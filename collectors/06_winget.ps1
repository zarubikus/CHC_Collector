# -------------------------------
# Installed Software and Update Collection
# -------------------------------

<#
.SYNOPSIS
    Collects installed software and available update information from a live Windows system.

.DESCRIPTION
    06_winget.ps1 collects live installed software inventory and available
    software update information. It is live-only and does not perform offline
    collection. If -SourceRoot is explicitly specified, collection is skipped
    unless -Force is supplied.

    Installed software inventory is collected from registry uninstall keys,
    AppX packages when available, Get-Package when available, and WinGet when
    available. Available updates are collected with Microsoft.WinGet.Client
    PowerShell commands if they are already installed; otherwise the collector
    falls back to winget.exe upgrade output.

    The collector does not install modules, does not install software, and does
    not run upgrades.

.PARAMETER OutputRoot
    Root folder for collection output. If specified, output goes directly under
    <OutputRoot>\<MachineName>-<yyyyMMdd>. If omitted, output goes under the
    collector parent output folder.

.PARAMETER SourceRoot
    Accepted for master-script compatibility. When explicitly specified,
    collection is skipped unless -Force is supplied.

.PARAMETER Force
    Forces live collection even when -SourceRoot is explicitly specified.

.PARAMETER MachineName
    Machine name used for output folder naming and log records. Defaults to the
    current COMPUTERNAME.

.PARAMETER Cleanup
    Removes existing winget output folder before collecting. The shared
    collected_files.csv is preserved.

.PARAMETER ShowLog
    Displays collector log records on screen while also writing them to -Log
    when -Log is supplied.

.PARAMETER Log
    Shared log file path. When supplied, collector records are appended to this
    file.

.PARAMETER Help
    Displays collector help and exits without collecting data.

.EXAMPLE
    .\06_winget.ps1

    Collects installed software and available updates from the live system.

.EXAMPLE
    .\06_winget.ps1 -SourceRoot D:\MountedImage

    Skips live collection because SourceRoot was explicitly supplied.

.EXAMPLE
    .\06_winget.ps1 -SourceRoot D:\MountedImage -Force

    Forces live collection even though SourceRoot was explicitly supplied.

.NOTES
    CHC Collector winget collector. Uses built-in PowerShell, registry queries,
    optional Microsoft.WinGet.Client commands if already present, and winget.exe
    when available.
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

function Show-WingetHelp {
    Write-Host @"
06_winget.ps1

Description:
  Collects live installed software inventory and available update information.
  This collector is live-only. It skips collection when -SourceRoot is
  explicitly specified unless -Force is supplied.

Outputs:
  <OutputRoot>\<MachineName>-<yyyyMMdd>\winget\installed_software.json
  <OutputRoot>\<MachineName>-<yyyyMMdd>\winget\available_updates.json
  <OutputRoot>\<MachineName>-<yyyyMMdd>\winget\winget_environment.json
  <OutputRoot>\<MachineName>-<yyyyMMdd>\winget\winget_list_raw.txt
  <OutputRoot>\<MachineName>-<yyyyMMdd>\winget\winget_upgrade_raw.txt
  <OutputRoot>\<MachineName>-<yyyyMMdd>\winget\winget_source_list_raw.txt

Collection logic:
  - Installed software:
      Registry uninstall keys:
        HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*
        HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*
        HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*
      AppX packages with Get-AppxPackage when available.
      Package providers with Get-Package when available.
      WinGet package list with Microsoft.WinGet.Client or winget.exe when available.
  - Available updates:
      Microsoft.WinGet.Client PowerShell commands if already installed.
      winget.exe upgrade fallback if available.
  - File index:
      Appends generated files to shared collected_files.csv using SHA256.

Arguments:
  -OutputRoot <string>  Root folder for collection output.
  -SourceRoot <string>  Accepted for compatibility; skips live collection unless -Force.
  -Force                Force live collection when SourceRoot is specified.
  -MachineName <string> Machine name for output naming and log records.
  -Cleanup              Remove existing winget output folder before collection.
  -ShowLog              Display log records on screen.
  -Log <string>         Shared log file path.
  -Help                 Display this help and exit.
"@
}

if ($Help) {
    Show-WingetHelp
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
$WingetOutputRoot = Join-Path $DestinationRoot "winget"
$InstalledSoftwareJsonPath = Join-Path $WingetOutputRoot "installed_software.json"
$AvailableUpdatesJsonPath = Join-Path $WingetOutputRoot "available_updates.json"
$EnvironmentJsonPath = Join-Path $WingetOutputRoot "winget_environment.json"
$WingetListRawPath = Join-Path $WingetOutputRoot "winget_list_raw.txt"
$WingetUpgradeRawPath = Join-Path $WingetOutputRoot "winget_upgrade_raw.txt"
$WingetSourceListRawPath = Join-Path $WingetOutputRoot "winget_source_list_raw.txt"
$FilesCsvPath = Join-Path $DestinationRoot "collected_files.csv"
$CollectedFileRecords = @()
$CollectionErrors = @()

function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $MachineName $Level winget: $Message"

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

function Add-CollectionError {
    param (
        [string]$Source,
        [string]$Message
    )

    $script:CollectionErrors += [pscustomobject]@{
        Source = $Source
        Message = $Message
    }
}

if ($Cleanup) {
    if (Test-Path -LiteralPath $WingetOutputRoot -PathType Container) {
        Write-Log -Message "Cleanup requested. Removing existing winget output folder: $WingetOutputRoot"
        Remove-Item -LiteralPath $WingetOutputRoot -Recurse -Force
    }

    if (Test-Path -LiteralPath $FilesCsvPath -PathType Leaf) {
        Write-Log -Message "Cleanup requested. Preserving shared collected files CSV: $FilesCsvPath"
    }
}

if ($SourceRootSpecified -and (-not $Force)) {
    Write-Log -Message "SourceRoot was specified. Skipping winget live collection."
    exit 0
}

if ($SourceRootSpecified -and $Force) {
    Write-Log -Level "DEBUG" -Message "Force was specified. Running winget live collection even though SourceRoot was provided: $SourceRoot"
}

function Ensure-WingetOutputRoot {
    if (-not (Test-Path -LiteralPath $WingetOutputRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $WingetOutputRoot -Force | Out-Null
    }
}

function Write-JsonFile {
    param (
        [string]$Path,
        [object]$Data
    )

    Ensure-WingetOutputRoot
    ConvertTo-Json -InputObject $Data -Depth 12 | Set-Content -Path $Path -Encoding UTF8
}

function Invoke-ExternalCommand {
    param (
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$RawOutputPath,
        [string]$SourceName
    )

    $result = [pscustomobject]@{
        ExitCode = $null
        Output = @()
        OutputText = ""
        Error = ""
    }

    try {
        Ensure-WingetOutputRoot
        $output = & $FilePath @Arguments 2>&1
        $result.ExitCode = $LASTEXITCODE
        $result.Output = @($output | ForEach-Object { [string]$_ })
        $result.OutputText = ($result.Output -join [Environment]::NewLine)
        Set-Content -Path $RawOutputPath -Value $result.Output -Encoding UTF8

        if ($result.ExitCode -ne 0) {
            $message = "$SourceName exited with code $($result.ExitCode)."
            Write-Log -Level "WARN" -Message $message
            Add-CollectionError -Source $SourceName -Message $message
        }
    }
    catch {
        $result.Error = [string]$_
        $message = "Could not execute ${SourceName}: $_"
        Write-Log -Level "WARN" -Message $message
        Add-CollectionError -Source $SourceName -Message $message
    }

    return $result
}

function Get-RegistryInstalledSoftware {
    $records = @()
    $locations = @(
        [pscustomobject]@{ Hive = "HKLM"; View = "64-bit"; Path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" },
        [pscustomobject]@{ Hive = "HKLM"; View = "32-bit"; Path = "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" },
        [pscustomobject]@{ Hive = "HKCU"; View = "Current User"; Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" }
    )

    foreach ($location in $locations) {
        try {
            Get-ItemProperty -Path $location.Path -ErrorAction SilentlyContinue | ForEach-Object {
                if ([string]::IsNullOrWhiteSpace([string]$_.DisplayName)) {
                    return
                }

                $records += [pscustomobject]@{
                    SourceType = "Registry Uninstall"
                    Hive = $location.Hive
                    RegistryView = $location.View
                    RegistryPath = [string]$_.PSPath
                    Name = [string]$_.DisplayName
                    Version = [string]$_.DisplayVersion
                    Publisher = [string]$_.Publisher
                    InstallDate = [string]$_.InstallDate
                    InstallLocation = [string]$_.InstallLocation
                    InstallSource = [string]$_.InstallSource
                    UninstallString = [string]$_.UninstallString
                    QuietUninstallString = [string]$_.QuietUninstallString
                    EstimatedSizeKb = [string]$_.EstimatedSize
                    WindowsInstaller = [string]$_.WindowsInstaller
                    SystemComponent = [string]$_.SystemComponent
                    ReleaseType = [string]$_.ReleaseType
                }
            }
        }
        catch {
            $message = "Could not collect installed software from $($location.Path): $_"
            Write-Log -Level "WARN" -Message $message
            Add-CollectionError -Source "Registry Uninstall" -Message $message
        }
    }

    return $records
}

function Get-AppxInstalledSoftware {
    $records = @()

    if (-not (Get-Command -Name Get-AppxPackage -ErrorAction SilentlyContinue)) {
        return $records
    }

    try {
        Get-AppxPackage -AllUsers -ErrorAction Stop | ForEach-Object {
            $records += [pscustomobject]@{
                SourceType = "AppX Package"
                Name = [string]$_.Name
                PackageFullName = [string]$_.PackageFullName
                PackageFamilyName = [string]$_.PackageFamilyName
                Publisher = [string]$_.Publisher
                Version = [string]$_.Version
                Architecture = [string]$_.Architecture
                InstallLocation = [string]$_.InstallLocation
                IsFramework = [string]$_.IsFramework
                IsBundle = [string]$_.IsBundle
                SignatureKind = [string]$_.SignatureKind
                Status = [string]$_.Status
            }
        }
    }
    catch {
        $message = "Could not collect AppX packages: $_"
        Write-Log -Level "WARN" -Message $message
        Add-CollectionError -Source "Get-AppxPackage" -Message $message
    }

    return $records
}

function Get-PackageInstalledSoftware {
    $records = @()

    if (-not (Get-Command -Name Get-Package -ErrorAction SilentlyContinue)) {
        return $records
    }

    try {
        Get-Package -ErrorAction Stop | ForEach-Object {
            $records += [pscustomobject]@{
                SourceType = "Get-Package"
                Name = [string]$_.Name
                Version = [string]$_.Version
                ProviderName = [string]$_.ProviderName
                Source = [string]$_.Source
                Status = [string]$_.Status
                FastPackageReference = [string]$_.FastPackageReference
            }
        }
    }
    catch {
        $message = "Could not collect package inventory with Get-Package: $_"
        Write-Log -Level "WARN" -Message $message
        Add-CollectionError -Source "Get-Package" -Message $message
    }

    return $records
}

function Convert-WingetObject {
    param (
        [object]$InputObject,
        [string]$SourceType
    )

    $properties = [ordered]@{ SourceType = $SourceType }
    foreach ($property in $InputObject.PSObject.Properties) {
        if ($property.MemberType -in @("Property", "NoteProperty", "AliasProperty", "ScriptProperty")) {
            $properties[$property.Name] = if ($null -eq $property.Value) { "" } else { $property.Value }
        }
    }

    return [pscustomobject]$properties
}

function Get-WinGetClientCommandName {
    param ([string[]]$Names)

    foreach ($name in $Names) {
        if (Get-Command -Name $name -ErrorAction SilentlyContinue) {
            return $name
        }
    }

    return ""
}

function Get-WinGetClientInstalledPackages {
    $records = @()
    $commandName = Get-WinGetClientCommandName -Names @("Get-WinGetPackage")
    if ([string]::IsNullOrWhiteSpace($commandName)) {
        return $records
    }

    try {
        & $commandName -ErrorAction Stop | ForEach-Object {
            $records += Convert-WingetObject -InputObject $_ -SourceType "Microsoft.WinGet.Client Package"
        }
    }
    catch {
        $message = "Could not collect installed packages with ${commandName}: $_"
        Write-Log -Level "WARN" -Message $message
        Add-CollectionError -Source $commandName -Message $message
    }

    return $records
}

function Get-WinGetClientAvailableUpdates {
    $records = @()
    $commandName = Get-WinGetClientCommandName -Names @("Get-WinGetPackage")
    if ([string]::IsNullOrWhiteSpace($commandName)) {
        return $records
    }

    try {
        & $commandName -ErrorAction Stop | Where-Object {
            ($_.PSObject.Properties.Name -contains "AvailableVersion" -and -not [string]::IsNullOrWhiteSpace([string]$_.AvailableVersion)) -or
            ($_.PSObject.Properties.Name -contains "IsUpdateAvailable" -and [bool]$_.IsUpdateAvailable)
        } | ForEach-Object {
            $records += Convert-WingetObject -InputObject $_ -SourceType "Microsoft.WinGet.Client Available Update"
        }
    }
    catch {
        $message = "Could not collect available updates with ${commandName}: $_"
        Write-Log -Level "WARN" -Message $message
        Add-CollectionError -Source $commandName -Message $message
    }

    return $records
}

function Parse-WingetUpgradeText {
    param ([string[]]$Lines)

    $records = @()
    $headerIndex = -1

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\s*Name\s+Id\s+Version\s+Available\s+Source\s*$') {
            $headerIndex = $i
            break
        }
    }

    if ($headerIndex -lt 0 -or ($headerIndex + 2) -ge $Lines.Count) {
        return $records
    }

    $header = $Lines[$headerIndex]
    $columns = [ordered]@{
        Name = $header.IndexOf("Name")
        Id = $header.IndexOf("Id")
        Version = $header.IndexOf("Version")
        Available = $header.IndexOf("Available")
        Source = $header.IndexOf("Source")
    }

    for ($i = $headerIndex + 2; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        if ($line -match '^\d+\s+upgrades?\s+available\.?$') {
            continue
        }

        if ($line -match '^\s*(No installed package found matching input criteria|No applicable update found|The following packages have an upgrade available)') {
            continue
        }

        if ($line.Length -lt $columns.Source) {
            continue
        }

        try {
            $records += [pscustomobject]@{
                SourceType = "winget.exe Available Update"
                Name = $line.Substring($columns.Name, $columns.Id - $columns.Name).Trim()
                Id = $line.Substring($columns.Id, $columns.Version - $columns.Id).Trim()
                Version = $line.Substring($columns.Version, $columns.Available - $columns.Version).Trim()
                Available = $line.Substring($columns.Available, $columns.Source - $columns.Available).Trim()
                Source = $line.Substring($columns.Source).Trim()
            }
        }
        catch {
            Write-Log -Level "WARN" -Message "Could not parse winget upgrade line: $line"
        }
    }

    return $records
}

function Add-CollectedFileRecord {
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
            Write-Log -Level "WARN" -Message "Could not read winget artifact metadata for ${DestinationPath}: $_"
        }

        try {
            $sha256 = (Get-FileHash -LiteralPath $DestinationPath -Algorithm SHA256 -ErrorAction Stop).Hash
        }
        catch {
            $hashMessage = "Could not calculate SHA256 for winget artifact '$DestinationPath': $_"
            Write-Log -Level "WARN" -Message $hashMessage
            if ([string]::IsNullOrWhiteSpace($Message)) {
                $Message = $hashMessage
            }
            else {
                $Message = "$Message $hashMessage"
            }
        }
    }

    $script:CollectedFileRecords += [pscustomobject]@{
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

function Export-CollectedFilesCsv {
    if ($CollectedFileRecords.Count -gt 0) {
        $recordsToWrite = @($CollectedFileRecords)
        if (Test-Path -LiteralPath $FilesCsvPath -PathType Leaf) {
            $existingRows = @(Import-Csv -Path $FilesCsvPath -ErrorAction SilentlyContinue)
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
            Write-Log -Level "DEBUG" -Message "No new winget rows to append to collected_files.csv."
            return
        }

        $csvExistsWithData = (Test-Path -LiteralPath $FilesCsvPath -PathType Leaf) -and ((Get-Item -LiteralPath $FilesCsvPath).Length -gt 0)
        if ($csvExistsWithData) {
            $recordsToWrite | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1 | Add-Content -Path $FilesCsvPath -Encoding UTF8
        }
        else {
            $recordsToWrite | Export-Csv -Path $FilesCsvPath -NoTypeInformation -Encoding UTF8
        }
    }
}

Write-Log -Message "Collecting installed software and available update information"

$wingetCommand = Get-Command -Name winget.exe -ErrorAction SilentlyContinue
$wingetClientModule = Get-Module -ListAvailable -Name Microsoft.WinGet.Client | Select-Object -First 1
$installedSoftware = @()
$availableUpdates = @()

$installedSoftware += @(Get-RegistryInstalledSoftware)
$installedSoftware += @(Get-AppxInstalledSoftware)
$installedSoftware += @(Get-PackageInstalledSoftware)

if ($wingetClientModule) {
    try {
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
        Write-Log -Level "DEBUG" -Message "Microsoft.WinGet.Client module is available: $($wingetClientModule.Version)"
        $installedSoftware += @(Get-WinGetClientInstalledPackages)
        $availableUpdates += @(Get-WinGetClientAvailableUpdates)
    }
    catch {
        $message = "Could not import Microsoft.WinGet.Client: $_"
        Write-Log -Level "WARN" -Message $message
        Add-CollectionError -Source "Microsoft.WinGet.Client" -Message $message
    }
}
else {
    Write-Log -Level "DEBUG" -Message "Microsoft.WinGet.Client module is not installed."
}

if ($wingetCommand) {
    Write-Log -Level "DEBUG" -Message "winget.exe found: $($wingetCommand.Source)"

    $sourceResult = Invoke-ExternalCommand -FilePath $wingetCommand.Source -Arguments @("source", "list", "--disable-interactivity") -RawOutputPath $WingetSourceListRawPath -SourceName "winget source list"
    $listResult = Invoke-ExternalCommand -FilePath $wingetCommand.Source -Arguments @("list", "--accept-source-agreements", "--disable-interactivity") -RawOutputPath $WingetListRawPath -SourceName "winget list"
    $upgradeResult = Invoke-ExternalCommand -FilePath $wingetCommand.Source -Arguments @("upgrade", "--accept-source-agreements", "--disable-interactivity") -RawOutputPath $WingetUpgradeRawPath -SourceName "winget upgrade"

    if ($upgradeResult.Output.Count -gt 0) {
        $availableUpdates += @(Parse-WingetUpgradeText -Lines $upgradeResult.Output)
    }
}
else {
    $message = "winget.exe is not available on this system or in this execution context."
    Write-Log -Level "WARN" -Message $message
    Add-CollectionError -Source "winget.exe" -Message $message
}

$environment = [pscustomobject]@{
    Collector = "winget"
    MachineName = $MachineName
    CollectionTime = (Get-Date).ToString("o")
    SourceRootSpecified = [bool]$SourceRootSpecified
    Force = [bool]$Force
    WingetExeAvailable = [bool]$wingetCommand
    WingetExePath = if ($wingetCommand) { [string]$wingetCommand.Source } else { "" }
    MicrosoftWinGetClientAvailable = [bool]$wingetClientModule
    MicrosoftWinGetClientVersion = if ($wingetClientModule) { [string]$wingetClientModule.Version } else { "" }
    InstalledSoftwareRecords = $installedSoftware.Count
    AvailableUpdateRecords = $availableUpdates.Count
    Errors = $CollectionErrors
}

$hasData = ($installedSoftware.Count -gt 0) -or ($availableUpdates.Count -gt 0) -or ($CollectionErrors.Count -gt 0)
if ($hasData) {
    Write-JsonFile -Path $InstalledSoftwareJsonPath -Data $installedSoftware
    Write-JsonFile -Path $AvailableUpdatesJsonPath -Data $availableUpdates
    Write-JsonFile -Path $EnvironmentJsonPath -Data $environment

    Add-CollectedFileRecord -SourceType "Winget JSON" -FullOriginalPath "Installed Software Inventory" -DestinationPath $InstalledSoftwareJsonPath -CollectionMethod "PowerShell inventory"
    Add-CollectedFileRecord -SourceType "Winget JSON" -FullOriginalPath "Available Software Updates" -DestinationPath $AvailableUpdatesJsonPath -CollectionMethod "Microsoft.WinGet.Client or winget.exe"
    Add-CollectedFileRecord -SourceType "Winget JSON" -FullOriginalPath "Winget Environment" -DestinationPath $EnvironmentJsonPath -CollectionMethod "PowerShell environment inventory"

    foreach ($rawPath in @($WingetListRawPath, $WingetUpgradeRawPath, $WingetSourceListRawPath)) {
        if (Test-Path -LiteralPath $rawPath -PathType Leaf) {
            Add-CollectedFileRecord -SourceType "Winget Raw Output" -FullOriginalPath ([System.IO.Path]::GetFileName($rawPath)) -DestinationPath $rawPath -CollectionMethod "winget.exe"
        }
    }

    Export-CollectedFilesCsv

    Write-Log -Message "Collection completed! Winget data is stored in: $WingetOutputRoot"
    Write-Log -Message "Installed software records collected: $($installedSoftware.Count)"
    Write-Log -Message "Available update records collected: $($availableUpdates.Count)"
    Write-Log -Message "Winget artifact files indexed: $($CollectedFileRecords.Count)"
}
else {
    Write-Log -Message "No winget data collected."
}

if ((-not $hasData) -and (Test-Path -LiteralPath $WingetOutputRoot -PathType Container)) {
    Remove-Item -LiteralPath $WingetOutputRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log -Message "No winget data collected. Removed empty winget folder: $WingetOutputRoot"
}
