$ErrorActionPreference = 'Stop'

$RepoOwner = 'zarubikus'
$RepoName = 'CHC_Collector'
$Branch = 'main'

$CurrentDir = (Get-Location).Path
$ZipUrl = "https://github.com/$RepoOwner/$RepoName/archive/refs/heads/$Branch.zip"
$ZipPath = Join-Path $CurrentDir "$RepoName.zip"
$TempExtractPath = Join-Path $CurrentDir "_${RepoName}_tmp"
$TargetRoot = Join-Path $CurrentDir 'CHC_Collector'

Write-Host "[*] Downloading $ZipUrl"
Invoke-WebRequest -Uri $ZipUrl -OutFile $ZipPath

if (Test-Path -LiteralPath $TempExtractPath) {
    Remove-Item -LiteralPath $TempExtractPath -Recurse -Force
}

Write-Host "[*] Extracting archive"
Expand-Archive -Path $ZipPath -DestinationPath $TempExtractPath -Force

$ExpandedRoot = Get-ChildItem -LiteralPath $TempExtractPath -Directory | Select-Object -First 1
if (-not $ExpandedRoot) {
    throw "Could not find extracted repository root in $TempExtractPath"
}

if (-not (Test-Path -LiteralPath $TargetRoot)) {
    New-Item -Path $TargetRoot -ItemType Directory | Out-Null
}

Write-Host "[*] Copying files to $TargetRoot"
Copy-Item -Path (Join-Path $ExpandedRoot.FullName 'CHC_Collector\*') -Destination $TargetRoot -Recurse -Force

Remove-Item -LiteralPath $ZipPath -Force
Remove-Item -LiteralPath $TempExtractPath -Recurse -Force

$MasterScript = Join-Path $TargetRoot 'CHC_Collector.ps1'
if (-not (Test-Path -LiteralPath $MasterScript)) {
    throw "Master script not found: $MasterScript"
}

Write-Host "[*] Running $MasterScript"
& $MasterScript
