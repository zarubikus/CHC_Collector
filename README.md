# CHC Collector

Collect Windows evidence for investigations and security audits. CHC Collector
saves the files, records their details in a CSV index, and creates a ZIP with a
SHA256 checksum.

## Start here

**Use the EXE for the easiest setup.** It contains the collector scripts and can
run without downloading anything. WinGet update checks may need internet access.

You need a Windows PC and Administrator access. The EXE requires 64-bit Windows,
.NET Framework 4.8 or later, and Windows PowerShell 5.1.

### Collect from the current PC

1. Create a folder named `C:\DFIR`.
2. Copy `dist\CHC_Collector.exe` into it.
3. Open **Windows PowerShell** using **Run as administrator**.
4. Paste these commands:

```powershell
Set-Location 'C:\DFIR'
.\CHC_Collector.exe -OutputRoot 'C:\DFIR\Collections\Run01'
```

Wait for collection to finish. The console shows the full paths of the ZIP and
checksum files. Some unavailable or protected sources may be skipped; check the
collection log for details.

For another collection, change `Run01` to a new folder name such as `Run02`.
This keeps earlier results separate and avoids mixing old and new index formats.

You can also double-click the EXE and approve the Administrator prompt. It shows
progress and waits for a key before closing. Use the commands above when you want
to choose exactly where results are saved.

## Common commands

Run these from `C:\DFIR`, with `CHC_Collector.exe` in that folder. Replace example
paths with your own. Use a different output folder for each collection.

### Collect only selected evidence

Registry and Windows event logs:

```powershell
.\CHC_Collector.exe -Artifacts 'registry,evtx' -OutputRoot 'C:\DFIR\Collections\Run02'
```

Running processes and network connections:

```powershell
.\CHC_Collector.exe -Artifacts runtime -OutputRoot 'C:\DFIR\Collections\Run03'
```

Available names: `runtime`, `winget`, `license`, `hardware`, `registry`, `evtx`,
`prefetch`, and `anydesk`. Omit `-Artifacts` to run all collectors.

### Collect from a mounted Windows image

`-SourceRoot` must point to the image's Windows drive root: the folder containing
`Windows` and `Users`. For example, use `D:\MountedImage`, not
`D:\MountedImage\Windows`.

```powershell
.\CHC_Collector.exe -SourceRoot 'D:\MountedImage' -MachineName 'OFFLINE-PC' -OutputRoot 'C:\DFIR\Collections\Run04'
```

Registry, event logs, Prefetch, and AnyDesk files are collected from that image.
The live-only collectors (`runtime`, `winget`, `license`, and `hardware`) are
skipped when `-SourceRoot` is supplied.

Explicitly naming a live-only collector in `-Artifacts` forces it to run on the
**current PC**, even with `-SourceRoot`. Its live inventory does not describe the
mounted image. Avoid selecting those names for an image-only collection.

### Keep results in a folder instead of a ZIP

```powershell
.\CHC_Collector.exe -NoArchive -OutputRoot 'C:\DFIR\Collections\Run05'
```

### See all options

```powershell
.\CHC_Collector.exe -Help
```

## Find your results

With `-OutputRoot 'C:\DFIR\Collections\Run01'`, a completed collection normally creates:

```text
C:\DFIR\Collections\Run01\
  PCNAME-20261016.zip
  PCNAME-20261016.SHA256
  PCNAME-20261016_master.log
```

The name uses the machine name and collection date. The ZIP contains:

- Evidence folders such as `runtime`, `registry`, `evtx`, and `prefetch`.
- `collected_files.csv`: file paths, timestamps, hashes, and collection results.
- The master log.

After a successful archive, the uncompressed collection folder is removed.
Use `-NoArchive` to keep that folder. The master log remains outside the ZIP too.

When `-OutputRoot` is omitted, the EXE uses `output` under the working folder.
If elevation starts it in System32 or SysWOW64, it uses the EXE's folder instead.
The PowerShell script defaults to `output` under its own folder.

## What each collector collects

| Name | Evidence | Where it works | Output folder |
| --- | --- | --- | --- |
| `runtime` | Running processes and TCP/UDP connections | Current PC | `runtime` |
| `winget` | Installed software, available updates, and raw WinGet output when available | Current PC | `winget` |
| `license` | Windows license status and embedded OEM key information | Current PC | `license` |
| `hardware` | Hardware inventory, serial numbers, disks, memory, network adapters, and TPM when available | Current PC | `hardware` |
| `registry` | Registry hives, user profile hives, and Amcache with related logs | Current PC or mounted image | `registry` |
| `evtx` | Windows event logs | Current PC or mounted image | `evtx` |
| `prefetch` | Windows `.pf` files | Current PC or mounted image | `prefetch` |
| `anydesk` | Files from known AnyDesk locations | Current PC or mounted image | `anydesk` |

Runtime produces `connections.json` and `processes.json`. Winget produces
`installed_software.json`, `available_updates.json`, and `winget_environment.json`.
License produces `license_status.json`; hardware produces `hardware_info.json`.

Registry collection includes `NTUSER.DAT`, `UsrClass.dat`, their related files,
`ntuser.ini`, and `Windows\AppCompat\Programs\Amcache.hve` with its sidecar files.
Live collection can use temporary Windows shadow copies to read locked files.
Failed registry copies and exports retry up to three times, waiting 30 seconds
between attempts. The main runner applies the same retry limit to failed collectors.

WinGet collection queries software and updates; it does not install software or
run upgrades. Availability of individual sources depends on permissions and
installed Windows components.

## Run the PowerShell scripts instead

Keep the full repository together, including the `collectors` folder and
`collectors\CollectionMetadata.psm1`.

Open Windows PowerShell as Administrator. Change to the folder containing
`CHC_Collector.ps1`, then run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CHC_Collector.ps1 -ShowLog -OutputRoot 'C:\DFIR\Collections\ScriptRun01'
```

This execution policy setting applies to that process only. The script accepts
the same collection options shown for the EXE. Add `-ShowLog` to display progress;
the EXE enables it automatically.

### Download and run from GitHub

This option needs internet access. In an Administrator PowerShell window:

```powershell
New-Item -ItemType Directory -Path 'C:\DFIR' -Force | Out-Null
Set-Location 'C:\DFIR'
Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/zarubikus/CHC_Collector/refs/heads/main/support/CHC_Bootstrap.ps1' | Invoke-Expression
```

The bootstrap downloads the repository into `C:\DFIR\CHC_Collector` and runs it
with visible progress. Results go under `C:\DFIR\CHC_Collector\output`.

## Options reference

| Option | What it does |
| --- | --- |
| `-Artifacts 'registry,evtx'` | Runs only the named collectors. Omit it or use `all` to select all. |
| `-SourceRoot 'D:\MountedImage'` | Uses a mounted Windows source for collectors that support it. |
| `-OutputRoot 'E:\Collections\Run01'` | Chooses where results are saved. |
| `-MachineName 'HOST01'` | Sets the name used in output filenames. |
| `-NoArchive` | Keeps the collection folder instead of creating a ZIP. |
| `-ShowLog` | Shows progress as well as saving it to the log. |
| `-Log 'E:\Logs\collection.log'` | Chooses a custom log file. |
| `-NoCleanup` | Preserves existing target logs/ZIPs and skips collector cleanup. It does not create a separate run. |
| `-NoAdminRequired` | Allows the script to start without Administrator rights; protected sources can still fail. The EXE still requests elevation. |
| `-Help` | Shows help without collecting evidence. |

## File index and timestamps

Every collector writes to `collected_files.csv`. Each new row, including a failed
collection attempt, has a `CollectionDate`.

The 13 columns are:

```text
Source Type, Full Original Path, Destination Path,
File Created, File Modified, File Access, Size, Attributes,
SHA256, Collected, Collection Method, Message, CollectionDate
```

`Collected` shows whether collection succeeded; `Message` provides details.
When run through the master, `Destination Path` is relative to the collection or
ZIP root, for example `runtime\connections.json`.

Timestamps use this format:

```text
2026-09-30T21:03:52.6428650+08:00
```

It includes seven fractional second digits and a UTC offset. New collection times
use the collecting PC's local offset. Source timestamps that already include an
offset retain it; `+08:00` is not forced onto every timestamp.

| Field | Meaning |
| --- | --- |
| `CollectionDate` | When the collector observed a record or recorded a file collection attempt. |
| Connection `CreationTime` | When Windows created the TCP connection or UDP endpoint. |
| Process `CreationDate` | When the process started. Also appears inside a connection's `OwningProcess`. |
| Report `CollectionTime` | An existing field kept as an alias of the report's `CollectionDate`. |
| `File Created`, `File Modified`, `File Access` | Filesystem times for the source evidence or generated report/export. |

All four live inventory collectors add `CollectionDate` to each top-level JSON
record/report. Embedded runtime process records also include their collection time.
Missing source times stay empty. A source time that cannot be parsed produces a
warning and an empty value.

### Dates that keep other formats

- Installer `InstallDate` values are often date-only `yyyyMMdd`.
- Log prefixes use `yyyy-MM-dd HH:mm:ss`.
- Folder and archive names use `yyyyMMdd`.
- Raw WinGet output and copied evidence retain their original contents and dates.

Process `KernelModeTime` and `UserModeTime` are CPU durations, not dates.

## Build the EXE

You only need this when creating or updating the bundled EXE. From the repository
folder, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\support\Build-CollectorExe.ps1
```

Or double-click `support\Build-CollectorExe.bat`. No Administrator access or package
downloads are needed to build. The build uses the installed x64 .NET Framework
C# compiler and creates:

- `dist\CHC_Collector.exe`
- `dist\CHC_Collector.SHA256`

Use `-Destination 'E:\Build Output'` to change the build output folder. Rebuild
after changing the master, collectors, or shared metadata module. The EXE includes
all scripts and the module; its temporary extracted files are removed after exit.
The build is unsigned.

## If something goes wrong

| Problem | What to do |
| --- | --- |
| Administrator access is required | Open Windows PowerShell with **Run as administrator** and run again. |
| A source is missing or access is denied | Read the master log. Some evidence may not exist on that PC or image. |
| An old index is rejected | Choose a new `-OutputRoot` folder. |
| Cannot write output or logs | Choose a writable folder and check available disk space. |
| No ZIP was created | Check the log for archive errors. If `-NoArchive` was used, look for the dated collection folder. |
| A live inventory collector is skipped | With `-SourceRoot`, this is expected unless that collector is explicitly selected. |
