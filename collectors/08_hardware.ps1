# -------------------------------
# Hardware Information Collection
# -------------------------------

<#
.SYNOPSIS
    Collects hardware inventory information from a live Windows system.

.DESCRIPTION
    08_hardware.ps1 collects live hardware inventory and writes a detailed JSON
    report under:
    <OutputRoot>\<MachineName>-<yyyyMMdd>\hardware

    The collector queries built-in CIM/WMI classes for motherboard/baseboard,
    BIOS, system enclosure, computer system, processors, memory modules, disks,
    volumes, display adapters, network adapters, TPM status, and selected OS
    context. It is live-only and does not perform offline collection.

    If -SourceRoot is explicitly specified, collection is skipped unless -Force
    is supplied.

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
    Removes existing hardware output folder before collecting. The shared
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
    .\08_hardware.ps1

    Collects hardware inventory from the live system.

.EXAMPLE
    .\08_hardware.ps1 -SourceRoot D:\MountedImage

    Skips live collection because SourceRoot was explicitly supplied.

.EXAMPLE
    .\08_hardware.ps1 -SourceRoot D:\MountedImage -Force

    Forces live collection even though SourceRoot was explicitly supplied.

.NOTES
    CHC Collector hardware collector. Uses built-in CIM/WMI queries and does
    not modify system hardware, firmware, or OS state.
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

function Show-HardwareHelp {
    Write-Host @"
08_hardware.ps1

Description:
  Collects live hardware inventory and stores JSON output under:
    <OutputRoot>\<MachineName>-<yyyyMMdd>\hardware

Outputs:
  - hardware/hardware_info.json
  - collected_files.csv entry for the generated JSON artifact

Collection logic:
  - Queries Win32_ComputerSystem, Win32_OperatingSystem, Win32_BIOS,
    Win32_BaseBoard, Win32_SystemEnclosure, Win32_Processor,
    Win32_PhysicalMemory, Win32_DiskDrive, Win32_LogicalDisk,
    Win32_VideoController, Win32_NetworkAdapter, Win32_NetworkAdapterConfiguration,
    and Win32_PnPEntity.
  - Attempts TPM collection from root\CIMV2\Security\MicrosoftTpm:Win32_Tpm.
  - Records serial numbers, model/manufacturer values, firmware details,
    CPU/memory/disk identity, MAC addresses, storage identifiers, and collection
    errors.
  - Does not modify hardware, firmware, OS, or licensing state.

Arguments:
  -OutputRoot <string>  Root folder for collection output.
  -SourceRoot <string>  Accepted for compatibility; skips live collection unless -Force.
  -Force                Force live collection when SourceRoot is specified.
  -MachineName <string> Machine name for output naming and log records.
  -Cleanup              Remove existing hardware output folder before collection.
  -ShowLog              Display log records on screen.
  -Log <string>         Shared log file path.
  -Help                 Display this help and exit.
"@
}

if ($Help) {
    Show-HardwareHelp
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
$HardwareOutputRoot = Join-Path $DestinationRoot "hardware"
$HardwareJsonPath = Join-Path $HardwareOutputRoot "hardware_info.json"
$FilesCsvPath = Join-Path $DestinationRoot "collected_files.csv"
$CollectedFileRecords = @()
$CollectionErrors = @()

function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $MachineName $Level hardware: $Message"

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

function Ensure-HardwareOutputRoot {
    if (-not (Test-Path -LiteralPath $HardwareOutputRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $HardwareOutputRoot -Force | Out-Null
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

function Get-CimData {
    param (
        [string]$ClassName,
        [string]$Namespace = "root\cimv2"
    )

    try {
        return @(Get-CimInstance -Namespace $Namespace -ClassName $ClassName -ErrorAction Stop)
    }
    catch {
        $message = "Could not query ${Namespace}:${ClassName}: $_"
        Write-Log -Level "WARN" -Message $message
        Add-CollectionError -Source "${Namespace}:${ClassName}" -Message $message
        return @()
    }
}

function Convert-CimObject {
    param (
        [object]$InputObject,
        [string[]]$Properties
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $values = [ordered]@{}
    foreach ($property in $Properties) {
        $value = ""
        if ($InputObject.PSObject.Properties.Name -contains $property) {
            $rawValue = $InputObject.$property
            if ($property -match "Date|Time") {
                $value = Convert-CimDateToIsoString -Value $rawValue
            }
            elseif ($rawValue -is [array]) {
                $value = @($rawValue)
            }
            elseif ($null -ne $rawValue) {
                $value = $rawValue
            }
        }

        $values[$property] = $value
    }

    return [pscustomobject]$values
}

function Write-JsonFile {
    param (
        [string]$Path,
        [object]$Data
    )

    Ensure-HardwareOutputRoot
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
            Write-Log -Level "WARN" -Message "Could not read hardware artifact metadata for ${DestinationPath}: $_"
        }

        try {
            $sha256 = (Get-FileHash -LiteralPath $DestinationPath -Algorithm SHA256 -ErrorAction Stop).Hash
        }
        catch {
            $hashMessage = "Could not calculate SHA256 for hardware artifact '$DestinationPath': $_"
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
            Write-Log -Level "DEBUG" -Message "No new hardware rows to append to collected_files.csv."
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
    if (Test-Path -LiteralPath $HardwareOutputRoot -PathType Container) {
        Write-Log -Message "Cleanup requested. Removing existing hardware output folder: $HardwareOutputRoot"
        Remove-Item -LiteralPath $HardwareOutputRoot -Recurse -Force
    }

    if (Test-Path -LiteralPath $FilesCsvPath -PathType Leaf) {
        Write-Log -Message "Cleanup requested. Preserving shared collected files CSV: $FilesCsvPath"
    }
}

if ($SourceRootSpecified -and (-not $Force)) {
    Write-Log -Message "SourceRoot was specified. Skipping hardware live collection."
    exit 0
}

if ($SourceRootSpecified -and $Force) {
    Write-Log -Level "DEBUG" -Message "Force was specified. Running hardware live collection even though SourceRoot was provided: $SourceRoot"
}

Write-Log -Message "Collecting hardware information"

$computerSystem = @(Get-CimData -ClassName Win32_ComputerSystem)
$operatingSystem = @(Get-CimData -ClassName Win32_OperatingSystem)
$bios = @(Get-CimData -ClassName Win32_BIOS)
$baseBoard = @(Get-CimData -ClassName Win32_BaseBoard)
$systemEnclosure = @(Get-CimData -ClassName Win32_SystemEnclosure)
$processor = @(Get-CimData -ClassName Win32_Processor)
$physicalMemory = @(Get-CimData -ClassName Win32_PhysicalMemory)
$diskDrive = @(Get-CimData -ClassName Win32_DiskDrive)
$logicalDisk = @(Get-CimData -ClassName Win32_LogicalDisk)
$videoController = @(Get-CimData -ClassName Win32_VideoController)
$networkAdapter = @(Get-CimData -ClassName Win32_NetworkAdapter | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.MACAddress) })
$networkAdapterConfig = @(Get-CimData -ClassName Win32_NetworkAdapterConfiguration | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.MACAddress) })
$pnpEntities = @(Get-CimData -ClassName Win32_PnPEntity | Where-Object {
    ([string]$_.PNPClass -in @("DiskDrive", "Display", "Media", "Monitor", "Net", "Processor", "System", "USB")) -or
    ([string]$_.Name -match "TPM|Trusted Platform|Serial|Storage|RAID|NVMe|SCSI|SATA")
})
$tpm = @(Get-CimData -Namespace "root\CIMV2\Security\MicrosoftTpm" -ClassName Win32_Tpm)

$report = [pscustomobject]@{
    Collector = "hardware"
    MachineName = $MachineName
    CollectionTime = (Get-Date).ToString("o")
    SourceRootSpecified = [bool]$SourceRootSpecified
    Force = [bool]$Force
    ComputerSystem = @($computerSystem | ForEach-Object {
        Convert-CimObject -InputObject $_ -Properties @(
            "Name", "DNSHostName", "Domain", "Manufacturer", "Model", "SystemType",
            "SystemFamily", "SystemSKUNumber", "TotalPhysicalMemory",
            "NumberOfProcessors", "NumberOfLogicalProcessors", "HypervisorPresent",
            "PartOfDomain", "PrimaryOwnerName", "UserName", "Workgroup"
        )
    })
    OperatingSystem = @($operatingSystem | ForEach-Object {
        Convert-CimObject -InputObject $_ -Properties @(
            "Caption", "Version", "BuildNumber", "OSArchitecture", "SerialNumber",
            "InstallDate", "LastBootUpTime", "WindowsDirectory", "SystemDirectory"
        )
    })
    BIOS = @($bios | ForEach-Object {
        Convert-CimObject -InputObject $_ -Properties @(
            "Manufacturer", "Name", "Description", "Version", "SMBIOSBIOSVersion",
            "SerialNumber", "ReleaseDate", "InstallDate", "PrimaryBIOS",
            "SMBIOSMajorVersion", "SMBIOSMinorVersion", "EmbeddedControllerMajorVersion",
            "EmbeddedControllerMinorVersion"
        )
    })
    BaseBoard = @($baseBoard | ForEach-Object {
        Convert-CimObject -InputObject $_ -Properties @(
            "Manufacturer", "Product", "SerialNumber", "Version", "Model", "PartNumber",
            "SKU", "Tag"
        )
    })
    SystemEnclosure = @($systemEnclosure | ForEach-Object {
        Convert-CimObject -InputObject $_ -Properties @(
            "Manufacturer", "Model", "SerialNumber", "SMBIOSAssetTag", "ChassisTypes",
            "Version", "PartNumber", "Tag"
        )
    })
    Processors = @($processor | ForEach-Object {
        Convert-CimObject -InputObject $_ -Properties @(
            "Name", "Manufacturer", "ProcessorId", "SocketDesignation", "Architecture",
            "AddressWidth", "NumberOfCores", "NumberOfLogicalProcessors",
            "MaxClockSpeed", "CurrentClockSpeed", "L2CacheSize", "L3CacheSize"
        )
    })
    PhysicalMemory = @($physicalMemory | ForEach-Object {
        Convert-CimObject -InputObject $_ -Properties @(
            "BankLabel", "DeviceLocator", "Manufacturer", "PartNumber", "SerialNumber",
            "Capacity", "Speed", "ConfiguredClockSpeed", "MemoryType", "SMBIOSMemoryType",
            "FormFactor", "DataWidth", "TotalWidth", "Tag"
        )
    })
    DiskDrives = @($diskDrive | ForEach-Object {
        Convert-CimObject -InputObject $_ -Properties @(
            "Model", "Manufacturer", "SerialNumber", "FirmwareRevision", "InterfaceType",
            "MediaType", "Size", "Partitions", "BytesPerSector", "Index",
            "DeviceID", "PNPDeviceID", "Status"
        )
    })
    LogicalDisks = @($logicalDisk | ForEach-Object {
        Convert-CimObject -InputObject $_ -Properties @(
            "DeviceID", "DriveType", "FileSystem", "VolumeName", "VolumeSerialNumber",
            "Size", "FreeSpace", "ProviderName"
        )
    })
    VideoControllers = @($videoController | ForEach-Object {
        Convert-CimObject -InputObject $_ -Properties @(
            "Name", "AdapterCompatibility", "AdapterDACType", "AdapterRAM",
            "DriverVersion", "DriverDate", "VideoProcessor", "PNPDeviceID", "Status"
        )
    })
    NetworkAdapters = @($networkAdapter | ForEach-Object {
        Convert-CimObject -InputObject $_ -Properties @(
            "Name", "NetConnectionID", "Manufacturer", "MACAddress", "AdapterType",
            "Speed", "PhysicalAdapter", "PNPDeviceID", "ServiceName", "Status",
            "NetEnabled"
        )
    })
    NetworkAdapterConfigurations = @($networkAdapterConfig | ForEach-Object {
        Convert-CimObject -InputObject $_ -Properties @(
            "Description", "MACAddress", "DHCPEnabled", "DHCPServer", "IPAddress",
            "IPSubnet", "DefaultIPGateway", "DNSServerSearchOrder", "DNSHostName",
            "DNSDomain", "IPEnabled"
        )
    })
    TPM = @($tpm | ForEach-Object {
        Convert-CimObject -InputObject $_ -Properties @(
            "IsActivated_InitialValue", "IsEnabled_InitialValue", "IsOwned_InitialValue",
            "ManufacturerId", "ManufacturerIdTxt", "ManufacturerVersion",
            "ManufacturerVersionFull20", "PhysicalPresenceVersionInfo",
            "SpecVersion"
        )
    })
    PnPEntities = @($pnpEntities | ForEach-Object {
        Convert-CimObject -InputObject $_ -Properties @(
            "Name", "Caption", "Manufacturer", "PNPClass", "DeviceID", "PNPDeviceID",
            "Service", "Status", "ConfigManagerErrorCode"
        )
    })
    Errors = $CollectionErrors
}

$hasData = ($computerSystem.Count -gt 0) -or ($bios.Count -gt 0) -or ($baseBoard.Count -gt 0) -or ($systemEnclosure.Count -gt 0) -or ($CollectionErrors.Count -gt 0)
if ($hasData) {
    Write-JsonFile -Path $HardwareJsonPath -Data $report
    Add-CollectedFileRecord -SourceType "Hardware JSON" -FullOriginalPath "Live Hardware Inventory" -DestinationPath $HardwareJsonPath -CollectionMethod "CIM/WMI hardware inventory"
    Export-CollectedFilesCsv

    Write-Log -Message "Collection completed! Hardware data is stored in: $HardwareOutputRoot"
    Write-Log -Message "Computer system records: $($computerSystem.Count)"
    Write-Log -Message "BIOS records: $($bios.Count)"
    Write-Log -Message "Baseboard records: $($baseBoard.Count)"
    Write-Log -Message "Disk drive records: $($diskDrive.Count)"
    Write-Log -Message "Network adapter records: $($networkAdapter.Count)"
    Write-Log -Message "Hardware artifact files indexed: $($CollectedFileRecords.Count)"
}
else {
    Write-Log -Message "No hardware data collected."
}

if ((-not $hasData) -and (Test-Path -LiteralPath $HardwareOutputRoot -PathType Container)) {
    Remove-Item -LiteralPath $HardwareOutputRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log -Message "No hardware data collected. Removed empty hardware folder: $HardwareOutputRoot"
}
