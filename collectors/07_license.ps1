# -------------------------------
# Windows License Collection
# -------------------------------

<#
.SYNOPSIS
    Collects Windows licensing state from a live Windows system.

.DESCRIPTION
    07_license.ps1 collects live Windows licensing information and writes a
    detailed JSON report under:
    <OutputRoot>\<MachineName>-<yyyyMMdd>\license

    The collector queries SoftwareLicensingService and SoftwareLicensingProduct
    through CIM/WMI, checks the embedded OEM product key exposed by BIOS/UEFI
    through OA3xOriginalProductKey, and records selected OS inventory fields.

    This collector is live-only. If -SourceRoot is explicitly specified,
    collection is skipped unless -Force is supplied.

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
    Removes existing license output folder before collecting. The shared
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
    .\07_license.ps1

    Collects Windows license and embedded OEM key information from the live
    system.

.EXAMPLE
    .\07_license.ps1 -SourceRoot D:\MountedImage

    Skips live collection because SourceRoot was explicitly supplied.

.EXAMPLE
    .\07_license.ps1 -SourceRoot D:\MountedImage -Force

    Forces live collection even though SourceRoot was explicitly supplied.

.NOTES
    CHC Collector license collector. Uses built-in CIM/WMI classes and does not
    modify activation or licensing state.
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

function Show-LicenseHelp {
    Write-Host @"
07_license.ps1

Description:
  Collects Windows license state from the live system and stores JSON output
  under:
    <OutputRoot>\<MachineName>-<yyyyMMdd>\license

Outputs:
  - license/license_status.json
  - collected_files.csv entry for the generated JSON artifact

Collection logic:
  - Queries Win32_OperatingSystem for OS caption, version, build, install date,
    architecture, serial number, and product type.
  - Queries SoftwareLicensingService for activation service details, partial
    product key, KMS/client configuration fields, grace period, and
    OA3xOriginalProductKey embedded OEM key when available.
  - Queries SoftwareLicensingProduct for Windows licensing products and records
    license status, application ID, product key channel, description, partial
    product key, grace period, and activation IDs.
  - Does not run activation commands and does not change license state.

Arguments:
  -OutputRoot <string>  Root folder for collection output.
  -SourceRoot <string>  Accepted for compatibility; skips live collection unless -Force.
  -Force                Force live collection when SourceRoot is specified.
  -MachineName <string> Machine name for output naming and log records.
  -Cleanup              Remove existing license output folder before collection.
  -ShowLog              Display log records on screen.
  -Log <string>         Shared log file path.
  -Help                 Display this help and exit.
"@
}

if ($Help) {
    Show-LicenseHelp
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
$LicenseOutputRoot = Join-Path $DestinationRoot "license"
$LicenseJsonPath = Join-Path $LicenseOutputRoot "license_status.json"
$FilesCsvPath = Join-Path $DestinationRoot "collected_files.csv"
$CollectedFileRecords = @()
$CollectionErrors = @()

function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $MachineName $Level license: $Message"

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

function Convert-LicenseStatus {
    param ([object]$Value)

    switch ([int]$Value) {
        0 { "Unlicensed" }
        1 { "Licensed" }
        2 { "Out-of-Box Grace Period" }
        3 { "Out-of-Tolerance Grace Period" }
        4 { "Non-Genuine Grace Period" }
        5 { "Notification" }
        6 { "Extended Grace Period" }
        default { "Unknown ($Value)" }
    }
}

function Convert-ProductType {
    param ([object]$Value)

    switch ([int]$Value) {
        1 { "Workstation" }
        2 { "Domain Controller" }
        3 { "Server" }
        default { "Unknown ($Value)" }
    }
}

function Ensure-LicenseOutputRoot {
    if (-not (Test-Path -LiteralPath $LicenseOutputRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $LicenseOutputRoot -Force | Out-Null
    }
}

function Write-JsonFile {
    param (
        [string]$Path,
        [object]$Data
    )

    Ensure-LicenseOutputRoot
    ConvertTo-Json -InputObject $Data -Depth 12 | Set-Content -Path $Path -Encoding UTF8
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
            Write-Log -Level "WARN" -Message "Could not read license artifact metadata for ${DestinationPath}: $_"
        }

        try {
            $sha256 = (Get-FileHash -LiteralPath $DestinationPath -Algorithm SHA256 -ErrorAction Stop).Hash
        }
        catch {
            $hashMessage = "Could not calculate SHA256 for license artifact '$DestinationPath': $_"
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
            Write-Log -Level "DEBUG" -Message "No new license rows to append to collected_files.csv."
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

if ($Cleanup) {
    if (Test-Path -LiteralPath $LicenseOutputRoot -PathType Container) {
        Write-Log -Message "Cleanup requested. Removing existing license output folder: $LicenseOutputRoot"
        Remove-Item -LiteralPath $LicenseOutputRoot -Recurse -Force
    }

    if (Test-Path -LiteralPath $FilesCsvPath -PathType Leaf) {
        Write-Log -Message "Cleanup requested. Preserving shared collected files CSV: $FilesCsvPath"
    }
}

if ($SourceRootSpecified -and (-not $Force)) {
    Write-Log -Message "SourceRoot was specified. Skipping license live collection."
    exit 0
}

if ($SourceRootSpecified -and $Force) {
    Write-Log -Level "DEBUG" -Message "Force was specified. Running license live collection even though SourceRoot was provided: $SourceRoot"
}

Write-Log -Message "Collecting Windows license information"

$operatingSystem = $null
$licensingService = $null
$licensingProducts = @()

try {
    $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
}
catch {
    $message = "Could not query Win32_OperatingSystem: $_"
    Write-Log -Level "WARN" -Message $message
    Add-CollectionError -Source "Win32_OperatingSystem" -Message $message
}

try {
    $licensingService = Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop
}
catch {
    $message = "Could not query SoftwareLicensingService: $_"
    Write-Log -Level "WARN" -Message $message
    Add-CollectionError -Source "SoftwareLicensingService" -Message $message
}

try {
    $licensingProducts = @(Get-CimInstance -ClassName SoftwareLicensingProduct -ErrorAction Stop |
        Where-Object {
            ($_.ApplicationID -eq "55c92734-d682-4d71-983e-d6ec3f16059f") -or
            ([string]$_.Name -match "Windows")
        } |
        Sort-Object Name, PartialProductKey)
}
catch {
    $message = "Could not query SoftwareLicensingProduct: $_"
    Write-Log -Level "WARN" -Message $message
    Add-CollectionError -Source "SoftwareLicensingProduct" -Message $message
}

$osRecord = if ($operatingSystem) {
    [pscustomobject]@{
        Caption = [string]$operatingSystem.Caption
        Version = [string]$operatingSystem.Version
        BuildNumber = [string]$operatingSystem.BuildNumber
        OSArchitecture = [string]$operatingSystem.OSArchitecture
        ProductType = Convert-ProductType -Value $operatingSystem.ProductType
        ProductTypeValue = [string]$operatingSystem.ProductType
        SerialNumber = [string]$operatingSystem.SerialNumber
        RegisteredUser = [string]$operatingSystem.RegisteredUser
        Organization = [string]$operatingSystem.Organization
        InstallDate = Convert-CimDateToIsoString -Value $operatingSystem.InstallDate
        LastBootUpTime = Convert-CimDateToIsoString -Value $operatingSystem.LastBootUpTime
        WindowsDirectory = [string]$operatingSystem.WindowsDirectory
        SystemDirectory = [string]$operatingSystem.SystemDirectory
    }
}
else {
    $null
}

$serviceRecord = if ($licensingService) {
    [pscustomobject]@{
        Version = [string]$licensingService.Version
        ClientMachineID = [string]$licensingService.ClientMachineID
        KeyManagementServiceMachine = [string]$licensingService.KeyManagementServiceMachine
        KeyManagementServicePort = [string]$licensingService.KeyManagementServicePort
        DiscoveredKeyManagementServiceMachineName = [string]$licensingService.DiscoveredKeyManagementServiceMachineName
        DiscoveredKeyManagementServiceMachinePort = [string]$licensingService.DiscoveredKeyManagementServiceMachinePort
        IsKeyManagementServiceMachine = [string]$licensingService.IsKeyManagementServiceMachine
        KeyManagementServiceCurrentCount = [string]$licensingService.KeyManagementServiceCurrentCount
        KeyManagementServiceLicensedRequests = [string]$licensingService.KeyManagementServiceLicensedRequests
        KeyManagementServiceUnlicensedRequests = [string]$licensingService.KeyManagementServiceUnlicensedRequests
        KeyManagementServiceNotificationRequests = [string]$licensingService.KeyManagementServiceNotificationRequests
        RemainingWindowsReArmCount = [string]$licensingService.RemainingWindowsReArmCount
        PolicyCacheRefreshRequired = [string]$licensingService.PolicyCacheRefreshRequired
        PartialProductKey = [string]$licensingService.PartialProductKey
        OA3xOriginalProductKey = [string]$licensingService.OA3xOriginalProductKey
        OA3xOriginalProductKeyDescription = [string]$licensingService.OA3xOriginalProductKeyDescription
        EmbeddedOemKeyPresent = -not [string]::IsNullOrWhiteSpace([string]$licensingService.OA3xOriginalProductKey)
    }
}
else {
    $null
}

$productRecords = @($licensingProducts | ForEach-Object {
    [pscustomobject]@{
        Name = [string]$_.Name
        Description = [string]$_.Description
        ApplicationID = [string]$_.ApplicationID
        ID = [string]$_.ID
        LicenseFamily = [string]$_.LicenseFamily
        ProductKeyChannel = [string]$_.ProductKeyChannel
        LicenseStatus = Convert-LicenseStatus -Value $_.LicenseStatus
        LicenseStatusValue = [string]$_.LicenseStatus
        LicenseStatusReason = [string]$_.LicenseStatusReason
        PartialProductKey = [string]$_.PartialProductKey
        ProductKeyID = [string]$_.ProductKeyID
        GracePeriodRemaining = [string]$_.GracePeriodRemaining
        EvaluationEndDate = Convert-CimDateToIsoString -Value $_.EvaluationEndDate
        VLActivationInterval = [string]$_.VLActivationInterval
        VLRenewalInterval = [string]$_.VLRenewalInterval
        KeyManagementServiceMachine = [string]$_.KeyManagementServiceMachine
        KeyManagementServicePort = [string]$_.KeyManagementServicePort
        DiscoveredKeyManagementServiceMachineName = [string]$_.DiscoveredKeyManagementServiceMachineName
        DiscoveredKeyManagementServiceMachinePort = [string]$_.DiscoveredKeyManagementServiceMachinePort
    }
})

$licensedWindowsProducts = @($productRecords | Where-Object { $_.LicenseStatusValue -eq "1" })
$report = [pscustomobject]@{
    Collector = "license"
    MachineName = $MachineName
    CollectionTime = (Get-Date).ToString("o")
    SourceRootSpecified = [bool]$SourceRootSpecified
    Force = [bool]$Force
    IsWindowsLicensed = ($licensedWindowsProducts.Count -gt 0)
    LicensedWindowsProducts = $licensedWindowsProducts
    OperatingSystem = $osRecord
    SoftwareLicensingService = $serviceRecord
    SoftwareLicensingProducts = $productRecords
    Errors = $CollectionErrors
}

$hasData = ($null -ne $osRecord) -or ($null -ne $serviceRecord) -or ($productRecords.Count -gt 0) -or ($CollectionErrors.Count -gt 0)
if ($hasData) {
    Write-JsonFile -Path $LicenseJsonPath -Data $report
    Add-CollectedFileRecord -SourceType "License JSON" -FullOriginalPath "Windows License State" -DestinationPath $LicenseJsonPath -CollectionMethod "CIM SoftwareLicensingService/SoftwareLicensingProduct"
    Export-CollectedFilesCsv

    Write-Log -Message "Collection completed! License data is stored in: $LicenseOutputRoot"
    Write-Log -Message "Windows licensed: $($report.IsWindowsLicensed)"
    if ($serviceRecord) {
        Write-Log -Message "Embedded OEM key present: $($serviceRecord.EmbeddedOemKeyPresent)"
    }
    Write-Log -Message "License products recorded: $($productRecords.Count)"
    Write-Log -Message "License artifact files indexed: $($CollectedFileRecords.Count)"
}
else {
    Write-Log -Message "No license data collected."
}

if ((-not $hasData) -and (Test-Path -LiteralPath $LicenseOutputRoot -PathType Container)) {
    Remove-Item -LiteralPath $LicenseOutputRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log -Message "No license data collected. Removed empty license folder: $LicenseOutputRoot"
}
