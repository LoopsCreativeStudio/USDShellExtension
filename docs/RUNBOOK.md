# Runbook

Operational procedures for installing, configuring, updating, and removing the USD Shell Extension.

## Install

### Requirements

- Windows 10 / 11 (64-bit)
- Administrator rights
- NVIDIA USD SDK 25.08 extracted on the build machine

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

If a previous installation exists at `C:\Program Files\Activision\UsdShellExtension\`, it is cleaned up automatically by `install.ps1`. A standalone cleanup script is also available on the IT share:

```
\\lps-srv-01\it\loops-it\toolbox\sandbox\windows\Remove-UsdShellExtension-Legacy.ps1
```

---

## Configuration: UsdShellExtension.ini

`UsdShellExtension.ini` is placed beside `UsdShellExtension.dll` in the install directory. Edit it to change runtime paths and behaviour without rebuilding.

```ini
[USD]
; Semicolon-separated directories added to PATH (usdview, usdrecord scripts)
PATH=D:\usd.py312.windows-x86_64.usdview.release-v25.08\bin;D:\...\lib

; Python module search path for USD Python bindings
PYTHONPATH=D:\usd.py312.windows-x86_64.usdview.release-v25.08\lib\python

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

The install is self-contained. To deploy without running `build.ps1` on each machine:

1. Build once on a build machine.
2. Copy `bin\v145\3.12\Release\` to each target machine.
3. Place a pre-written `UsdShellExtension.ini` in that folder.
4. Run `register.bat` as Administrator on each target.

Or use the NSIS installer (`UsdShellExtensionInstaller` project) for an `.exe` setup package.

---

## Diagnostics

Errors from all components are written to:

**Windows Event Viewer → Windows Logs → Application**  
Source: `USD Shell Extension`

See [DEBUG.md](DEBUG.md) for common error patterns.
