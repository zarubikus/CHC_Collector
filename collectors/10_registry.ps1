# -------------------------------
# Registry Collection with Hostname Folder
# -------------------------------

<#
.SYNOPSIS
    Collects Windows registry artifacts from offline files and live hives.

.DESCRIPTION
    10_registry.ps1 collects registry evidence into
    <OutputRoot>\<MachineName>-<yyyyMMdd>\registry. When -SourceRoot is
    explicitly supplied, it copies offline registry hive files and related
    transaction/log files from the supplied filesystem root and skips live
    collection. When -SourceRoot is not supplied, it attempts live registry
    collection using reg.exe save for selected HKLM hives and copies live user
    profile registry hive files.

    The collector creates a CSV index for copied registry files and live
    registry save attempts. The index includes source type, original path,
    destination path, timestamps, size, attributes, SHA256, collection status,
    collection method, and message.

.PARAMETER OutputRoot
    Root folder for collection output. If specified, output goes directly under
    <OutputRoot>\<MachineName>-<yyyyMMdd>. If omitted, output goes under the
    collector parent output folder.

.PARAMETER SourceRoot
    Offline filesystem root. When explicitly specified, offline hive files are
    copied from this root. Examples: C: or D:\MountedImage.

.PARAMETER MachineName
    Machine name used for output folder naming and log records. Defaults to the
    current COMPUTERNAME.

.PARAMETER Cleanup
    Removes existing registry output and registry CSV files for the current
    MachineName/date before collecting.

.PARAMETER ShowLog
    Displays registry collector log records on screen while also writing them
    to -Log when -Log is supplied.

.PARAMETER Log
    Shared log file path. When supplied, registry collector log records are
    appended to this file.

.PARAMETER Help
    Displays collector help and exits without collecting data.

.EXAMPLE
    .\collectors\10_registry.ps1 -OutputRoot E:\Collections -MachineName HOST01 -SourceRoot D:\MountedImage

    Copies offline registry hive files from D:\MountedImage, writing output
    under E:\Collections\HOST01-<yyyyMMdd>.

.EXAMPLE
    .\collectors\10_registry.ps1 -Log .\output\HOST01-20260523_master.log -ShowLog

    Attempts live registry collection because -SourceRoot is not supplied,
    appends records to the shared log, and mirrors log records to the console.

.NOTES
    Offline sources include relevant Windows\System32\config hive files, user
    NTUSER.DAT files, user UsrClass.dat files, and service profile hive files.
    Filename matching is case-insensitive. Live collection uses reg.exe save
    and may require Administrator privileges.
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

function Show-RegistryHelp {
    Write-Host @"
10_registry.ps1

Description:
  Collects Windows registry artifacts. When -SourceRoot is specified, it copies
  offline registry hive files from that filesystem root and skips live
  collection. When -SourceRoot is not specified, it attempts live registry hive
      collection from the running system using reg.exe save.

Arguments:
  -OutputRoot <string>
      Root folder for collection output. If specified, output goes directly
      under <OutputRoot>\<MachineName>-<yyyyMMdd>. If omitted, output goes under
      <collector parent>\output\<MachineName>-<yyyyMMdd>.

  -SourceRoot <string>
      Offline filesystem root. When specified, the collector copies registry
      hive files from this root. Example: C: or D:\MountedImage.

  -MachineName <string>
      Machine name used for output folder naming and log records. Default:
      current COMPUTERNAME.

  -Cleanup
      Remove existing registry output and registry CSV files for the current
      MachineName/date before collection.

  -ShowLog
      Display registry collector log records on screen while also writing them
      to -Log when -Log is supplied.

  -Log <string>
      Shared log file path. When supplied, registry log records are appended to
      this file.

  -Help
      Display this help and exit without collecting data.

Technical collection logic:
  Offline hive file copy, only when -SourceRoot is explicitly specified:
    - Source: <SourceRoot>\Windows\System32\config
      Patterns, case-insensitive: SAM, SECURITY, SOFTWARE, SYSTEM, DEFAULT,
      COMPONENTS, DRIVERS, BCD, and their sidecar files such as .LOG, .LOG1,
      .LOG2, .sav, .blf, and .regtrans-ms.
    - Source: <SourceRoot>\Users\<profile>
      Patterns, case-insensitive: NTUSER.DAT, NTUSER.DAT.*, ntuser.ini.
    - Source: <SourceRoot>\Users\<profile>\AppData\Local\Microsoft\Windows
      Patterns: UsrClass.dat, UsrClass.dat.*.
    - Source: <SourceRoot>\Windows\ServiceProfiles\<profile>
      Patterns, case-insensitive: NTUSER.DAT, NTUSER.DAT.*, ntuser.ini.
    - Source: <SourceRoot>\Windows\ServiceProfiles\<profile>\AppData\Local\Microsoft\Windows
      Patterns: UsrClass.dat, UsrClass.dat.*.
    - Copies files into:
      <OutputRoot>\<MachineName>-<yyyyMMdd>\registry\<source-relative-path>
    - If a file cannot be copied normally, the collector retries with a
      temporary shadow copy of the source volume.

  Live registry collection, only when -SourceRoot is not specified:
    - Uses reg.exe save to export:
      HKLM\SAM, HKLM\SECURITY, HKLM\SOFTWARE, HKLM\SYSTEM,
      HKLM\COMPONENTS, HKLM\DRIVERS.
    - Does not enumerate HKU user hives and does not export user registry data
      with reg.exe in live mode.
    - Copies live user profile registry files from C:\Users and
      C:\Windows\ServiceProfiles using the same file copy and shadow copy
      fallback logic as offline collection.
    - Saves successful hives into:
      <OutputRoot>\<MachineName>-<yyyyMMdd>\registry\Windows\System32\config
      using native hive filenames such as SYSTEM, SOFTWARE, SAM.
    - Failed reg.exe saves are recorded and any zero-byte destination files are
      removed. If reg.exe save fails for a machine hive, the collector retries
      by copying the matching file from %SystemRoot%\System32\config, then with
      a temporary shadow copy of the system volume.
    - Live user profile registry files are copied into:
      <OutputRoot>\<MachineName>-<yyyyMMdd>\registry\<source-relative-path>

  Index output:
    - collected_files.csv indexes copied/found registry files and live registry
      save attempts with source type, original path or registry path,
      destination path, timestamps, size, attributes, SHA256, collected status,
      collection method, and message.
"@
}

if ($Help) {
    Show-RegistryHelp
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
$RegistryOutputRoot = Join-Path $DestinationRoot "registry"
$OfflineRegistryOutputRoot = $RegistryOutputRoot
$LiveRegistryOutputRoot = Join-Path $RegistryOutputRoot "Windows\System32\config"
$FileCsvPath = Join-Path $DestinationRoot "collected_files.csv"
$CollectedFileRecords = @()
$LiveRegistryRecords = @()
$SeenFilePaths = @{}
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

function Export-RegistryFileCsv {
    if ($CollectedFileRecords.Count -gt 0) {
        $csvExistsWithData = (Test-Path -LiteralPath $FileCsvPath -PathType Leaf) -and ((Get-Item -LiteralPath $FileCsvPath).Length -gt 0)
        if ($csvExistsWithData) {
            $CollectedFileRecords | Select-Object $FileCsvColumns | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1 | Add-Content -Path $FileCsvPath -Encoding UTF8
        }
        else {
            $CollectedFileRecords | Select-Object $FileCsvColumns | Export-Csv -Path $FileCsvPath -NoTypeInformation -Encoding UTF8
        }
    }
}

function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $MachineName $Level registry: $Message"

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
    if (Test-Path -LiteralPath $RegistryOutputRoot -PathType Container) {
        Write-Log -Message "Cleanup requested. Removing existing Registry output folder: $RegistryOutputRoot"
        Remove-Item -LiteralPath $RegistryOutputRoot -Recurse -Force
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

function Add-RegistryFileRecord {
    param (
        [System.IO.FileInfo]$File,
        [string]$SourceType,
        [string]$DestinationPath,
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

    Export-RegistryFileCsv
}

function Get-RegistryFileSha256 {
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

function Copy-RegistryFile {
    param (
        [System.IO.FileInfo]$File,
        [string]$SourceType,
        [string]$DestinationRoot = $OfflineRegistryOutputRoot
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
    $destPath = Join-Path $DestinationRoot $relativePath
    $destParent = Split-Path -Path $destPath -Parent
    if (-not (Test-Path -LiteralPath $destParent -PathType Container)) {
        New-Item -ItemType Directory -Path $destParent -Force | Out-Null
    }

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
        $sha256 = Get-RegistryFileSha256 -Path $destPath -Description $destPath
    }

    Add-RegistryFileRecord -File $File -SourceType $SourceType -DestinationPath $destPath -Collected $collected -SHA256 $sha256 -CollectionMethod $collectionMethod -Message $message
}

function Copy-RegistryFilesFromPath {
    param (
        [string]$SourcePath,
        [string]$SourceType,
        [string[]]$Include,
        [string]$DestinationRoot = $OfflineRegistryOutputRoot,
        [switch]$Recurse
    )

    try {
        if (-not (Test-Path -LiteralPath $SourcePath -PathType Container -ErrorAction Stop)) {
            return
        }
    }
    catch {
        Write-Log -Level "WARN" -Message "Could not access registry file source folder ${SourcePath}: $_"
        return
    }

    Write-Log -Message "Collecting registry files from $SourcePath"
    Get-ChildItem -LiteralPath $SourcePath -File -Recurse:$Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $file = $_
        foreach ($pattern in $Include) {
            if ($file.Name -ilike $pattern) {
                Copy-RegistryFile -File $file -SourceType $SourceType -DestinationRoot $DestinationRoot
                break
            }
        }
    }
}

function Add-LiveRegistryRecord {
    param (
        [string]$RegistryPath,
        [string]$DestinationPath,
        [string]$Collected,
        [string]$SHA256 = "",
        [string]$Message = "",
        [string]$CollectionMethod = "reg.exe save"
    )

    $script:LiveRegistryRecords += [pscustomobject]@{
        "Registry Path"    = $RegistryPath
        "Destination Path" = $DestinationPath
        "SHA256"           = $SHA256
        "Collected"        = $Collected
        "Message"          = $Message
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
            Write-Log -Level "WARN" -Message "Could not read live registry hive metadata for ${DestinationPath}: $_"
        }
    }

    $script:CollectedFileRecords += [pscustomobject]@{
        "Source Type"        = "Live Registry Hive"
        "Full Original Path" = $RegistryPath
        "Destination Path"   = $DestinationPath
        "File Created"       = $fileCreated
        "File Modified"      = $fileModified
        "File Access"        = $fileAccess
        "Size"               = $size
        "Attributes"         = $attributes
        "SHA256"             = $SHA256
        "Collected"          = $Collected
        "Collection Method"  = $CollectionMethod
        "Message"            = $Message
    }

    Export-RegistryFileCsv
}

function Format-RegistryToolMessage {
    param ([string]$Message)

    return $Message -replace 'ERROR: The system was unable to find the specified registry key or value\.', 'WARNING: The system was unable to find the specified registry key or value.'
}

function Add-ProfilePath {
    param (
        [hashtable]$ProfilePaths,
        [string]$ProfilePath,
        [string]$SID = "Unknown"
    )

    if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
        return
    }

    $expandedPath = [Environment]::ExpandEnvironmentVariables($ProfilePath)
    try {
        $fullPath = [System.IO.Path]::GetFullPath($expandedPath).TrimEnd('\')
    }
    catch {
        Write-Log -Level "WARN" -Message "Could not normalize profile path ${ProfilePath}: $_"
        return
    }

    if (-not $ProfilePaths.ContainsKey($fullPath)) {
        $ProfilePaths[$fullPath] = [pscustomobject]@{
            Path = $fullPath
            SID  = $SID
        }
    }
    elseif (($ProfilePaths[$fullPath].SID -eq "Unknown") -and ($SID -ne "Unknown")) {
        $ProfilePaths[$fullPath].SID = $SID
    }
}

function Get-OfflineUserProfilePaths {
    $profilePaths = @{}

    foreach ($profileRoot in @((Join-Path $SourceRoot "Users"), (Join-Path $SourceRoot "Windows\ServiceProfiles"))) {
        try {
            if (Test-Path -LiteralPath $profileRoot -PathType Container -ErrorAction Stop) {
                Get-ChildItem -LiteralPath $profileRoot -Directory -Force -ErrorAction SilentlyContinue |
                    Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) } |
                    ForEach-Object {
                        Add-ProfilePath -ProfilePaths $profilePaths -ProfilePath $_.FullName -SID "N/A"
                    }
            }
        }
        catch {
            Write-Log -Level "WARN" -Message "Could not enumerate offline profile root ${profileRoot}: $_"
        }
    }

    return @($profilePaths.Values | Sort-Object Path)
}

function Get-LiveUserProfilePaths {
    $profilePaths = @{}
    $profileListPath = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"

    try {
        Get-ChildItem -Path $profileListPath -ErrorAction Stop | ForEach-Object {
            try {
                $profile = Get-ItemProperty -LiteralPath $_.PSPath -Name ProfileImagePath -ErrorAction Stop
                $sid = Split-Path -Path $_.Name -Leaf
                Add-ProfilePath -ProfilePaths $profilePaths -ProfilePath $profile.ProfileImagePath -SID $sid
            }
            catch {
                Write-Log -Level "WARN" -Message "Could not read ProfileImagePath from $($_.Name): $_"
            }
        }
    }
    catch {
        Write-Log -Level "WARN" -Message "Could not enumerate live ProfileList registry key: $_"
    }

    foreach ($profileRoot in @((Join-Path $SourceRoot "Users"), (Join-Path $SourceRoot "Windows\ServiceProfiles"))) {
        try {
            if (Test-Path -LiteralPath $profileRoot -PathType Container -ErrorAction Stop) {
                Get-ChildItem -LiteralPath $profileRoot -Directory -Force -ErrorAction SilentlyContinue |
                    Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) } |
                    ForEach-Object {
                        Add-ProfilePath -ProfilePaths $profilePaths -ProfilePath $_.FullName
                    }
            }
        }
        catch {
            Write-Log -Level "WARN" -Message "Could not enumerate live profile root ${profileRoot}: $_"
        }
    }

    return @($profilePaths.Values | Sort-Object Path)
}

function Write-IdentifiedProfileDebug {
    param (
        [string]$Mode,
        [object[]]$ProfileEntries
    )

    Write-Log -Level "DEBUG" -Message "$Mode user profiles identified: $($ProfileEntries.Count)"
    foreach ($profileEntry in $ProfileEntries) {
        Write-Log -Level "DEBUG" -Message "[$Mode] User Profile: $($profileEntry.Path) SID: $($profileEntry.SID)"
    }
}

function Copy-UserProfileRegistryFiles {
    param (
        [object[]]$ProfileEntries,
        [string]$Mode
    )

    Write-IdentifiedProfileDebug -Mode $Mode -ProfileEntries $ProfileEntries

    foreach ($profileEntry in $ProfileEntries) {
        $profilePath = $profileEntry.Path
        Copy-RegistryFilesFromPath -SourcePath $profilePath -SourceType "User Hive" -Include @("NTUSER.DAT", "NTUSER.DAT.*", "ntuser.ini")

        $usrClassPath = Join-Path $profilePath "AppData\Local\Microsoft\Windows"
        Copy-RegistryFilesFromPath -SourcePath $usrClassPath -SourceType "User Class Hive" -Include @("UsrClass.dat", "UsrClass.dat.*")
    }
}

function Save-LiveRegistryHive {
    param (
        [string]$RegistryPath,
        [string]$DestinationPath,
        [string]$SourceFilePath = ""
    )

    $destParent = Split-Path -Path $DestinationPath -Parent
    if (-not (Test-Path -LiteralPath $destParent -PathType Container)) {
        New-Item -ItemType Directory -Path $destParent -Force | Out-Null
    }

    try {
        $output = & reg.exe save $RegistryPath $DestinationPath /y 2>&1
        if ($LASTEXITCODE -eq 0) {
            $sha256 = ""
            try {
                $sha256 = (Get-FileHash -LiteralPath $DestinationPath -Algorithm SHA256 -ErrorAction Stop).Hash
            }
            catch {
                Write-Log -Level "WARN" -Message "Could not calculate SHA256 for live registry hive $DestinationPath`: $_"
            }

            Add-LiveRegistryRecord -RegistryPath $RegistryPath -DestinationPath $DestinationPath -Collected "Yes" -SHA256 $sha256 -Message ($output -join " ") -CollectionMethod "reg.exe save"
        }
        else {
            $message = Format-RegistryToolMessage -Message ($output -join " ")
            if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) {
                Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
            }

            if ((-not [string]::IsNullOrWhiteSpace($SourceFilePath)) -and (Test-Path -LiteralPath $SourceFilePath -PathType Leaf)) {
                Write-Log -Level "WARN" -Message "Could not save live registry hive ${RegistryPath} with reg.exe: $message"
                $fallbackResult = Copy-FileWithFallback -SourcePath $SourceFilePath -DestinationPath $DestinationPath
                if ($fallbackResult.Success) {
                    $sha256 = ""
                    try {
                        $sha256 = (Get-FileHash -LiteralPath $DestinationPath -Algorithm SHA256 -ErrorAction Stop).Hash
                    }
                    catch {
                        Write-Log -Level "WARN" -Message "Could not calculate SHA256 for live registry hive $DestinationPath`: $_"
                    }

                    Add-LiveRegistryRecord -RegistryPath $RegistryPath -DestinationPath $DestinationPath -Collected "Yes" -SHA256 $sha256 -Message "reg.exe save failed: $message Fallback method: $($fallbackResult.Method). $($fallbackResult.Message)" -CollectionMethod $fallbackResult.Method
                    return
                }

                $message = "$message Fallback copy failed: $($fallbackResult.Message)"
            }

            Write-Log -Level "WARN" -Message "Could not save live registry hive ${RegistryPath}: $message"
            Add-LiveRegistryRecord -RegistryPath $RegistryPath -DestinationPath $DestinationPath -Collected "No" -Message $message -CollectionMethod "reg.exe save"
        }
    }
    catch {
        if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) {
            Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
        }
        Write-Log -Level "WARN" -Message "Could not save live registry hive ${RegistryPath}: $_"
        Add-LiveRegistryRecord -RegistryPath $RegistryPath -DestinationPath $DestinationPath -Collected "No" -Message $_ -CollectionMethod "reg.exe save"
    }
}

function Export-RegistryCsv {
    Export-RegistryFileCsv
}

function Copy-OfflineRegistryFiles {
    if (-not $SourceRootSpecified) {
        Write-Log -Message "SourceRoot was not specified. Skipping offline registry hive file collection."
        return
    }

    $systemHivePatterns = @(
        "SAM", "SAM.*",
        "SECURITY", "SECURITY.*",
        "SOFTWARE", "SOFTWARE.*",
        "SYSTEM", "SYSTEM.*",
        "DEFAULT", "DEFAULT.*",
        "COMPONENTS", "COMPONENTS.*",
        "DRIVERS", "DRIVERS.*",
        "BCD", "BCD.*",
        "*.blf",
        "*.regtrans-ms"
    )

    $configPath = Join-Path $SourceRoot "Windows\System32\config"
    Copy-RegistryFilesFromPath -SourcePath $configPath -SourceType "System Hive" -Include $systemHivePatterns -Recurse

    $profileEntries = Get-OfflineUserProfilePaths
    Copy-UserProfileRegistryFiles -ProfileEntries $profileEntries -Mode "Offline"
}

function Save-LiveRegistryData {
    Write-Log -Message "Collecting live registry data"

    $hklmHives = @(
        @{ Path = "HKLM\SAM"; Name = "SAM"; Source = (Join-Path $env:SystemRoot "System32\config\SAM") },
        @{ Path = "HKLM\SECURITY"; Name = "SECURITY"; Source = (Join-Path $env:SystemRoot "System32\config\SECURITY") },
        @{ Path = "HKLM\SOFTWARE"; Name = "SOFTWARE"; Source = (Join-Path $env:SystemRoot "System32\config\SOFTWARE") },
        @{ Path = "HKLM\SYSTEM"; Name = "SYSTEM"; Source = (Join-Path $env:SystemRoot "System32\config\SYSTEM") },
        @{ Path = "HKLM\COMPONENTS"; Name = "COMPONENTS"; Source = (Join-Path $env:SystemRoot "System32\config\COMPONENTS") },
        @{ Path = "HKLM\DRIVERS"; Name = "DRIVERS"; Source = (Join-Path $env:SystemRoot "System32\config\DRIVERS") }
    )

    foreach ($hive in $hklmHives) {
        $destPath = Join-Path $LiveRegistryOutputRoot $hive.Name
        Save-LiveRegistryHive -RegistryPath $hive.Path -DestinationPath $destPath -SourceFilePath $hive.Source
    }

    $profileEntries = Get-LiveUserProfilePaths
    Copy-UserProfileRegistryFiles -ProfileEntries $profileEntries -Mode "Live"
}

if ($SourceRootSpecified) {
    Copy-OfflineRegistryFiles
    Write-Log -Message "SourceRoot was specified. Skipping live registry collection."
}
else {
    Save-LiveRegistryData
}
Export-RegistryCsv

Write-Log -Message "Collection completed! Registry data is stored in: $RegistryOutputRoot"
Write-Log -Message "Registry files collected/found: $(($CollectedFileRecords | Where-Object { $_.Collected -eq "Yes" }).Count)/$($CollectedFileRecords.Count)"
if (-not $SourceRootSpecified) {
    Write-Log -Message "Live registry hives collected/attempted: $(($LiveRegistryRecords | Where-Object { $_.Collected -eq "Yes" }).Count)/$($LiveRegistryRecords.Count)"
}

$hasRegistryData = ($CollectedFileRecords | Where-Object { $_.Collected -eq "Yes" }).Count -gt 0
if ((-not $hasRegistryData) -and (Test-Path -LiteralPath $RegistryOutputRoot -PathType Container)) {
    Remove-Item -LiteralPath $RegistryOutputRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log -Message "No registry data collected. Removed empty registry folder: $RegistryOutputRoot"
}
