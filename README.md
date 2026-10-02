# CHC Collector

CHC Collector is a PowerShell-based artifact collection framework for Windows.
It runs modular sub-collectors, writes normalized file indexes, and optionally
archives results into a ZIP package with SHA256 integrity metadata.

## Purpose

CHC Collector collects evidence files offline for automated digital forensics and
incident response (DFIR) processing. Its purpose is to prepare evidence for
cyber investigations, incident analysis, compliance checks, and security audits.
Collected files, normalized indexes, and SHA256 integrity metadata provide inputs
for downstream automated analysis workflows.

Collection can run without network access using a local copy or the bundled EXE.
Collectors that support offline sources can also collect from a mounted Windows
image through `-SourceRoot`. Live collectors capture additional system state
when run on a Windows host; optional online checks require network access.

## Highlights

- Modular collector architecture (`collectors/*.ps1`)
- Master runner with collector selection (`-Artifacts`)
- Shared logging and optional console mirroring (`-ShowLog`)
- Normalized file index format across collectors (`collected_files.csv`)
- SHA256 hashing for collected artifacts
- Optional archive packaging and archive SHA256 output
- Single offline EXE with PowerShell and BAT build launchers

## Repository Structure

- `CHC_Collector.ps1`: Master script
- `support/Build-CollectorExe.ps1`: Builds the offline EXE and its checksum
- `support/Build-CollectorExe.bat`: Double-click launcher for the EXE build
- `dist/CHC_Collector.exe`: Offline collector with all scripts bundled
- `dist/CHC_Collector.SHA256`: Checksum for the EXE
- `collectors/05_runtime.ps1`: Live runtime state (connections/processes JSON)
- `collectors/06_winget.ps1`: Live installed software and available updates
- `collectors/07_license.ps1`: Live Windows license and embedded OEM key state
- `collectors/08_hardware.ps1`: Live hardware inventory and serial numbers
- `collectors/10_registry.ps1`: Registry collection (offline or live)
- `collectors/12_evtx.ps1`: Event log collection (offline or live)
- `collectors/13_prefetch.ps1`: Prefetch artifact collection
- `collectors/21_anydesk.ps1`: AnyDesk artifact collection

## Requirements

- Windows PowerShell 5.1+ (or PowerShell with Windows networking/registry cmdlets)
- Windows host access to required sources
- Administrator rights recommended (required by default in master script)

## Offline EXE

Build a single EXE containing the master script and all current collector scripts:

```powershell
.\support\Build-CollectorExe.ps1
```

Or double-click `support\Build-CollectorExe.bat` to run the same build and keep the result window open. Building does not require Administrator access.

To choose a build output folder, use either launcher from the repository folder:

```powershell
.\support\Build-CollectorExe.ps1 -Destination 'E:\Build Output'
```

```cmd
support\Build-CollectorExe.bat -Destination "E:\Build Output"
```

The build creates `dist\CHC_Collector.exe` and `dist\CHC_Collector.SHA256`. It uses the installed x64 .NET Framework C# compiler; no package downloads are needed. Rebuild after changing collector scripts. Build files remain under `build/`, which is ignored by Git.

Copy the EXE to the collection machine and run it. It requests Administrator access, displays progress, and reports the ZIP and SHA256 file paths. The EXE requires 64-bit Windows, .NET Framework 4.8 or later, and Windows PowerShell 5.1. Scripts are bundled; Windows utilities and optional tools such as WinGet must already be installed. Optional online checks still require network access.

```powershell
.\dist\CHC_Collector.exe
.\dist\CHC_Collector.exe -Artifacts registry -SourceRoot 'D:\Mounted Image' -OutputRoot 'E:\Collections'
.\dist\CHC_Collector.exe -Help
```

Existing master parameters are accepted, including comma-separated or multiple `-Artifacts` values and switches such as `-NoArchive`. Relative paths are resolved against the working folder. Default results and master logs go under `<working folder>\output`; if elevation starts in System32 or SysWOW64, the EXE's folder is used instead. Scripts are extracted to a unique temporary folder and removed when the collector exits; results remain outside that folder. An unwritable output or log folder stops the launch with a visible error.

A double-click launch waits for a key before closing; terminal launches return normally. `-ShowLog` is enabled by default, and the EXE returns the collector process exit code. The initial build is unsigned.

To verify a build with synthetic offline evidence, run `tests\exe.Tests.ps1`. It checks the embedded scripts, archive contents, hashes, output paths, failures, and temporary-folder cleanup. In a non-elevated session it uses a temporary test EXE with the same code and payload; the production EXE retains its Administrator manifest. Check the Administrator prompt and double-click console behavior manually on the target machine.

## Quick Start - Bootstrap script

You can download and execute the toolkit in one command line using Powershell (as Administator):

```powershell
Set-ExecutionPolicy Unrestricted -Scope LocalMachine
Set-Location C:\DFIR
iwr -UseBasicParsing https://raw.githubusercontent.com/zarubikus/CHC_Collector/refs/heads/main/support/CHC_Bootstrap.ps1 | iex
```

`CHC_Bootstrap.ps1` is a bootstrap script that downloads the toolkit and runs it.
It downloads and extracts into the current working folder, then runs the copy under `<working folder>\CHC_Collector`. Choose an existing working folder before executing the command.
The bootstrap runs the collector with `-ShowLog`, so the console displays the full ZIP archive path and SHA256 file path when created, as well as collection or archive failure warnings.

`support\CHC_Bootstrap.bat` preserves the caller's working folder. If elevation starts it in `%SystemRoot%\System32` or `%SystemRoot%\SysWOW64`, it uses the batch file's folder instead. For example, launching `C:\DFIR\CHC_Collector\support\CHC_Bootstrap.bat` this way places the downloaded copy in `C:\DFIR\CHC_Collector\support\CHC_Collector`. To download into `C:\DFIR\CHC_Collector`, first open an elevated terminal, change its working folder to `C:\DFIR`, and launch the batch file from there.


The same command but executed from cmd.exe:

```cmd.exe
cd /d C:\DFIR
powershell -NoProfile -ExecutionPolicy Bypass -Command "iwr -UseBasicParsing https://raw.githubusercontent.com/zarubikus/CHC_Collector/refs/heads/main/support/CHC_Bootstrap.ps1 | iex"
```

## Quick Start - Local Copy

Run all collectors with defaults:

```powershell
.\CHC_Collector.ps1
```

Run selected collectors with log output to console:

```powershell
.\CHC_Collector.ps1 -Artifacts registry,evtx -ShowLog
```

Run all and force runtime collector even if `-SourceRoot` is present:

```powershell
.\CHC_Collector.ps1 -SourceRoot D:\MountedImage
```

Show help for master and selected collectors:

```powershell
.\CHC_Collector.ps1 -Help -Artifacts runtime
```

## Master Script Options

- `-MachineName <string>`: Override machine name used in output naming
- `-SourceRoot <string>`: Offline source root for collectors that support offline mode
- `-OutputRoot <string>`: Output root directory (default: `<repo>\output`)
- `-Artifacts <list>`: Collector names (`all`, `runtime`, `winget`, `license`, `hardware`, `registry`, `evtx`, `anydesk`)
- `-Log <path>`: Shared log file path
- `-ShowLog`: Print log lines to console
- `-NoCleanup`: Preserve existing master ZIP/log and do not pass `-Cleanup` to collectors
- `-NoArchive`: Skip ZIP packaging
- `-NoAdminRequired`: Allow master execution without elevation
- `-Help`: Show help and run sub-collector help

## Collector Behavior

### Runtime (`05_runtime.ps1`)

- Produces:
  - `runtime/connections.json`
  - `runtime/processes.json`
  - `collected_files.csv` entries for generated JSON artifacts
- `-SourceRoot` handling:
  - Skips by default when explicitly provided
  - Supports `-Force` to run live anyway

### Winget (`06_winget.ps1`)

- Live-only collector for installed software and available updates
- Produces:
  - `winget/installed_software.json`
  - `winget/available_updates.json`
  - `winget/winget_environment.json`
  - raw `winget.exe` output files when WinGet is available
  - `collected_files.csv` entries for generated artifacts
- Collection sources:
  - Registry uninstall keys
  - AppX packages when accessible
  - `Get-Package` when available
  - `Microsoft.WinGet.Client` if already installed
  - `winget.exe list`, `winget.exe upgrade`, and `winget.exe source list`
- `-SourceRoot` handling:
  - Skips by default when explicitly provided
  - Supports `-Force` to run live anyway
- The collector does not install modules, install software, or run upgrades

### License (`07_license.ps1`)

- Live-only collector for Windows licensing state
- Produces:
  - `license/license_status.json`
  - `collected_files.csv` entry for the generated JSON artifact
- Collection sources:
  - `Win32_OperatingSystem`
  - `SoftwareLicensingService`
  - `SoftwareLicensingProduct`
  - `OA3xOriginalProductKey` for embedded BIOS/UEFI OEM key when available
- `-SourceRoot` handling:
  - Skips by default when explicitly provided
  - Supports `-Force` to run live anyway
- The collector does not run activation commands or modify license state

### Hardware (`08_hardware.ps1`)

- Live-only collector for hardware inventory and serial numbers
- Produces:
  - `hardware/hardware_info.json`
  - `collected_files.csv` entry for the generated JSON artifact
- Collection sources:
  - `Win32_ComputerSystem`
  - `Win32_OperatingSystem`
  - `Win32_BIOS`
  - `Win32_BaseBoard`
  - `Win32_SystemEnclosure`
  - `Win32_Processor`
  - `Win32_PhysicalMemory`
  - `Win32_DiskDrive`
  - `Win32_LogicalDisk`
  - `Win32_VideoController`
  - `Win32_NetworkAdapter`
  - `Win32_NetworkAdapterConfiguration`
  - `Win32_PnPEntity`
  - `Win32_Tpm` when available
- `-SourceRoot` handling:
  - Skips by default when explicitly provided
  - Supports `-Force` to run live anyway
- The collector does not modify hardware, firmware, or OS state

### Registry (`10_registry.ps1`)

- Offline mode: when `-SourceRoot` is explicitly provided
- Live mode: when `-SourceRoot` is not provided
- Writes artifacts under `registry/...`
- Appends collected file metadata to shared `collected_files.csv`
- Collects `NTUSER.DAT`, `UsrClass.dat`, their sidecar files, and `ntuser.ini` from user and service profiles. Live profiles use a temporary link to a shadow copy, with normal file collection as a fallback.
- Collects `Amcache.hve` and `Amcache.hve.*` (including transaction logs) from `Windows\AppCompat\Programs` in both modes, preserving that path under `registry/`. Live collection first uses one shadow copy for the hive and logs, then falls back for unsuccessful files. SHA256 hashes and collection results are included in `collected_files.csv`; absent files and access failures are logged separately.
- Failed registry file copies and `reg.exe save` exports wait 30 seconds before each of up to three retries (four attempts total). Failed exports then try copying the source hive.
- The main runner also retries collectors that report unsuccessful execution or throw an error, with the same delay and limit.

### EVTX (`12_evtx.ps1`)

- Offline mode: when `-SourceRoot` is explicitly provided
- Live mode: when `-SourceRoot` is not provided
- Live export path mirrors `evtx/Windows/System32/winevt/Logs/...`
- Appends collected file metadata to shared `collected_files.csv`

### AnyDesk (`21_anydesk.ps1`)

- Collects from known AnyDesk locations (ProgramData, user profile paths, system profile, temp)
- Appends discovered/collected file metadata to shared `collected_files.csv`

## Output Layout

Default output folder:

`<repo>\output\<MachineName>-<yyyyMMdd>\`

Typical contents:

- Collector subfolders (`runtime`, `winget`, `license`, `hardware`, `registry`, `evtx`, `anydesk`) when data exists
- `collected_files.csv` (shared normalized file index)
- `<MachineName>-<yyyyMMdd>_master.log` (default log path unless overridden)

If archiving is enabled (default):

- `<MachineName>-<yyyyMMdd>.zip`
- `<MachineName>-<yyyyMMdd>.SHA256`

## File Index Format

Collectors use a common schema for `collected_files.csv`:

- `Source Type`
- `Full Original Path`
- `Destination Path`
- `File Created`
- `File Modified`
- `File Access`
- `Size`
- `Attributes`
- `SHA256`
- `Collected`
- `Collection Method`
- `Message`

## Notes

- Collectors are designed to avoid creating empty output subfolders when no data is collected.
- Runtime/state collection can include privileged metadata (process owner/path/SID) depending on rights.
- Winget/update collection depends on installed WinGet components and source availability.
- Some system-protected sources may require Administrator access.
