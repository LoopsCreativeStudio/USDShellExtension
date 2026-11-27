# Runbook

Operational procedures for installing, configuring, updating, and removing the USD Shell Extension.

## Install

### Requirements

- Windows 10 / 11 (64-bit)
- Administrator rights
- On the build machine only: the OpenUSD 26.11 SDK built by `build-openusd.ps1` (see [Quick Start](quickstart.md))

### Build then install

```powershell
# 1. Build (any user, from repo root)
.\build.ps1

# 2. Install (must be Administrator)
.\install.ps1
```

Install location: `C:\Program Files\UsdShellExtension\`  
Install size: ~400 MB

### Custom install directory

```powershell
.\install.ps1 -InstallDir "D:\Tools\UsdShellExtension"
```

### Debug build

```powershell
.\build.ps1 -Config Debug
.\install.ps1 -Config Debug
```

---

## Update

Re-run build + install. The install script automatically:

1. Unregisters the current installation
2. Stops COM server processes and restarts Explorer to release locked DLLs
3. Copies the new files
4. Registers the COM servers
5. Clears the Windows MuiCache

```powershell
.\build.ps1
.\install.ps1   # as Administrator
```

---

## Uninstall

```powershell
# As Administrator
.\install.ps1 -Uninstall
```

This unregisters all COM servers, removes the install directory, and clears MuiCache entries.

### Remove a legacy Activision installation

If a previous installation exists at `C:\Program Files\Activision\UsdShellExtension\`, it is cleaned up automatically by `install.ps1`.


---

## Configuration: UsdShellExtension.ini

`UsdShellExtension.ini` is placed beside `UsdShellExtension.dll` in the install directory. Edit it to change runtime paths and behaviour without rebuilding.

```ini
[USD]
; Semicolon-separated directories added to PATH (USD DLLs and tools: usdview, usdrecord, ...)
PATH=C:\Program Files\UsdShellExtension

; Python module search path for USD Python bindings
PYTHONPATH=C:\Program Files\UsdShellExtension\lib\python

; Leave empty to use the bundled plugins in the usd\ subfolder
PXR_PLUGINPATH_NAME=

; Text editor for the "Edit" context menu, must block until the file is closed
EDITOR=

[RENDERER]
; Hydra renderer for each feature. Leave empty for Storm (default).
; Other options: GL, Embree, Arnold, ...
PREVIEW=
THUMBNAIL=
VIEW=

[PYTHON]
; Path to the bundled Python (copied by install.ps1)
PATH=%ProgramFiles%\UsdShellExtension\python\

; Additional packages (PySide6, PyOpenGL)
PYTHONPATH=%ProgramFiles%\UsdShellExtension\pip-packages
```

### Configuring the text editor

The editor command must block (not return) until the user closes the file.

**VS Code:**
```ini
[USD]
EDITOR="C:\Users\<username>\AppData\Local\Programs\Microsoft VS Code\Code.exe" --wait
```

**Notepad++ (default install):**
```ini
[USD]
EDITOR="C:\Program Files\Notepad++\notepad++.exe" -multiInst -notabbar -nosession
```

### Configuring a Hydra renderer

Install the renderer plugin alongside the USD SDK, then set:
```ini
[RENDERER]
PREVIEW=Embree
THUMBNAIL=Embree
VIEW=Embree
```

---

## File associations

The installer registers `.usd`, `.usda`, `.usdc`, `.usdz` as the default handler. If a user has manually associated one of these extensions with another application, their personal association takes priority.

To reset the association for a user:

**Settings → Apps → Default apps → Choose defaults by file type**

Set `.usd`, `.usda`, `.usdc`, `.usdz` to **USD Shell Extension**.

---

## Deploying to multiple machines

Use the setup `.exe` from the [releases](https://github.com/LoopsCreativeStudio/USDShellExtension/releases): it is self-contained (USD and Python runtime included), installs silently, registers an entry in *Installed apps*, and replaces files that Explorer keeps loaded during an update.

### Verifying a download

The setup `.exe` is not code-signed (Windows shows *Unknown publisher*). Each release also has a `<setup>.exe.sha256` file holding its SHA256; check that it matches before deploying:

```powershell
(Get-FileHash .\UsdShellExtension-vX.Y.Z-u26.11-p3.14-setup.exe -Algorithm SHA256).Hash
Get-Content .\UsdShellExtension-vX.Y.Z-u26.11-p3.14-setup.exe.sha256
```

The same value can be given to Chocolatey (`-Checksum64 <hash> -ChecksumType64 sha256`) when the package downloads the setup from the release.

### Silent install

Run as Administrator or SYSTEM (Intune, SCCM / ConfigMgr, a GPO startup script, Chocolatey):

```bat
UsdShellExtension-vX.Y.Z-u26.11-p3.14-setup.exe /S
```

| Option | Effect |
|--------|--------|
| `/S` | Silent: no window, no dialog. |
| `/D=C:\Path\To\Folder` | Install folder. Must be the **last** argument, without quotes, even with spaces. Default: `C:\Program Files\UsdShellExtension`. |
| `/RENDERER_PREVIEW=GL` (and `/RENDERER_THUMBNAIL=`, `/RENDERER_VIEW=`) | Hydra renderer written to the INI files. |

An existing installation is uninstalled first (in its own folder, waiting for the end), then replaced. A deployment made by copying files, without an *Installed apps* entry, is simply overwritten. Files that an uninstall could not delete (still in use) are scheduled for deletion at the next reboot; the install cancels those scheduled deletions in its folder, so the reboot does not remove the new files.

The installer stops Windows Explorer and restarts it at the end. With nobody logged in (startup or shutdown script) nothing is visible; with a user logged in, the taskbar and Explorer windows close and come back. No antivirus setting is changed.

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | Installed. |
| `1` | Cancelled by the user (interactive install only). |
| `2` | Aborted, or `UsdShellExtension.dll` registration failed: the extension does not appear in Explorer. See the log. |
| `3010` | Installed, but a file still in use is replaced at the next reboot. Treat it as a success with a pending reboot. |

The log is written to `%TEMP%\UsdShellExtension_setup.log` of the installing account, i.e. `C:\Windows\Temp\UsdShellExtension_setup.log` when run as SYSTEM.

### Detection rule

Either of:

- Registry: `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\UsdShellExtension`, value `DisplayVersion` (e.g. `1.10.5.0`); `InstallLocation` holds the install folder.
- File: `C:\Program Files\UsdShellExtension\UsdPreviewLocalServer.exe` (file version = product version).

### Silent uninstall

```bat
"C:\Program Files\UsdShellExtension\uninstall.exe" /S _?=C:\Program Files\UsdShellExtension
```

The same command is stored in the `QuietUninstallString` value of the Uninstall key. Keep `_?=<install folder>` (last, without quotes): without it the uninstaller copies itself to `%TEMP%` and returns immediately, before the uninstall is done. Exit codes: `0`, or `3010` when some files are deleted at the next reboot. The log is `%TEMP%\UsdShellExtension_uninstall.log`.

### Examples

- **Intune (Win32 app)**: package the `.exe` with the Win32 Content Prep Tool. Install command `UsdShellExtension-vX.Y.Z-u26.11-p3.14-setup.exe /S`, uninstall command as above, install behavior *System*, return code `3010` = *Soft reboot*, detection rule on the registry `DisplayVersion` or on the file.
- **SCCM / ConfigMgr (application, script installer)**: same commands and detection rule; `3010` is a soft reboot by default.
- **Chocolatey**: `Install-ChocolateyInstallPackage` with `silentArgs = '/S'` and `validExitCodes = @(0, 3010)`; in `chocolateyUninstall.ps1`, run `uninstall.exe /S _?=<install folder>` (folder from `InstallLocation`).

### Manual deployment (no installer)

Copying `bin\v145\3.14\Release\` and running `register.bat` as Administrator also works, but gives no *Installed apps* entry, no version detection and no clean uninstall, and an update fails while Explorer keeps the DLLs loaded. Prefer the setup `.exe`.

---

## Diagnostics

Errors from all components are written to:

**Windows Event Viewer → Windows Logs → Application**  
Source: `USD Shell Extension`

See [debug.md](debug.md) for common error patterns.
