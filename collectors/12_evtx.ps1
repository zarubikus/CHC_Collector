# -------------------------------
# Windows Event Log Collection with Hostname Folder
# -------------------------------

<#
.SYNOPSIS
    Collects Windows Event Log artifacts from offline EVTX files and live logs.

.DESCRIPTION
    20_eventlogs.ps1 collects Windows Event Log evidence into
    <OutputRoot>\<MachineName>-<yyyyMMdd>\evtx. When -SourceRoot is
    explicitly supplied, it copies offline .evtx files from the supplied
    filesystem root and skips live collection. When -SourceRoot is not supplied,
    it enumerates event logs with Get-WinEvent -ListLog *, exports logs with
    records using wevtutil.exe epl, and logs zero-record channels as INFO.

    The collector creates a single CSV index for copied EVTX files and live log
    export attempts. The index includes source type, original path or log path,
    destination path, timestamps, size, attributes, SHA256, collection status,
    collection method, and message.

.PARAMETER OutputRoot
    Root folder for collection output. If specified, output goes directly under
    <OutputRoot>\<MachineName>-<yyyyMMdd>. If omitted, output goes under the
    collector parent output folder.

.PARAMETER SourceRoot
    Offline filesystem root. When explicitly specified, offline EVTX files are
    copied from <SourceRoot>\Windows\System32\winevt\Logs.

.PARAMETER MachineName
    Machine name used for output folder naming and log records. Defaults to the
    current COMPUTERNAME.

.PARAMETER Cleanup
    Removes existing event log output and event log CSV files for the current
    MachineName/date before collecting.

.PARAMETER ShowLog
    Displays event log collector log records on screen while also writing them
    to -Log when -Log is supplied.

.PARAMETER Log
    Shared log file path. When supplied, event log collector records are
    appended to this file.

.PARAMETER Help
    Displays collector help and exits without collecting data.

.EXAMPLE
    .\collectors\20_eventlogs.ps1 -OutputRoot E:\Collections -MachineName HOST01 -SourceRoot D:\MountedImage

    Copies offline EVTX files from D:\MountedImage\Windows\System32\winevt\Logs
    and exports populated live logs under E:\Collections\HOST01-<yyyyMMdd>.

.EXAMPLE
    .\collectors\20_eventlogs.ps1 -Log .\output\HOST01-20260523_master.log -ShowLog

    Exports populated live event logs, appends records to the shared log, and
    mirrors log records to the console.

.NOTES
    Live collection uses Get-WinEvent and wevtutil.exe. Metadata archiving with
    wevtutil archive-log is attempted opportunistically; if unsupported on the
    host, the collector continues with EVTX exports.
#>

param (
    [string]$OutputRoot = (Split-Path -Path $PSScriptRoot -Parent),
    [string]$SourceRoot = "C:",
    [string]$MachineName = $env:COMPUTERNAME,
    [switch]$Cleanup,
    [switch]$ShowLog,
    [string]$Log,
    [switch]$Help
)

function Show-EventLogsHelp {
    Write-Host @"
20_eventlogs.ps1

Description:
  Collects Windows Event Log artifacts. When -SourceRoot is specified, it
  copies offline .evtx files from that filesystem root and skips live
  collection. When -SourceRoot is not specified, it exports live event logs from
  the running system using built-in Windows tooling.

Arguments:
  -OutputRoot <string>
      Root folder for collection output. If specified, output goes directly
      under <OutputRoot>\<MachineName>-<yyyyMMdd>. If omitted, output goes under
      <collector parent>\output\<MachineName>-<yyyyMMdd>.

  -SourceRoot <string>
      Offline filesystem root. When specified, the collector copies event log
      files from this root. Example: C: or D:\MountedImage.

  -MachineName <string>
      Machine name used for output folder naming and log records. Default:
      current COMPUTERNAME.

  -Cleanup
      Remove existing event log output and event log CSV files for the current
      MachineName/date before collection.

  -ShowLog
      Display event log collector log records on screen while also writing them
      to -Log when -Log is supplied.

  -Log <string>
      Shared log file path. When supplied, event log collector records are
      appended to this file.

  -Help
      Display this help and exit without collecting data.

Technical collection logic:
  Offline event log file copy, only when -SourceRoot is explicitly specified:
    - Source: <SourceRoot>\Windows\System32\winevt\Logs
    - Pattern: *.evtx, recursively.
    - Copies files into:
      <OutputRoot>\<MachineName>-<yyyyMMdd>\evtx\<source-relative-path>
    - If a file cannot be copied normally, the collector retries with a
      temporary shadow copy of the source volume.

  Live event log collection, only when -SourceRoot is not specified:
    - Enumerates logs with Get-WinEvent -ListLog *.
    - Exports logs with RecordCount > 0 using:
      wevtutil epl <LogName> <DestinationFile>
    - Logs channels with RecordCount 0 as INFO and does not export them.
    - Destination path mirrors the configured event log file path when Windows
      exposes it, usually under Windows\System32\winevt\Logs.
    - If a configured path is unavailable, destination filenames replace / with
      %2F to preserve channel names safely.
    - Runs wevtutil archive-log <DestinationFile> /locale:en-us after export so
      provider metadata is captured when available.
    - Saves exported logs into:
      <OutputRoot>\<MachineName>-<yyyyMMdd>\evtx\Windows\System32\winevt\Logs

  Index output:
    - collected_files.csv indexes offline copied/found files and live event log
      export attempts with source type, original path or log path, destination
      path, timestamps, size, attributes, SHA256, collected status, collection
      method, and message.
"@
}

if ($Help) {
    Show-EventLogsHelp
    exit 0
}

# ===== CONFIGURATION =====
$SourceRootSpecified = $PSBoundParameters.ContainsKey("SourceRoot")

if ($SourceRoot -match '^[a-zA-Z]:$') {
    $SourceRoot = "$SourceRoot\"
}

$SourceRootFullPath = [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
$SourceRootPrefix = "$SourceRootFullPath\"

if ($PSBoundParameters.ContainsKey("OutputRoot")) {
    $BaseDestination = $OutputRoot
}
else {
    $BaseDestination = Join-Path $OutputRoot "output"
}

$hostnameRaw = $MachineName
$hostnameSafe = ($hostnameRaw -replace '[^a-zA-Z0-9\-]', '_')
$dateString = Get-Date -Format "yyyyMMdd"
$DestinationRoot = Join-Path $BaseDestination "$hostnameSafe-$dateString"
$EventLogsOutputRoot = Join-Path $DestinationRoot "evtx"
$OfflineEventLogsOutputRoot = $EventLogsOutputRoot
$LiveEventLogsOutputRoot = Join-Path $EventLogsOutputRoot "Windows\System32\winevt\Logs"
$FileCsvPath = Join-Path $DestinationRoot "collected_files.csv"
$CollectedFileRecords = @()
$LiveEventLogRecords = @()
$SeenFilePaths = @{}
$MetadataArchivingAvailable = $true
$FileCsvColumns = @(
    "Source Type",
    "Full Original Path",
    "Destination Path",
    "File Created",
    "File Modified",
    "File Access",
    "Size",
    "Attributes",
    "SHA256",
    "Collected",
    "Collection Method",
    "Message"
)
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $MachineName $Level eventlogs: $Message"

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
    if (Test-Path -LiteralPath $EventLogsOutputRoot -PathType Container) {
        Write-Log -Message "Cleanup requested. Removing existing Event Logs output folder: $EventLogsOutputRoot"
        Remove-Item -LiteralPath $EventLogsOutputRoot -Recurse -Force
    }

    foreach ($csvPath in @($FileCsvPath)) {
        if (Test-Path -LiteralPath $csvPath -PathType Leaf) {
            Write-Log -Message "Cleanup requested. Preserving shared collected files CSV: $csvPath"
        }
    }
}

function Get-SourceRelativePath {
    param ([string]$SourcePath)

    $sourceFullPath = [System.IO.Path]::GetFullPath($SourcePath)
    if ($sourceFullPath.StartsWith($SourceRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $sourceFullPath.Substring($SourceRootPrefix.Length)
    }

    return (($SourcePath -replace ":", "") -replace "\\", "\")
}

function Add-EventLogFileRecord {
    param (
        [System.IO.FileInfo]$File,
        [string]$SourceType,
        [string]$DestinationPath = "",
        [string]$Collected,
        [string]$SHA256 = "",
        [string]$CollectionMethod = "",
        [string]$Message = ""
    )

    $script:CollectedFileRecords += [pscustomobject]@{
        "Source Type"        = $SourceType
        "Full Original Path" = $File.FullName
        "Destination Path"   = $DestinationPath
        "File Created"       = $File.CreationTime
        "File Modified"      = $File.LastWriteTime
        "File Access"        = $File.LastAccessTime
        "Size"               = $File.Length
        "Attributes"         = $File.Attributes
        "SHA256"             = $SHA256
        "Collected"          = $Collected
        "Collection Method"  = $CollectionMethod
        "Message"            = $Message
    }
}

function Get-EventLogFileSha256 {
    param (
        [string]$Path,
        [string]$Description
    )

    try {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    }
    catch {
        Write-Log -Level "WARN" -Message "Could not calculate SHA256 for ${Description}: $_"
        return ""
    }
}

function Copy-FileWithShadowCopy {
    param (
        [string]$SourcePath,
        [string]$DestinationPath
    )

    $sourceFullPath = [System.IO.Path]::GetFullPath($SourcePath)
    $sourceRoot = [System.IO.Path]::GetPathRoot($sourceFullPath)
    if ([string]::IsNullOrWhiteSpace($sourceRoot) -or ($sourceRoot -notmatch '^[a-zA-Z]:\\$')) {
        return [pscustomobject]@{
            Success = $false
            Message = "Shadow copy fallback supports local drive paths only."
        }
    }

    $shadow = $null
    try {
        $createResult = Invoke-CimMethod -ClassName Win32_ShadowCopy -MethodName Create -Arguments @{
            Volume  = $sourceRoot
            Context = "ClientAccessible"
        } -ErrorAction Stop

        if ($createResult.ReturnValue -ne 0) {
            return [pscustomobject]@{
                Success = $false
                Message = "Shadow copy creation failed with return value $($createResult.ReturnValue)."
            }
        }

        $shadow = Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction Stop |
            Where-Object { $_.ID -eq $createResult.ShadowID } |
            Select-Object -First 1

        if (-not $shadow) {
            return [pscustomobject]@{
                Success = $false
                Message = "Shadow copy was created but could not be found by ID $($createResult.ShadowID)."
            }
        }

        $relativePath = $sourceFullPath.Substring($sourceRoot.Length)
        $shadowSourcePath = Join-Path ($shadow.DeviceObject + "\") $relativePath
        Copy-Item -LiteralPath $shadowSourcePath -Destination $DestinationPath -Force -ErrorAction Stop

        return [pscustomobject]@{
            Success = $true
            Message = "Copied from shadow copy $($shadow.ID)."
        }
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            Message = "Shadow copy fallback failed: $_"
        }
    }
    finally {
        if ($shadow) {
            $shadowId = $shadow.ID
            try {
                $shadowToDelete = Get-CimInstance -ClassName Win32_ShadowCopy -Filter "ID='$shadowId'" -ErrorAction Stop
                if ($shadowToDelete) {
                    $shadowToDelete | Remove-CimInstance -ErrorAction Stop
                }
            }
            catch {
                try {
                    $wmiShadow = Get-WmiObject -Class Win32_ShadowCopy -Filter "ID='$shadowId'" -ErrorAction Stop
                    if ($wmiShadow) {
                        $deleteResult = $wmiShadow.Delete()
                        if ($deleteResult.ReturnValue -ne 0) {
                            throw "WMI delete returned $($deleteResult.ReturnValue)."
                        }
                    }
                }
                catch {
                    Write-Log -Level "WARN" -Message "Could not delete shadow copy ${shadowId}: $_"
                }
            }
        }
    }
}

function Copy-FileWithFallback {
    param (
        [string]$SourcePath,
        [string]$DestinationPath
    )

    $destParent = Split-Path -Path $DestinationPath -Parent
    if (-not (Test-Path -LiteralPath $destParent -PathType Container)) {
        New-Item -ItemType Directory -Path $destParent -Force | Out-Null
    }

    try {
        Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force -ErrorAction Stop
        return [pscustomobject]@{
            Success = $true
            Method  = "Copy-Item"
            Message = "Copied successfully."
        }
    }
    catch {
        $copyItemMessage = "Copy-Item failed: $_"
        Write-Log -Level "WARN" -Message "Could not collect $SourcePath with Copy-Item: $_"
    }

    $shadowCopyResult = Copy-FileWithShadowCopy -SourcePath $SourcePath -DestinationPath $DestinationPath
    if ($shadowCopyResult.Success) {
        Write-Log -Level "DEBUG" -Message "Collected $SourcePath using shadow copy after Copy-Item failed. Destination: $DestinationPath"
        return [pscustomobject]@{
            Success = $true
            Method  = "shadow copy"
            Message = $shadowCopyResult.Message
        }
    }

    Write-Log -Level "WARN" -Message "Could not collect ${SourcePath} with shadow copy: $($shadowCopyResult.Message)"
    return [pscustomobject]@{
        Success = $false
        Method  = ""
        Message = "$copyItemMessage $($shadowCopyResult.Message)"
    }
}

function Copy-EventLogFile {
    param (
        [System.IO.FileInfo]$File,
        [string]$SourceType
    )

    if ($script:SeenFilePaths.ContainsKey($File.FullName)) {
        return
    }
    $script:SeenFilePaths[$File.FullName] = $true

    $sha256 = ""
    $collected = "No"
    $collectionMethod = ""
    $message = ""
    $relativePath = Get-SourceRelativePath -SourcePath $File.FullName
    $destPath = Join-Path $OfflineEventLogsOutputRoot $relativePath

    $fallbackResult = Copy-FileWithFallback -SourcePath $File.FullName -DestinationPath $destPath
    if ($fallbackResult.Success) {
        $collected = "Yes"
        $collectionMethod = $fallbackResult.Method
        $message = $fallbackResult.Message
    }
    else {
        $message = $fallbackResult.Message
    }

    if ($collected -eq "Yes") {
        $sha256 = Get-EventLogFileSha256 -Path $destPath -Description $destPath
    }

    Add-EventLogFileRecord -File $File -SourceType $SourceType -DestinationPath $destPath -Collected $collected -SHA256 $sha256 -CollectionMethod $collectionMethod -Message $message
}

function Add-LiveEventLogRecord {
    param (
        [string]$LogName,
        [string]$OriginalPath = "",
        [string]$DestinationPath,
        [int64]$RecordCount,
        [string]$Collected,
        [string]$SHA256 = "",
        [string]$Message = "",
        [string]$CollectionMethod = "wevtutil epl"
    )

    $script:LiveEventLogRecords += [pscustomobject]@{
        "Log Name"         = $LogName
        "Destination Path" = $DestinationPath
        "Record Count"    = $RecordCount
        "SHA256"          = $SHA256
        "Collected"       = $Collected
        "Message"         = $Message
    }

    if ([string]::IsNullOrWhiteSpace($OriginalPath)) {
        $OriginalPath = $LogName
    }

    $fileCreated = ""
    $fileModified = ""
    $fileAccess = ""
    $size = ""
    $attributes = ""
    if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) {
        try {
            $destinationFile = Get-Item -LiteralPath $DestinationPath -Force -ErrorAction Stop
            $fileCreated = $destinationFile.CreationTime
            $fileModified = $destinationFile.LastWriteTime
            $fileAccess = $destinationFile.LastAccessTime
            $size = $destinationFile.Length
            $attributes = $destinationFile.Attributes
        }
        catch {
            Write-Log -Level "WARN" -Message "Could not read live event log metadata for ${DestinationPath}: $_"
        }
    }

    $recordMessage = "RecordCount=$RecordCount. $Message"
    $script:CollectedFileRecords += [pscustomobject]@{
        "Source Type"        = "Live Event Log"
        "Full Original Path" = $OriginalPath
        "Destination Path"   = $DestinationPath
        "File Created"       = $fileCreated
        "File Modified"      = $fileModified
        "File Access"        = $fileAccess
        "Size"               = $size
        "Attributes"         = $attributes
        "SHA256"             = $SHA256
        "Collected"          = $Collected
        "Collection Method"  = $CollectionMethod
        "Message"            = $recordMessage
    }
}

function ConvertTo-EventLogFileName {
    param ([string]$LogName)

    return (($LogName -replace "/", "%2F") -replace '[<>:"\\|?*]', "_") + ".evtx"
}

function Get-LiveEventLogDestinationPath {
    param (
        [object]$EventLog,
        [string]$LogName
    )

    $logFilePath = ""
    try {
        $logFilePath = [string]$EventLog.LogFilePath
    }
    catch {
        $logFilePath = ""
    }

    if (-not [string]::IsNullOrWhiteSpace($logFilePath)) {
        $expandedPath = [Environment]::ExpandEnvironmentVariables($logFilePath)
        try {
            $fullPath = [System.IO.Path]::GetFullPath($expandedPath)
            $root = [System.IO.Path]::GetPathRoot($fullPath)
            if (-not [string]::IsNullOrWhiteSpace($root)) {
                $relativePath = $fullPath.Substring($root.Length)
                return Join-Path $EventLogsOutputRoot $relativePath
            }
        }
        catch {
            Write-Log -Level "WARN" -Message "Could not normalize live event log file path '${logFilePath}' for ${LogName}: $_"
        }
    }

    return Join-Path $LiveEventLogsOutputRoot (ConvertTo-EventLogFileName -LogName $LogName)
}

function Copy-OfflineEventLogFiles {
    if (-not $SourceRootSpecified) {
        Write-Log -Message "SourceRoot was not specified. Skipping offline event log file collection."
        return
    }

    $eventLogPath = Join-Path $SourceRoot "Windows\System32\winevt\Logs"
    if (-not (Test-Path -LiteralPath $eventLogPath -PathType Container)) {
        Write-Log -Level "WARN" -Message "Offline Event Log source folder not found: $eventLogPath"
        return
    }

    Write-Log -Message "Collecting offline event log files from $eventLogPath"
    Get-ChildItem -LiteralPath $eventLogPath -File -Filter "*.evtx" -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-EventLogFile -File $_ -SourceType "Offline EVTX"
    }
}

function Export-LiveEventLogs {
    Write-Log -Message "Collecting live Windows Event Logs"

    try {
        $eventLogs = Get-WinEvent -ListLog * -ErrorAction SilentlyContinue
    }
    catch {
        Write-Log -Level "WARN" -Message "Could not enumerate live Windows Event Logs: $_"
        return
    }

    foreach ($eventLog in $eventLogs) {
        $source = $eventLog.LogName
        $recordCount = [int64]$eventLog.RecordCount
        if ($recordCount -le 0) {
            Write-Log -Message "Skipping live event log with no records: $source"
            continue
        }

        $originalLogPath = ""
        try {
            $originalLogPath = [Environment]::ExpandEnvironmentVariables([string]$eventLog.LogFilePath)
        }
        catch {
            $originalLogPath = $source
        }
        if ([string]::IsNullOrWhiteSpace($originalLogPath)) {
            $originalLogPath = $source
        }

        $destinationFile = Get-LiveEventLogDestinationPath -EventLog $eventLog -LogName $source
        $destinationParent = Split-Path -Path $destinationFile -Parent
        if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
            New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        }

        if (Test-Path -LiteralPath $destinationFile -PathType Leaf) {
            Remove-Item -LiteralPath $destinationFile -Force -ErrorAction SilentlyContinue
        }

        try {
            Write-Log -Message "Exporting live event log: $source"
            $exportOutput = & wevtutil.exe epl $source $destinationFile 2>&1
            if ($LASTEXITCODE -ne 0) {
                $message = ($exportOutput -join " ")
                if (Test-Path -LiteralPath $destinationFile -PathType Leaf) {
                    Remove-Item -LiteralPath $destinationFile -Force -ErrorAction SilentlyContinue
                }
                Write-Log -Level "WARN" -Message "Could not export live event log ${source}: $message"
                Add-LiveEventLogRecord -LogName $source -OriginalPath $originalLogPath -DestinationPath $destinationFile -RecordCount $recordCount -Collected "No" -Message $message
                continue
            }

            if ($script:MetadataArchivingAvailable) {
                $archiveOutput = & wevtutil.exe archive-log $destinationFile /locale:en-us 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $script:MetadataArchivingAvailable = $false
                    Write-Log -Level "WARN" -Message "Could not archive event log metadata on this system. Continuing with EVTX exports only. First failure for ${source}: $(($archiveOutput -join " "))"
                }
            }

            $sha256 = ""
            try {
                $sha256 = (Get-FileHash -LiteralPath $destinationFile -Algorithm SHA256 -ErrorAction Stop).Hash
            }
            catch {
                Write-Log -Level "WARN" -Message "Could not calculate SHA256 for exported event log $destinationFile`: $_"
            }

            Add-LiveEventLogRecord -LogName $source -OriginalPath $originalLogPath -DestinationPath $destinationFile -RecordCount $recordCount -Collected "Yes" -SHA256 $sha256 -Message ($exportOutput -join " ")
        }
        catch {
            if (Test-Path -LiteralPath $destinationFile -PathType Leaf) {
                Remove-Item -LiteralPath $destinationFile -Force -ErrorAction SilentlyContinue
            }
            Write-Log -Level "WARN" -Message "Could not export live event log ${source}: $_"
            Add-LiveEventLogRecord -LogName $source -OriginalPath $originalLogPath -DestinationPath $destinationFile -RecordCount $recordCount -Collected "No" -Message $_
        }
    }
}

function Export-EventLogsCsv {
    if ($CollectedFileRecords.Count -gt 0) {
        $recordsToWrite = @($CollectedFileRecords)
        if (Test-Path -LiteralPath $FileCsvPath -PathType Leaf) {
            $existingRows = @(Import-Csv -Path $FileCsvPath -ErrorAction SilentlyContinue)
            $recordsToWrite = @($CollectedFileRecords | Where-Object {
                $record = $_
                $matches = @($existingRows | Where-Object {
                    ($_."Source Type" -eq $record."Source Type") -and
                    ($_."Full Original Path" -eq $record."Full Original Path") -and
                    ($_."Destination Path" -eq $record."Destination Path")
                } | Select-Object -First 1)
                $matches.Count -eq 0
            })
        }

        if ($recordsToWrite.Count -eq 0) {
            Write-Log -Level "DEBUG" -Message "No new event log rows to append to collected_files.csv."
            return
        }

        $csvExistsWithData = (Test-Path -LiteralPath $FileCsvPath -PathType Leaf) -and ((Get-Item -LiteralPath $FileCsvPath).Length -gt 0)
        if ($csvExistsWithData) {
            $recordsToWrite | Select-Object $FileCsvColumns | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1 | Add-Content -Path $FileCsvPath -Encoding UTF8
        }
        else {
            $recordsToWrite | Select-Object $FileCsvColumns | Export-Csv -Path $FileCsvPath -NoTypeInformation -Encoding UTF8
        }
    }
}

if ($SourceRootSpecified) {
    Copy-OfflineEventLogFiles
    Write-Log -Message "SourceRoot was specified. Skipping live event log collection."
}
else {
    Export-LiveEventLogs
}
Export-EventLogsCsv

Write-Log -Message "Collection completed! Event Logs are stored in: $EventLogsOutputRoot"
Write-Log -Message "Offline event log files collected/found: $(($CollectedFileRecords | Where-Object { $_.Collected -eq "Yes" }).Count)/$($CollectedFileRecords.Count)"
if (-not $SourceRootSpecified) {
    Write-Log -Message "Live event logs collected/attempted: $(($LiveEventLogRecords | Where-Object { $_.Collected -eq "Yes" }).Count)/$($LiveEventLogRecords.Count)"
}

$hasEventLogData = ($CollectedFileRecords | Where-Object { $_.Collected -eq "Yes" }).Count -gt 0
if ((-not $hasEventLogData) -and (Test-Path -LiteralPath $EventLogsOutputRoot -PathType Container)) {
    Remove-Item -LiteralPath $EventLogsOutputRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log -Message "No event log data collected. Removed empty evtx folder: $EventLogsOutputRoot"
}
