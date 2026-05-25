# -------------------------------
# Runtime State Collection
# -------------------------------

<#
.SYNOPSIS
    Collects live runtime system state for connections and processes.

.DESCRIPTION
    05_runtime.ps1 collects runtime-only information from the running host and
    writes three JSON artifacts under:
    <OutputRoot>\<MachineName>-<yyyyMMdd>\runtime

    Required outputs:
      - connections.json
      - processes.json

    The collector does not perform offline collection. -SourceRoot is accepted
    for master-script compatibility and ignored.

.PARAMETER OutputRoot
    Root folder for collection output. If specified, output goes directly under
    <OutputRoot>\<MachineName>-<yyyyMMdd>. If omitted, output goes under the
    collector parent output folder.

.PARAMETER SourceRoot
    Accepted for master-script compatibility. Runtime collection is live-only.

.PARAMETER Force
    Forces live runtime collection even when -SourceRoot is explicitly
    specified.

.PARAMETER MachineName
    Machine name used for output folder naming and log records. Defaults to the
    current COMPUTERNAME.

.PARAMETER Cleanup
    Removes existing runtime output folder and runtime JSON files for the
    current MachineName/date before collecting.

.PARAMETER ShowLog
    Displays runtime collector log records on screen while also writing them
    to -Log when -Log is supplied.

.PARAMETER Log
    Shared log file path. When supplied, runtime collector records are appended
    to this file.

.PARAMETER Help
    Displays collector help and exits without collecting data.
#>

param (
    [string]$OutputRoot = (Split-Path -Path $PSScriptRoot -Parent),
    [string]$SourceRoot = "C:",
    [switch]$Force,
    [string]$MachineName = $env:COMPUTERNAME,
    [switch]$Cleanup,
    [switch]$ShowLog,
    [string]$Log,
    [switch]$Help
)

$SourceRootSpecified = $PSBoundParameters.ContainsKey("SourceRoot")

function Show-RuntimeHelp {
    Write-Host @"
05_runtime.ps1

Description:
  Collects live runtime state and stores JSON outputs under:
    <OutputRoot>\<MachineName>-<yyyyMMdd>\runtime

Required outputs:
  - connections.json
  - processes.json

Arguments:
  -OutputRoot <string>
      Root folder for collection output. If specified, output goes directly
      under <OutputRoot>\<MachineName>-<yyyyMMdd>. If omitted, output goes under
      <collector parent>\output\<MachineName>-<yyyyMMdd>.

  -SourceRoot <string>
      Accepted for master compatibility. Runtime collection is live-only.

  -Force
      Force live runtime collection even when -SourceRoot is explicitly
      specified.

  -MachineName <string>
      Machine name used for output folder naming and log records.

  -Cleanup
      Remove existing runtime output and runtime JSON files before collection.

  -ShowLog
      Display runtime log records on screen while also writing them to -Log.

  -Log <string>
      Shared log file path.

  -Help
      Display this help and exit.
"@
}

if ($Help) {
    Show-RuntimeHelp
    exit 0
}

if ($PSBoundParameters.ContainsKey("OutputRoot")) {
    $BaseDestination = $OutputRoot
}
else {
    $BaseDestination = Join-Path $OutputRoot "output"
}

$hostnameSafe = ($MachineName -replace '[^a-zA-Z0-9\-]', '_')
$dateString = Get-Date -Format "yyyyMMdd"
$DestinationRoot = Join-Path $BaseDestination "$hostnameSafe-$dateString"
$RuntimeOutputRoot = Join-Path $DestinationRoot "runtime"
$ConnectionsJsonPath = Join-Path $RuntimeOutputRoot "connections.json"
$ProcessesJsonPath = Join-Path $RuntimeOutputRoot "processes.json"
$RuntimeFilesCsvPath = Join-Path $DestinationRoot "collected_files.csv"
$RuntimeFileRecords = @()

function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $MachineName $Level runtime: $Message"

    if ($Log) {
        $logParent = Split-Path -Path $Log -Parent
        if ($logParent -and (-not (Test-Path -LiteralPath $logParent -PathType Container))) {
            New-Item -ItemType Directory -Path $logParent -Force | Out-Null
        }

        Add-Content -Path $Log -Value $logMessage -Encoding UTF8
    }

    if ($ShowLog -or (-not $Log)) {
        Write-Host $logMessage
    }
}

if ($Cleanup) {
    if (Test-Path -LiteralPath $RuntimeOutputRoot -PathType Container) {
        Write-Log -Message "Cleanup requested. Removing existing runtime output folder: $RuntimeOutputRoot"
        Remove-Item -LiteralPath $RuntimeOutputRoot -Recurse -Force
    }

    if (Test-Path -LiteralPath $RuntimeFilesCsvPath -PathType Leaf) {
        Write-Log -Message "Cleanup requested. Preserving shared collected files CSV: $RuntimeFilesCsvPath"
    }
}

if ($SourceRootSpecified -and (-not $Force)) {
    Write-Log -Message "SourceRoot was specified. Skipping runtime live collection."
    exit 0
}

if ($SourceRootSpecified -and $Force) {
    Write-Log -Level "DEBUG" -Message "Force was specified. Running runtime live collection even though SourceRoot was provided: $SourceRoot"
}

if (-not (Test-Path -LiteralPath $RuntimeOutputRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $RuntimeOutputRoot -Force | Out-Null
}

function Convert-CimDateToIsoString {
    param ([object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    try {
        if ($Value -is [datetime]) {
            return $Value.ToString("o")
        }

        return ([System.Management.ManagementDateTimeConverter]::ToDateTime([string]$Value)).ToString("o")
    }
    catch {
        return [string]$Value
    }
}

function Get-ProcessOwnerInfo {
    param ([object]$Process)

    try {
        $owner = Invoke-CimMethod -InputObject $Process -MethodName GetOwner -ErrorAction Stop
        $sid = Invoke-CimMethod -InputObject $Process -MethodName GetOwnerSid -ErrorAction Stop
        if ($owner.ReturnValue -eq 0) {
            return [pscustomobject]@{
                User = [string]$owner.User
                Domain = [string]$owner.Domain
                Sid = [string]$sid.Sid
            }
        }
    }
    catch {
    }

    return [pscustomobject]@{
        User = ""
        Domain = ""
        Sid = ""
    }
}

function Split-CommandLineArguments {
    param (
        [string]$CommandLine,
        [string]$ExecutablePath
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return ""
    }

    $trimmed = $CommandLine.Trim()
    if (-not [string]::IsNullOrWhiteSpace($ExecutablePath)) {
        $escaped = [regex]::Escape($ExecutablePath)
        return ($trimmed -replace "^\s*`"?$escaped`"?\s*", "").Trim()
    }

    if ($trimmed.StartsWith('"')) {
        $quoteIndex = $trimmed.IndexOf('"', 1)
        if ($quoteIndex -ge 0) {
            return $trimmed.Substring($quoteIndex + 1).Trim()
        }
    }

    $spaceIndex = $trimmed.IndexOf(" ")
    if ($spaceIndex -ge 0) {
        return $trimmed.Substring($spaceIndex + 1).Trim()
    }

    return ""
}

function Get-PathSha256Info {
    param (
        [string]$ExecutablePath,
        [int]$ProcessId
    )

    if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
        return [pscustomobject]@{
            Hash = ""
            Message = "Executable path is not available."
        }
    }

    if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
        $missingMessage = "Executable path does not exist or is inaccessible: $ExecutablePath"
        Write-Log -Level "ERROR" -Message "Could not calculate path SHA256 for PID ${ProcessId}. $missingMessage"
        return [pscustomobject]@{
            Hash = ""
            Message = $missingMessage
        }
    }

    try {
        $hashValue = (Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256 -ErrorAction Stop).Hash
        return [pscustomobject]@{
            Hash = $hashValue
            Message = ""
        }
    }
    catch {
        $errorMessage = "Failed to calculate SHA256 for executable path '$ExecutablePath': $_"
        Write-Log -Level "ERROR" -Message "Could not calculate path SHA256 for PID ${ProcessId}. $errorMessage"
        return [pscustomobject]@{
            Hash = ""
            Message = $errorMessage
        }
    }
}

function Build-ServiceMap {
    $serviceMap = @{}
    try {
        Get-CimInstance -ClassName Win32_Service -ErrorAction Stop | ForEach-Object {
            $processIdValue = [int]$_.ProcessId
            if ($processIdValue -le 0) {
                return
            }

            if (-not $serviceMap.ContainsKey($processIdValue)) {
                $serviceMap[$processIdValue] = @()
            }

            $serviceMap[$processIdValue] += [pscustomobject]@{
                Name = [string]$_.Name
                DisplayName = [string]$_.DisplayName
                State = [string]$_.State
                StartMode = [string]$_.StartMode
                StartName = [string]$_.StartName
                PathName = [string]$_.PathName
            }
        }
    }
    catch {
        Write-Log -Level "WARN" -Message "Could not collect Win32_Service process mapping: $_"
    }

    return $serviceMap
}

function Build-ProcessMap {
    param ([hashtable]$ServiceMap)

    $processMap = @{}
    $processList = @()

    try {
        Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | ForEach-Object {
            $owner = Get-ProcessOwnerInfo -Process $_
            $processIdValue = [int]$_.ProcessId
            $executablePath = [string]$_.ExecutablePath
            $pathSha256Info = Get-PathSha256Info -ExecutablePath $executablePath -ProcessId $processIdValue
            $services = @()
            if ($ServiceMap.ContainsKey($processIdValue)) {
                $services = @($ServiceMap[$processIdValue])
            }

            $record = [pscustomobject]@{
                ProcessId = $processIdValue
                ParentProcessId = [int]$_.ParentProcessId
                Name = [string]$_.Name
                ExecutablePath = $executablePath
                PathSha256 = $pathSha256Info.Hash
                PathSha256Message = $pathSha256Info.Message
                CommandLine = [string]$_.CommandLine
                Arguments = Split-CommandLineArguments -CommandLine ([string]$_.CommandLine) -ExecutablePath $executablePath
                Owner = $owner.User
                Domain = $owner.Domain
                Sid = $owner.Sid
                SessionId = [string]$_.SessionId
                Priority = [string]$_.Priority
                HandleCount = [string]$_.HandleCount
                ThreadCount = [string]$_.ThreadCount
                WorkingSetSize = [string]$_.WorkingSetSize
                VirtualSize = [string]$_.VirtualSize
                KernelModeTime = [string]$_.KernelModeTime
                UserModeTime = [string]$_.UserModeTime
                CreationDate = Convert-CimDateToIsoString -Value $_.CreationDate
                Services = $services
            }

            $processMap[$processIdValue] = $record
            $processList += $record
        }
    }
    catch {
        Write-Log -Level "WARN" -Message "Could not collect running process inventory with Win32_Process: $_"
    }

    return [pscustomobject]@{
        Map = $processMap
        List = ($processList | Sort-Object ProcessId)
    }
}

function Collect-Connections {
    param ([hashtable]$ProcessMap)

    $records = @()

    if (Get-Command -Name Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        try {
            Get-NetTCPConnection -ErrorAction Stop | ForEach-Object {
                $processIdValue = [int]$_.OwningProcess
                $process = $null
                if ($ProcessMap.ContainsKey($processIdValue)) {
                    $process = $ProcessMap[$processIdValue]
                }

                $records += [pscustomobject]@{
                    SourceType = "Runtime Network Connection"
                    Protocol = "TCP"
                    LocalAddress = [string]$_.LocalAddress
                    LocalPort = [string]$_.LocalPort
                    RemoteAddress = [string]$_.RemoteAddress
                    RemotePort = [string]$_.RemotePort
                    State = [string]$_.State
                    AppliedSetting = [string]$_.AppliedSetting
                    CreationTime = [string]$_.CreationTime
                    OffloadState = [string]$_.OffloadState
                    OwningProcessId = $processIdValue
                    OwningProcess = $process
                    Services = if ($null -ne $process) { $process.Services } else { @() }
                    CollectionMethod = "Get-NetTCPConnection"
                }
            }
        }
        catch {
            Write-Log -Level "WARN" -Message "Could not collect TCP connections with Get-NetTCPConnection: $_"
        }
    }
    else {
        Write-Log -Level "WARN" -Message "Get-NetTCPConnection is not available."
    }

    if (Get-Command -Name Get-NetUDPEndpoint -ErrorAction SilentlyContinue) {
        try {
            Get-NetUDPEndpoint -ErrorAction Stop | ForEach-Object {
                $processIdValue = [int]$_.OwningProcess
                $process = $null
                if ($ProcessMap.ContainsKey($processIdValue)) {
                    $process = $ProcessMap[$processIdValue]
                }

                $records += [pscustomobject]@{
                    SourceType = "Runtime Network Connection"
                    Protocol = "UDP"
                    LocalAddress = [string]$_.LocalAddress
                    LocalPort = [string]$_.LocalPort
                    RemoteAddress = ""
                    RemotePort = ""
                    State = ""
                    AppliedSetting = ""
                    CreationTime = [string]$_.CreationTime
                    OffloadState = ""
                    OwningProcessId = $processIdValue
                    OwningProcess = $process
                    Services = if ($null -ne $process) { $process.Services } else { @() }
                    CollectionMethod = "Get-NetUDPEndpoint"
                }
            }
        }
        catch {
            Write-Log -Level "WARN" -Message "Could not collect UDP endpoints with Get-NetUDPEndpoint: $_"
        }
    }
    else {
        Write-Log -Level "WARN" -Message "Get-NetUDPEndpoint is not available."
    }

    return $records
}

function Write-JsonFile {
    param (
        [string]$Path,
        [object]$Data
    )

    $Data | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding UTF8
}

function Add-RuntimeFileRecord {
    param (
        [string]$SourceType,
        [string]$FullOriginalPath,
        [string]$DestinationPath,
        [string]$CollectionMethod,
        [string]$Message = ""
    )

    $collected = "No"
    $fileCreated = ""
    $fileModified = ""
    $fileAccess = ""
    $size = ""
    $attributes = ""
    $sha256 = ""

    if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) {
        $collected = "Yes"
        try {
            $file = Get-Item -LiteralPath $DestinationPath -ErrorAction Stop
            $fileCreated = $file.CreationTime
            $fileModified = $file.LastWriteTime
            $fileAccess = $file.LastAccessTime
            $size = $file.Length
            $attributes = $file.Attributes
        }
        catch {
            Write-Log -Level "WARN" -Message "Could not read runtime artifact metadata for ${DestinationPath}: $_"
        }

        try {
            $sha256 = (Get-FileHash -LiteralPath $DestinationPath -Algorithm SHA256 -ErrorAction Stop).Hash
        }
        catch {
            $hashMessage = "Could not calculate SHA256 for runtime artifact '$DestinationPath': $_"
            Write-Log -Level "WARN" -Message $hashMessage
            if ([string]::IsNullOrWhiteSpace($Message)) {
                $Message = $hashMessage
            }
            else {
                $Message = "$Message $hashMessage"
            }
        }
    }

    $script:RuntimeFileRecords += [pscustomobject]@{
        "Source Type"        = $SourceType
        "Full Original Path" = $FullOriginalPath
        "Destination Path"   = $DestinationPath
        "File Created"       = $fileCreated
        "File Modified"      = $fileModified
        "File Access"        = $fileAccess
        "Size"               = $size
        "Attributes"         = $attributes
        "SHA256"             = $sha256
        "Collected"          = $collected
        "Collection Method"  = $CollectionMethod
        "Message"            = $Message
    }
}

function Export-RuntimeFilesCsv {
    if ($RuntimeFileRecords.Count -gt 0) {
        $csvExistsWithData = (Test-Path -LiteralPath $RuntimeFilesCsvPath -PathType Leaf) -and ((Get-Item -LiteralPath $RuntimeFilesCsvPath).Length -gt 0)
        if ($csvExistsWithData) {
            $RuntimeFileRecords | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1 | Add-Content -Path $RuntimeFilesCsvPath -Encoding UTF8
        }
        else {
            $RuntimeFileRecords | Export-Csv -Path $RuntimeFilesCsvPath -NoTypeInformation -Encoding UTF8
        }
    }
}

Write-Log -Message "Collecting runtime state"
$serviceMap = Build-ServiceMap
$processResult = Build-ProcessMap -ServiceMap $serviceMap
$processMap = $processResult.Map
$processes = $processResult.List
$connections = Collect-Connections -ProcessMap $processMap

Write-JsonFile -Path $ConnectionsJsonPath -Data $connections
Write-JsonFile -Path $ProcessesJsonPath -Data $processes

Add-RuntimeFileRecord -SourceType "Runtime JSON" -FullOriginalPath "Runtime Connections" -DestinationPath $ConnectionsJsonPath -CollectionMethod "ConvertTo-Json"
Add-RuntimeFileRecord -SourceType "Runtime JSON" -FullOriginalPath "Runtime Processes" -DestinationPath $ProcessesJsonPath -CollectionMethod "ConvertTo-Json"
Export-RuntimeFilesCsv

Write-Log -Message "Collection completed! Runtime data is stored in: $RuntimeOutputRoot"
Write-Log -Message "Connections collected: $($connections.Count)"
Write-Log -Message "Processes collected: $($processes.Count)"
Write-Log -Message "Runtime artifact files indexed: $($RuntimeFileRecords.Count)"

$hasRuntimeData = ($connections.Count -gt 0) -or ($processes.Count -gt 0)
if ((-not $hasRuntimeData) -and (Test-Path -LiteralPath $RuntimeOutputRoot -PathType Container)) {
    Remove-Item -LiteralPath $RuntimeOutputRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log -Message "No runtime data collected. Removed empty runtime folder: $RuntimeOutputRoot"
}
