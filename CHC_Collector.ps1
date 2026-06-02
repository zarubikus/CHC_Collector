# -------------------------------
# Master Script Runner
# -------------------------------
# Executes all PowerShell scripts in a subfolder in order by filename
# -------------------------------

<#
.SYNOPSIS
    Runs all CHC collector scripts and packages the collected output.

.DESCRIPTION
    CHC_Collector.ps1 is the master runner for the CHC collection framework.
    It executes every PowerShell collector in the collectors folder in sorted
    filename order, passes shared runtime options to collectors, writes a shared
    master log, and creates a final ZIP archive by default.

    Administrator privileges are required by default. Use -NoAdminRequired only
    when intentionally testing or collecting artifacts that do not require
    elevation. By default the master removes the existing target master log and
    target ZIP archive before collection, passes -Cleanup to collectors, archives
    output\<MachineName>-<yyyyMMdd> plus the master log into
    output\<MachineName>-<yyyyMMdd>.zip, and deletes the uncompressed dated
    output folder only after archive creation succeeds.

.PARAMETER MachineName
    Overrides the machine name used by the master log and output naming. This
    value is passed to collectors only when explicitly specified.

.PARAMETER SourceRoot
    Offline filesystem source root, such as C: or D:\MountedImage. This value
    is passed to collectors only when explicitly specified.

.PARAMETER OutputRoot
    Root folder for collection output. Defaults to the output folder under the
    master script directory. This value is passed to collectors only when
    explicitly specified.

.PARAMETER Artifacts
    Comma-separated collector artifact names to execute, such as
    "anydesk, registry". Names match collector filenames after the numeric
    prefix, so "registry" matches 10_registry.ps1 and "anydesk" matches
    21_anydesk.ps1. If omitted, all collectors are executed. If "all" is
    specified, all collectors are executed. If "runtime" or "winget" is
    explicitly listed, that live collector is executed with -Force.

.PARAMETER Log
    Shared master log path. If omitted, the default is
    output\<MachineName>-<yyyyMMdd>_master.log. The resolved log path is always
    passed to collectors.

.PARAMETER ShowLog
    Displays master and collector log records on screen while also writing them
    to the shared log file.

.PARAMETER NoCleanup
    Prevents the master from deleting the existing target master log and target
    ZIP archive at startup. Also prevents the master from passing -Cleanup to
    collectors.

.PARAMETER NoArchive
    Disables final ZIP archive creation and prevents deletion of the
    uncompressed output\<MachineName>-<yyyyMMdd> folder.

.PARAMETER NoAdminRequired
    Allows the master to run without Administrator privileges. Without this
    option, the master exits before executing collectors if it is not elevated.

.PARAMETER Help
    Displays master help and executes each sub collector with -Help. This path
    exits before admin checks, cleanup, collection, logging, or archiving.

.EXAMPLE
    .\CHC_Collector.ps1

    Runs all collectors as Administrator, writes output under .\output, creates
    .\output\<MachineName>-<yyyyMMdd>.zip, and keeps the master log.

.EXAMPLE
    .\CHC_Collector.ps1 -MachineName HOST01 -SourceRoot D:\MountedImage -OutputRoot E:\Collections -ShowLog

    Runs collectors against an offline source root, uses HOST01 for output
    naming, writes output under E:\Collections, and mirrors log records to the
    console.

.EXAMPLE
    .\CHC_Collector.ps1 -NoAdminRequired -NoArchive -NoCleanup

    Runs without requiring elevation, preserves existing logs/ZIPs, does not
    pass -Cleanup to collectors, and leaves the uncompressed output folder.

.NOTES
    CHC Collector master script. Designed for local Windows artifact collection
    using built-in PowerShell and Windows utilities.
#>

param (
    [string]$MachineName = $env:COMPUTERNAME,
    [string]$SourceRoot = "C:",
    [string]$OutputRoot = (Join-Path $PSScriptRoot "output"),
    [string[]]$Artifacts,
    [string]$Log,
    [switch]$ShowLog,
    [switch]$NoCleanup,
    [switch]$NoArchive,
    [switch]$NoAdminRequired,
    [switch]$Help
)

$MasterBoundParameters = @{} + $PSBoundParameters

# ===== CONFIGURATION =====
$ScriptsFolder = Join-Path $PSScriptRoot "collectors"  # Folder containing your collector scripts
$DateString = Get-Date -Format "yyyyMMdd"
$MachineNameSafe = ($MachineName -replace '[^a-zA-Z0-9\-]', '_')
$CollectionOutputRoot = Join-Path $OutputRoot "$MachineNameSafe-$DateString"
$ArchivePath = Join-Path $OutputRoot "$MachineNameSafe-$DateString.zip"
$ArchiveHashPath = [System.IO.Path]::ChangeExtension($ArchivePath, "SHA256")

function Show-MasterHelp {
    Write-Host @"
CHC_Collector.ps1

Description:
  Master runner for CHC collector scripts. Executes all *.ps1 files in the
  collectors folder in filename order, passes shared arguments to collectors,
  writes a master log, and archives the collection output by default.

Arguments:
  -MachineName <string>
      Override the machine name used by the master log and passed to collectors
      only when this argument is specified.

  -SourceRoot <string>
      Source filesystem root for offline collection. Passed to collectors only
      when this argument is specified.

  -OutputRoot <string>
      Output directory root. Default: <script folder>\output. Passed to
      collectors only when this argument is specified.

  -Artifacts <string>
      Comma-separated collector artifact names to execute. Example:
      -Artifacts "anydesk, registry". If omitted, all collectors are executed.
      If "all" is specified, all collectors are executed. If "runtime" is
      explicitly listed, runtime is executed with -Force. If "winget" is
      explicitly listed, winget is executed with -Force.

  -Log <string>
      Master/shared log path. Default:
      <script folder>\output\<MachineName>-<yyyyMMdd>_master.log.
      The resolved log path is always passed to collectors.

  -ShowLog
      Display master and collector log records on screen while also writing
      them to the shared log.

  -NoCleanup
      Do not delete the existing master log or target zip at startup, and do
      not pass -Cleanup to collectors.

  -NoArchive
      Do not create output\<MachineName>-<yyyyMMdd>.zip and do not delete the
      output\<MachineName>-<yyyyMMdd> folder after collection.

  -NoAdminRequired
      Allow execution without Administrator privileges. By default, the master
      exits before running collectors when Administrator privileges are absent.

  -Help
      Display this help and execute each sub collector with -Help.

Default workflow:
  1. Require Administrator privileges unless -NoAdminRequired is used.
  2. Delete the target master log and zip unless -NoCleanup is used.
  3. Execute selected collectors in sorted filename order.
  4. Pass -Cleanup to collectors unless -NoCleanup is used.
  5. Always pass the resolved -Log path to collectors.
  6. Archive output\<MachineName>-<yyyyMMdd> plus the master log into
     output\<MachineName>-<yyyyMMdd>.zip unless -NoArchive is used.
  7. Delete output\<MachineName>-<yyyyMMdd> only after successful archive
     creation. The master log remains in place.
"@
}

function Get-ArtifactNameFromScript {
    param ([string]$ScriptName)

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($ScriptName)
    return ($baseName -replace '^\d+[_-]?', '').ToLowerInvariant()
}

function Get-RequestedArtifactNames {
    if (-not $MasterBoundParameters.ContainsKey("Artifacts") -or $null -eq $Artifacts -or $Artifacts.Count -eq 0) {
        return @()
    }

    $rawArtifactValues = @($Artifacts | ForEach-Object { [string]$_ })
    return @($rawArtifactValues -split "," |
        ForEach-Object { $_.Trim().ToLowerInvariant() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Write-ArtifactSelectionWarning {
    param ([string]$Message)

    if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Level "WARNING" -Message $Message
    }
    else {
        Write-Host "WARNING: $Message"
    }
}

function Select-CollectorScripts {
    param ([object[]]$Scripts)

    $requestedArtifacts = @(Get-RequestedArtifactNames)
    if ($requestedArtifacts.Count -eq 0) {
        return @($Scripts)
    }

    if ($requestedArtifacts -contains "all") {
        return @($Scripts)
    }

    $availableArtifacts = @{}
    foreach ($script in $Scripts) {
        $artifactName = Get-ArtifactNameFromScript -ScriptName $script.Name
        $availableArtifacts[$artifactName] = $script
    }

    $selectedScripts = @()
    foreach ($artifactName in $requestedArtifacts) {
        if ($availableArtifacts.ContainsKey($artifactName)) {
            $selectedScripts += $availableArtifacts[$artifactName]
        }
        else {
            Write-ArtifactSelectionWarning -Message "Requested artifact '$artifactName' does not match any collector script."
        }
    }

    return @($selectedScripts | Sort-Object Name -Unique)
}

if ($Help) {
    Show-MasterHelp

    if (Test-Path -LiteralPath $ScriptsFolder -PathType Container) {
        $helpScriptFiles = Select-CollectorScripts -Scripts (Get-ChildItem -LiteralPath $ScriptsFolder -Filter "*.ps1" | Sort-Object Name)
        foreach ($script in $helpScriptFiles) {
            Write-Host ""
            Write-Host "===== $($script.Name) ====="
            & $script.FullName -Help
        }
    }
    else {
        Write-Host ""
        Write-Host "Collectors folder not found: $ScriptsFolder"
    }

    exit 0
}

if (-not $MasterBoundParameters.ContainsKey("Log")) {
    $Log = Join-Path (Join-Path $PSScriptRoot "output") "$MachineNameSafe-$DateString`_master.log"
}

if ((-not $NoCleanup) -and (Test-Path -LiteralPath $Log -PathType Leaf)) {
    Remove-Item -LiteralPath $Log -Force
}

if ((-not $NoCleanup) -and (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
    Remove-Item -LiteralPath $ArchivePath -Force
}

if ((-not $NoCleanup) -and (Test-Path -LiteralPath $ArchiveHashPath -PathType Leaf)) {
    Remove-Item -LiteralPath $ArchiveHashPath -Force
}

function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $MachineName $Level master: $Message"

    $logParent = Split-Path -Path $Log -Parent
    if ($logParent -and (-not (Test-Path -LiteralPath $logParent -PathType Container))) {
        New-Item -ItemType Directory -Path $logParent -Force | Out-Null
    }

    Add-Content -Path $Log -Value $logMessage -Encoding UTF8

    if ($ShowLog) {
        Write-Host $logMessage
    }
}

function Write-RequiredAdminWarning {
    $adminWarning = "WARNING: CHC COLLECTOR MUST BE RUN AS ADMINISTRATOR. EXITING WITHOUT EXECUTING COLLECTORS."
    Write-Log -Level "WARNING" -Message $adminWarning

    if (-not $ShowLog) {
        Write-Host $adminWarning
    }
}

function Get-CollectorParameters {
    param ([string]$ScriptPath)

    $collectorParams = @{}

    if ($MasterBoundParameters.ContainsKey("MachineName")) {
        $collectorParams["MachineName"] = $MachineName
    }

    if ($MasterBoundParameters.ContainsKey("OutputRoot")) {
        $collectorParams["OutputRoot"] = $OutputRoot
    }

    if ($MasterBoundParameters.ContainsKey("SourceRoot")) {
        $collectorParams["SourceRoot"] = $SourceRoot
    }

    $collectorParams["Log"] = $Log

    if ($ShowLog) {
        $collectorParams["ShowLog"] = [switch]::Present
    }

    if (-not $NoCleanup) {
        $collectorParams["Cleanup"] = [switch]::Present
    }

    $requestedArtifacts = @(Get-RequestedArtifactNames)
    $artifactName = Get-ArtifactNameFromScript -ScriptName ([System.IO.Path]::GetFileName($ScriptPath))
    if ((($requestedArtifacts -contains "runtime") -and ($artifactName -eq "runtime")) -or
        (($requestedArtifacts -contains "winget") -and ($artifactName -eq "winget"))) {
        $collectorParams["Force"] = [switch]::Present
    }

    return $collectorParams
}

function Format-CollectorCommand {
    param (
        [string]$ScriptPath,
        [hashtable]$Parameters
    )

    $parameterText = @()
    foreach ($key in ($Parameters.Keys | Sort-Object)) {
        $parameterValue = $Parameters[$key]
        if ($parameterValue -is [System.Management.Automation.SwitchParameter]) {
            if ($parameterValue.IsPresent) {
                $parameterText += "-$key"
            }
            continue
        }

        $value = [string]$parameterValue
        $escapedValue = $value -replace "'", "''"
        $parameterText += "-$key '$escapedValue'"
    }

    if ($parameterText.Count -eq 0) {
        return "& '$ScriptPath'"
    }

    return "& '$ScriptPath' $($parameterText -join ' ')"
}

function Compress-CollectionOutput {
    if (-not (Test-Path -LiteralPath $CollectionOutputRoot -PathType Container)) {
        Write-Log -Level "WARNING" -Message "Collection output folder not found. Skipping archive: $CollectionOutputRoot"
        return
    }

    $archiveParent = Split-Path -Path $ArchivePath -Parent
    if ($archiveParent -and (-not (Test-Path -LiteralPath $archiveParent -PathType Container))) {
        New-Item -ItemType Directory -Path $archiveParent -Force | Out-Null
    }

    $archiveItems = @($CollectionOutputRoot)
    if (Test-Path -LiteralPath $Log -PathType Leaf) {
        $archiveItems += $Log
    }
    else {
        Write-Log -Level "WARNING" -Message "Master log file not found. Archive will not include it: $Log"
    }

    try {
        Write-Log -Message "Creating archive: $ArchivePath"
        Compress-Archive -LiteralPath $archiveItems -DestinationPath $ArchivePath -Force -ErrorAction Stop
        Write-Log -Message "Archive created successfully: $ArchivePath"

        $archiveHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256 -ErrorAction Stop).Hash
        $hashFileContent = "$archiveHash *$([System.IO.Path]::GetFileName($ArchivePath))"
        Set-Content -Path $ArchiveHashPath -Value $hashFileContent -Encoding ASCII
        Write-Log -Message "Archive SHA256: $archiveHash"
        Write-Log -Message "Archive SHA256 file created: $ArchiveHashPath"

        Remove-Item -LiteralPath $CollectionOutputRoot -Recurse -Force -ErrorAction Stop
        Write-Log -Message "Removed collection output folder after successful archive: $CollectionOutputRoot"
    }
    catch {
        Write-Log -Level "WARNING" -Message "Could not create archive or cleanup collection output folder: $_"
    }
}

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
$isAdministrator = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($isAdministrator) {
    Write-Log -Level "DEBUG" -Message "CHC Collector is running as Administrator."
}
elseif ($NoAdminRequired) {
    Write-Log -Level "WARNING" -Message "CHC Collector is not running as Administrator. Some artifacts may not be accessible."
}
else {
    Write-RequiredAdminWarning
    exit 1
}

# Check if folder exists
if (-not (Test-Path -LiteralPath $ScriptsFolder -PathType Container)) {
    Write-Log -Level "ERROR" -Message "Scripts folder not found: $ScriptsFolder"
    exit
}

# ===== GET SCRIPTS =====
$scriptFiles = Select-CollectorScripts -Scripts (Get-ChildItem -LiteralPath $ScriptsFolder -Filter "*.ps1" | Sort-Object Name)

if ($scriptFiles.Count -eq 0) {
    Write-Log -Level "WARNING" -Message "No collector scripts selected. Exiting without executing collectors."
    exit 0
}

if ((Get-RequestedArtifactNames).Count -gt 0) {
    Write-Log -Message "Selected artifacts: $($scriptFiles.Name -join ', ')"
}

# ===== EXECUTE SCRIPTS =====
foreach ($script in $scriptFiles) {
    Write-Log -Message "Executing $($script.Name) ..."
    try {
        # Use the & call operator to execute the script
        $collectorParams = Get-CollectorParameters -ScriptPath $script.FullName
        Write-Log -Level "DEBUG" -Message "Executing command: $(Format-CollectorCommand -ScriptPath $script.FullName -Parameters $collectorParams)"
        & $script.FullName @collectorParams
        Write-Log -Message "$($script.Name) completed successfully."
    }
    catch {
        Write-Log -Level "WARNING" -Message "Error executing $($script.Name): $_"
    }
}

Write-Log -Message "All scripts executed."

if ($NoArchive) {
    Write-Log -Message "NoArchive requested. Skipping archive creation and collection output cleanup."
}
else {
    Compress-CollectionOutput
}
