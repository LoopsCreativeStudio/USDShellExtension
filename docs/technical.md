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
└── Hosts Python: usdrecord (thumbnails), usdview (subprocess), usdchecker
    (Validate), usdfixbrokenpixarschemas (Fix Schemas), layer stack report,
    UsdUtils.ComputeUsdStageStats (Stage Statistics), UsdUtils.StitchLayers
    (Stitch Layers)

UsdSdkToolsLocalServer.exe  [COM Local Server, separate process]
└── Hosts C++ USD tools: format conversion (USD/USDA/USDC/USDZ), Unpackage
    (USDZ archive extraction via SdfZipFile)
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
| `UsdShellExtension/ExplorerCommands.cpp` | IExplorerCommand classes for the Windows 11 context menu |
| `UsdShellExtension/ShellExecute.cpp` | rundll32 entry points (legacy context menu, pre-Windows 11) |
| `UsdShellExtension/ShellExtModule.rgs` | ATL registry script, file associations and shell verbs |
| `UsdShellExtension/Module.cpp` | DllRegisterServer / DllUnregisterServer / DllInstall |
| `UsdPythonToolsServer/UsdPythonToolsImpl.cpp` | Python tool dispatch: thumbnails, usdview, Validate, Fix, Layer Stack, Stage Stats, Stitch |
| `shared/environment.h` | INI config loading, PATH/PYTHONPATH helpers |
| `shared/PythonUtil.h` | Python embedding helpers |

## Differences from Activision/USDShellExtension

This project is a complete rewrite inspired by [Activision/USDShellExtension](https://github.com/Activision/USDShellExtension). The table below summarizes what changed and why.

| Aspect | Activision | This repo |
|--------|-----------|-----------|
| USD SDK for Explorer DLL | Bare-bones monolithic build, compiled from source, with `--no-python --no-imaging` | NVIDIA USD 25.08 pre-built (full), isolated via Windows Activation Context |
| USD SDK for Python tools | Full shared build, compiled from source | Same NVIDIA USD 25.08 pre-built |
| How "no Python in Explorer" is enforced | Python excluded at the SDK level: the DLL's USD build has no Python support at all | Python excluded at the process level: all Python work goes to COM Local Server EXEs; the DLL itself never calls into Python |
| Boost | Separate build, matched to MSVC and Python version | `usd_boost.lib` / `usd_boost.dll` bundled in the NVIDIA SDK |
| Python version | 2.7, 3.6, 3.7 | 3.12 (bundled in the NVIDIA SDK) |
| USD library naming | Bare names: `tf.lib`, `sdf.lib` | `usd_`-prefixed: `usd_tf.lib`, `usd_sdf.lib` (NVIDIA convention) |
| Build USD from source | Required | Not required |
| Build process | Manual Visual Studio setup, two USD builds | `build.ps1` one-command build |
| Visual Studio version | 2017+ | 2026 Community (v145) |

### Why the Activision approach required two USD builds

The Activision repo kept Python entirely out of the Explorer process by using a USD build that had no Python support compiled in. This required maintaining two separate USD SDK builds: one stripped down for the DLL (no Python, no imaging), and one full build for the Python tools. Each build had to be compiled from source with matching Boost and Python versions, which is a significant infrastructure cost.

### How this repo achieves the same safety guarantee

This repo relies on COM Local Servers instead of SDK isolation. The DLL loaded into Explorer delegates every Python-dependent operation (preview, thumbnails, format conversion) to a separate EXE via out-of-process COM. If a COM server crashes, Explorer is unaffected. The DLL itself only uses the C++ USD SDK directly for fast, synchronous operations such as reading metadata via `IPropertyStore`.

A single NVIDIA pre-built SDK covers both the DLL's C++ USD usage and the Python tools, which eliminates the need to compile USD from source or maintain multiple SDK configurations.

### Trade-offs

The Activision approach is stricter: even a bug in the USD C++ code inside the Explorer DLL cannot accidentally invoke Python because Python is absent from the SDK. This repo's approach is safe in practice (Python is never called from the DLL), but requires discipline to maintain that invariant as the codebase evolves.

The NVIDIA pre-built approach trades flexibility (fixed release cadence, `usd_`-prefixed lib names) for zero build infrastructure. See [Why the NVIDIA pre-built bundle instead of a self-compiled USD](#why-the-nvidia-pre-built-bundle-instead-of-a-self-compiled-usd) for the full rationale.

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

The extension exposes two parallel context menu paths. Use the one that matches your target:

### Modern (Windows 11) IExplorerCommand verb

Recommended for all new commands. These appear in the Windows 11 context menu under the **USD Tools** submenu.

1. Add a string resource `IDS_SHELL_MYVERB` and an icon resource `IDR_ICON_MYVERB` in `ShellExt.rc` and `resource.h`.
2. Implement a `CUsdCmdMyVerb` class derived from `CUsdCmdBase` in `ExplorerCommands.h` / `ExplorerCommands.cpp`. Override `GetTitle`, `GetIcon`, and `Invoke`. Override `GetState` to return `ECS_HIDDEN` if the command should be conditionally hidden (e.g. only on `.usdz` files, or only on multi-selection).
3. Register the class in `Module.cpp` (`ATL_REGMAP_ENTRY`) and in `ExplorerCommands.h` (`CLSID_STR_UsdCmdMyVerb`).
4. Add the command to `CUsdCmdUsdTools::DoEnumSubCommands` in the appropriate group.
5. If the command calls a COM server, add the method to the relevant `.idl` and implement it in the corresponding `*Impl.cpp`.
6. Rebuild and reinstall.

### Legacy (pre-Windows 11) shell verb

Used for the classic context menu on older Windows versions. These are registered via `ShellExtModule.rgs` and invoked through `rundll32`.

1. Add a string resource `IDS_SHELL_MYVERB` in `ShellExt.rc`.
2. Add the verb block in `ShellExtModule.rgs` under the relevant ProgID(s), pointing to the rundll32 entry point.
3. Add a `rundll32` entry point function in `ShellExecute.cpp`.
4. Rebuild and reinstall.
