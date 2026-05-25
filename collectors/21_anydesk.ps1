# -------------------------------
# AnyDesk Log Collection with Hostname Folder
# -------------------------------

<#
.SYNOPSIS
    Collects AnyDesk logs, configuration files, traces, cache, and related data.

.DESCRIPTION
    21_anydesk.ps1 collects AnyDesk artifacts from ProgramData, user profiles,
    the system profile, and Windows temp locations into
    <OutputRoot>\<MachineName>-<yyyyMMdd>\anydesk. It scans known AnyDesk
    directories below -SourceRoot, copies relevant files, preserves
    source-relative paths, and creates a CSV index.

    Relevant files include *.ini, *.log, *.txt, *.ad, *conf, and *trace files,
    plus all files under AnyDesk cache and thumbnails directories. Discovered
    non-matching files are indexed with Collected=No. Collected files include a
    SHA256 hash in the CSV index when hash calculation succeeds.

.PARAMETER OutputRoot
    Root folder for collection output. If specified, output goes directly under
    <OutputRoot>\<MachineName>-<yyyyMMdd>. If omitted, output goes under the
    collector parent output folder.

.PARAMETER SourceRoot
    Filesystem root to collect from. Defaults to C:. Supports mounted/offline
    roots such as D:\MountedImage.

.PARAMETER MachineName
    Machine name used for output folder naming and log records. Defaults to the
    current COMPUTERNAME.

.PARAMETER Cleanup
    Removes existing AnyDesk output and AnyDesk CSV files for the current
    MachineName/date before collecting.

.PARAMETER ShowLog
    Displays AnyDesk collector log records on screen while also writing them
    to -Log when -Log is supplied.

.PARAMETER Log
    Shared log file path. When supplied, AnyDesk collector records are appended
    to this file.

.PARAMETER Help
    Displays collector help and exits without collecting data.

.EXAMPLE
    .\collectors\21_anydesk.ps1 -OutputRoot E:\Collections -MachineName HOST01 -SourceRoot D:\MountedImage

    Collects AnyDesk artifacts from the mounted image root and writes output
    under E:\Collections\HOST01-<yyyyMMdd>\anydesk.

.EXAMPLE
    .\collectors\21_anydesk.ps1 -Log .\output\HOST01-20260523_master.log -ShowLog

    Collects AnyDesk artifacts from C:, appends records to the shared log, and
    mirrors log records to the console.

.NOTES
    Source locations include ProgramData\AnyDesk, user AppData Local/Roaming
    AnyDesk folders, the system profile AnyDesk folder, and Windows\Temp\AnyDesk.
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

function Show-AnyDeskHelp {
    Write-Host @"
21_anydesk.ps1

Description:
  Collects AnyDesk configuration, log, cache, trace, and related artifacts from
  ProgramData, user profiles, system profile, and Windows temp locations.

Arguments:
  -OutputRoot <string>
      Root folder for collection output. If specified, output goes directly
      under <OutputRoot>\<MachineName>-<yyyyMMdd>. If omitted, output goes under
      <collector parent>\output\<MachineName>-<yyyyMMdd>.

  -SourceRoot <string>
      Filesystem root to collect from. Default: C:. Supports mounted/offline
      roots such as D:\MountedImage.

  -MachineName <string>
      Machine name used for output folder naming and log records. Default:
      current COMPUTERNAME.

  -Cleanup
      Remove existing AnyDesk output and AnyDesk CSV for the current
      MachineName/date before collection.

  -ShowLog
      Display AnyDesk collector log records on screen while also writing them
      to -Log when -Log is supplied.

  -Log <string>
      Shared log file path. When supplied, AnyDesk log records are appended to
      this file.

  -Help
      Display this help and exit without collecting data.

Technical collection logic:
  Source locations:
    - <SourceRoot>\ProgramData\AnyDesk
    - <SourceRoot>\Users\<profile>\AppData\Local\AnyDesk
    - <SourceRoot>\Users\<profile>\AppData\Roaming\AnyDesk
    - <SourceRoot>\Windows\SysWOW64\config\systemprofile\AppData\Roaming\AnyDesk
    - <SourceRoot>\Windows\Temp\AnyDesk

  File selection:
    - Collects files matching: *.ini, *.log, *.txt, *.ad, *conf, *trace.
    - Also collects all files under AnyDesk cache and thumbnails subfolders.
    - Non-matching files are indexed but marked Collected=No.

  Output:
    - Copies selected files into:
      <OutputRoot>\<MachineName>-<yyyyMMdd>\anydesk\<source-relative-path>
    - Preserves source-relative paths below SourceRoot.

  Index output:
    - collected_files.csv records every discovered file with source type, original
      path, destination path, timestamps, size, attributes, SHA256 when
      calculated, collected status, collection method, and message.
"@
}

if ($Help) {
    Show-AnyDeskHelp
    exit 0
}

# ===== CONFIGURATION =====
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

$UsersPath = Join-Path $SourceRoot "Users"
$ProgramDataPath = Join-Path $SourceRoot "ProgramData\AnyDesk"
$SystemProfilePath = Join-Path $SourceRoot "Windows\SysWOW64\config\systemprofile\AppData\Roaming\AnyDesk"
$TempPaths = @(Join-Path $SourceRoot "Windows\Temp\AnyDesk")

# ===== GET HOSTNAME & DATE =====
$hostnameRaw = $MachineName
$hostnameSafe = ($hostnameRaw -replace '[^a-zA-Z0-9\-]', '_') # replace special chars
$dateString = Get-Date -Format "yyyyMMdd"
$DestinationRoot = Join-Path $BaseDestination "$hostnameSafe-$dateString"
$AnyDeskOutputRoot = Join-Path $DestinationRoot "anydesk"
$CsvPath = Join-Path $DestinationRoot "collected_files.csv"
$CollectedFileRecords = @()
$SeenFilePaths = @{}
$CsvColumns = @(
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
    $logMessage = "[$timestamp] $MachineName $Level anydesk: $Message"

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
    if (Test-Path -LiteralPath $AnyDeskOutputRoot -PathType Container) {
        Write-Log -Message "Cleanup requested. Removing existing AnyDesk output folder: $AnyDeskOutputRoot"
        Remove-Item -LiteralPath $AnyDeskOutputRoot -Recurse -Force
    }

    if (Test-Path -LiteralPath $CsvPath -PathType Leaf) {
        Write-Log -Message "Cleanup requested. Preserving shared collected files CSV: $CsvPath"
    }
}

# ===== HELPER FUNCTION =====
function Get-SourceRelativePath {
    param ([string]$SourcePath)

    $sourceFullPath = [System.IO.Path]::GetFullPath($SourcePath)
    if ($sourceFullPath.StartsWith($SourceRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $sourceFullPath.Substring($SourceRootPrefix.Length)
    }

    return (($SourcePath -replace ":", "") -replace "\\", "\")
}

function Test-RelevantAnyDeskFile {
    param (
        [System.IO.FileInfo]$File,
        [string]$SourcePath
    )

    $anyDeskFilePatterns = @("*.ini", "*.log", "*.txt", "*.ad", "*conf", "*trace")

    foreach ($pattern in $anyDeskFilePatterns) {
        if ($File.Name -like $pattern) {
            return $true
        }
    }

    $fileFullPath = [System.IO.Path]::GetFullPath($File.FullName)
    $cachePrefix = [System.IO.Path]::GetFullPath((Join-Path $SourcePath "cache")).TrimEnd('\') + "\"
    if ($fileFullPath.StartsWith($cachePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $thumbnailsPrefix = [System.IO.Path]::GetFullPath((Join-Path $SourcePath "thumbnails")).TrimEnd('\') + "\"
    if ($fileFullPath.StartsWith($thumbnailsPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    return $false
}

function Add-AnyDeskFileRecord {
    param (
        [System.IO.FileInfo]$File,
        [string]$DestinationPath = "",
        [string]$Collected,
        [string]$SHA256 = "",
        [string]$CollectionMethod = "",
        [string]$Message = ""
    )

    $script:CollectedFileRecords += [pscustomobject]@{
        "Source Type"        = "AnyDesk File"
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

function Copy-AnyDeskFile {
    param (
        [System.IO.FileInfo]$File,
        [string]$SourcePath
    )

    if ($script:SeenFilePaths.ContainsKey($File.FullName)) {
        return
    }
    $script:SeenFilePaths[$File.FullName] = $true

    $collected = "No"
    if (-not (Test-RelevantAnyDeskFile -File $File -SourcePath $SourcePath)) {
        Add-AnyDeskFileRecord -File $File -Collected $collected -Message "File did not match AnyDesk collection patterns."
        return
    }

    $sha256 = ""
    $collectionMethod = ""
    $message = ""
    $relativePath = Get-SourceRelativePath -SourcePath $File.FullName
    $destPath = Join-Path $AnyDeskOutputRoot $relativePath
    $destParent = Split-Path -Path $destPath -Parent
    if (-not (Test-Path -LiteralPath $destParent -PathType Container)) {
        New-Item -ItemType Directory -Path $destParent -Force | Out-Null
    }

    try {
        Copy-Item -LiteralPath $File.FullName -Destination $destPath -Force -ErrorAction Stop
        $collected = "Yes"
        $collectionMethod = "Copy-Item"
        $message = "Copied successfully."
    }
    catch {
        $collected = "No"
        $message = "Copy-Item failed: $_"
        Write-Log -Level "WARN" -Message "Could not collect $($File.FullName): $_"
    }

    if ($collected -eq "Yes") {
        try {
            $sha256 = (Get-FileHash -LiteralPath $destPath -Algorithm SHA256 -ErrorAction Stop).Hash
        }
        catch {
            Write-Log -Level "WARN" -Message "Could not calculate SHA256 for ${destPath}: $_"
        }
    }

    Add-AnyDeskFileRecord -File $File -DestinationPath $destPath -Collected $collected -SHA256 $sha256 -CollectionMethod $collectionMethod -Message $message
}

function Copy-AnyDeskLogs {
    param ([string]$SourcePath)
    if (Test-Path -LiteralPath $SourcePath -PathType Container) {
        Write-Log -Message "Collecting logs from $SourcePath"
        Get-ChildItem -LiteralPath $SourcePath -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-AnyDeskFile -File $_ -SourcePath $SourcePath
        }
    }
}

function Export-AnyDeskCsv {
    $csvExistsWithData = (Test-Path -LiteralPath $CsvPath -PathType Leaf) -and ((Get-Item -LiteralPath $CsvPath).Length -gt 0)

    if ($CollectedFileRecords.Count -gt 0) {
        if ($csvExistsWithData) {
            $CollectedFileRecords | Select-Object $CsvColumns | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1 | Add-Content -Path $CsvPath -Encoding UTF8
        }
        else {
            $CollectedFileRecords | Select-Object $CsvColumns | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
        }
    }
}

# ===== 1. ProgramData =====
Copy-AnyDeskLogs -SourcePath $ProgramDataPath

# ===== 2. User Profiles =====
if (Test-Path -LiteralPath $UsersPath -PathType Container) {
    Get-ChildItem -LiteralPath $UsersPath -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $userAnyDeskLocal = Join-Path $_.FullName "AppData\Local\AnyDesk"
        $userAnyDeskRoaming = Join-Path $_.FullName "AppData\Roaming\AnyDesk"
        Copy-AnyDeskLogs -SourcePath $userAnyDeskLocal
        Copy-AnyDeskLogs -SourcePath $userAnyDeskRoaming
    }
}

# ===== 3. SYSTEM Profile =====
Copy-AnyDeskLogs -SourcePath $SystemProfilePath

# ===== 4. Temp Folders =====
foreach ($tempPath in $TempPaths) {
    Copy-AnyDeskLogs -SourcePath $tempPath
}

Export-AnyDeskCsv

Write-Log -Message "Collection completed! Logs are stored in: $AnyDeskOutputRoot"
Write-Log -Message "Files collected/found: $(($CollectedFileRecords | Where-Object { $_.Collected -eq "Yes" }).Count)/$($CollectedFileRecords.Count)"
