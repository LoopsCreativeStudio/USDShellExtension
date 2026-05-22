# Technical Guide

## Architecture

The core constraint: **Python must never run inside the Windows Explorer process.** A Python crash would take down Explorer and the entire desktop. All Python-dependent features are delegated to isolated COM Local Server executables via out-of-process COM calls.

### Process model

```
Windows Explorer (explorer.exe)
└── UsdShellExtension.dll  [in-process]
    ├── IPropertyStore      → reads USD metadata via C++ SDK directly (fast, no Python)
    ├── IPreviewHandler     → delegates to UsdPreviewLocalServer.exe via COM
    └── IThumbnailProvider  → delegates to UsdPythonToolsLocalServer.exe via COM

UsdPreviewLocalServer.exe   [COM Local Server, separate process]
└── Hosts Python, runs UsdPreviewHandlerPython.py (usdStageView)

UsdPythonToolsLocalServer.exe  [COM Local Server, separate process]
└── Hosts Python, runs usdrecord (thumbnails) and launches usdview (subprocess)

UsdSdkToolsLocalServer.exe  [COM Local Server, separate process]
└── Hosts C++ USD tools for format conversion (USD ↔ USDA ↔ USDC ↔ USDZ)
```

If a COM server crashes, Explorer is unaffected.

### Projects

| Project | Type | Description |
|---------|------|-------------|
| `UsdShellExtension` | DLL | Core shell extension, loaded into Explorer |
| `UsdPreviewLocalServer` | EXE | COM server hosting the usdStageView preview |
| `UsdPreviewHandlerPython` | `.pyd` | Python C extension bridging C++ and the preview script |
| `UsdPythonToolsLocalServer` | EXE | COM server for thumbnails (usdrecord) and usdview |
| `UsdSdkToolsLocalServer` | EXE | COM server for USD format conversions |
| `EventViewerMessages` | Static lib | Shared Windows Event Log message table |

### Key files

| File | Role |
|------|------|
| `UsdShellExtension/ShellPreviewHandlerImpl.cpp` | IPreviewHandler, spawns UsdPreviewLocalServer |
| `UsdShellExtension/ShellThumbnailProviderImpl.cpp` | IThumbnailProvider, calls UsdPythonToolsLocalServer |
| `UsdShellExtension/ShellPropertyStoreImpl.cpp` | IPropertyStore, reads USD metadata in-process |
| `UsdShellExtension/ShellExecute.cpp` | rundll32 entry points for context menu commands |
| `UsdShellExtension/ShellExtModule.rgs` | ATL registry script, file associations and shell verbs |
| `UsdShellExtension/Module.cpp` | DllRegisterServer / DllUnregisterServer / DllInstall |
| `UsdPythonToolsServer/UsdPythonToolsImpl.cpp` | Record() (thumbnail) and View() (usdview subprocess) |
| `shared/environment.h` | INI config loading, PATH/PYTHONPATH helpers |
| `shared/PythonUtil.h` | Python embedding helpers |

## Build system

**Toolchain**: Visual Studio 2026, v145, x64 only.

### Linters

| Tool | Scope | Config file |
|------|-------|-------------|
| Ruff | Python files in `UsdPreviewHandlerServer/` and `UsdPythonToolsServer/` | default rules |
| PSScriptAnalyzer | `*.ps1` files (`build.ps1`, `install.ps1`, `uninstaller.ps1`) | `PSScriptAnalyzerSettings.psd1` |

Both linters run in CI (`.github/workflows/ci.yaml`) and can be run locally with the same configuration:

```powershell
# Python
pip install ruff
ruff check UsdPreviewHandlerServer/ UsdPythonToolsServer/

# PowerShell
$files = Get-ChildItem -Filter "*.ps1" -Recurse
$files | ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName -Settings .\PSScriptAnalyzerSettings.psd1 -Severity Warning,Error }
```

`PSScriptAnalyzerSettings.psd1` excludes the `PSAvoidUsingWriteHost` rule. The three scripts are interactive (build, install, uninstall) and rely on `Write-Host -ForegroundColor` for colored terminal output. All scripts declare `#Requires -Version 5.1`, which makes `Write-Host` fully suppressable and redirectable, so the rule does not apply.

### Property sheets

| File | Purpose |
|------|---------|
| `usd-shared.props` | NVIDIA USD 25.08 include/lib paths, `usd_`-prefixed lib names |
| `boost.props` | `usd_boost.lib` / `usd_boost.dll` from the NVIDIA SDK |
| `python.props` | Python 3.12 bundled in the SDK (`python\` subfolder) |
| `version.props` | Version numbers and product/company strings for all RC files |

### Build output

```
bin\v145\3.12\Release\
├── UsdShellExtension.dll
├── UsdPreviewLocalServer.exe
├── UsdPreviewHandlerPython.pyd (.UsdPreviewHandler Python module)
├── UsdPythonToolsLocalServer.exe
├── UsdSdkToolsLocalServer.exe
├── usd_*.dll              (USD runtime DLLs)
├── python312.dll, python3.dll
├── tbb.dll, tbbmalloc.dll, tbbmalloc_proxy.dll
├── usd\                   (USD plugin manifests)
├── register.bat / unregister.bat
└── UsdShellExtension.ini
```

## Distribution

### Installation layout

`install.ps1` copies the build output to `C:\Program Files\UsdShellExtension\` and also places `uninstaller.ps1` alongside the binaries:

```
C:\Program Files\UsdShellExtension\
├── UsdShellExtension.dll
├── UsdPreviewLocalServer.exe
├── UsdPythonToolsLocalServer.exe
├── UsdSdkToolsLocalServer.exe
├── register.bat / unregister.bat
├── uninstaller.ps1          ← standalone uninstaller
├── UsdShellExtension.ini
├── usd_*.dll
├── python\
├── usd\
└── plugin\
```

`uninstaller.ps1` can be run directly from the install directory (it auto-elevates if needed). It stops all COM servers and Explorer, unregisters COM, clears the icon and thumbnail caches, removes the install directory, then restarts Explorer.

## Key implementation details

### usdview launched as subprocess (not embedded Python)

`UsdPythonToolsImpl::View()` uses `CreateProcess` rather than `PyRun_String`. Running usdview via embedded Python inside the COM server's STA apartment causes Qt/PySide6 to fail initializing the WGL OpenGL context, resulting in a black viewport. A subprocess inherits the environment (PATH, PYTHONPATH, PYTHONHOME) and gets a fresh Qt context.

### USD Activation Context

The USD DLLs and their dependencies are isolated via a Windows Activation Context (the `.manifest` file embedded in the DLL). This prevents version clashes if another Explorer extension loads a different copy of USD.

### ArResolver plugin

`ArResolverShellExtension` is registered as a USD ArResolver plugin. Its only job: override `fopen` to use `_SH_DENYNO` (shared read mode) instead of the MSVC default that denies concurrent reads. Required because multiple Explorer processes may read the same USD file simultaneously.

### Registry: file associations

`ShellExtModule.rgs` registers:
- ProgIDs `OpenUSD.USD`, `OpenUSD.USDA`, `OpenUSD.USDC`, `OpenUSD.USDZ` with shell verbs
- Extensions `.usd`, `.usda`, `.usdc`, `.usdz` with their default ProgID set, which makes the verbs appear in the Explorer context menu (not just `OpenWithProgids`)

### Why the NVIDIA pre-built bundle instead of a self-compiled USD

The NVIDIA OpenUSD bundle was chosen over compiling USD from source for the following reasons:

- **Zero build infrastructure**: compiling USD on Windows requires CMake, Boost, TBB, OpenSubdiv, MaterialX, GLEW and a full Visual Studio toolchain configured for each dependency, a multi-hour build with a large surface for version conflicts.
- **Pre-tested with usdview and usdrecord**: the bundle ships a known-good Python 3.12 + PySide6 + PyOpenGL combination that runs usdview and usdrecord without additional setup.
- **Maintenance cost**: every USD or Python update would require a full rebuild and re-validation. The NVIDIA release cadence (one or two drops per year) is sufficient for a shell extension.
- **Scope fit**: this project consumes USD in read-only mode (metadata, preview, thumbnail). The small differences a custom build could offer, such as stripped plugins, a different Python version, or custom patches, do not justify the overhead.

The main trade-off is coupling to NVIDIA's release schedule and their `usd_`-prefixed library naming (see `usd-shared.props`). If a critical USD fix or a specific Python version is ever required, switching to a self-built USD is feasible: update `usd-shared.props`, `boost.props`, and `python.props` to point at the new SDK.

### Dependency notes

- **pxr_boost**: `usd_boost.lib` / `usd_boost.dll`. Use `#include <pxr/external/boost/python.hpp>` and `namespace pxr_boost::python`.
- **TBB**: `tbb.dll` / `tbbmalloc.dll` (NVIDIA 25.08 naming, not `tbb12.dll`).
- **USD libs**: all prefixed `usd_` (e.g. `usd_tf.lib`, `usd_sdf.lib`).
- **Python**: bundled in the SDK at `python\`. No separate Python installation needed.

## Adding a new context menu verb

1. Add a string resource `IDS_SHELL_MYVERB` in `ShellExt.rc`.
2. Add the verb block in `ShellExtModule.rgs` under the relevant ProgID(s).
3. Add a `rundll32` entry point function in `ShellExecute.cpp`.
4. Update `Module.cpp::UpdateRegistry` if the string ID needs a regmap entry.
5. Rebuild and reinstall.
