# Quick Start

> **Just want to install?** Run the installer exe from the [latest release](https://github.com/LoopsCreativeStudio/USDShellExtension/releases/latest). See the [README](../README.md#quick-install). No build required.

This guide gets the USD Shell Extension **built from source** and installed on a fresh Windows machine. The first OpenUSD build takes one to two hours; the extension itself then builds in under a minute.

## Prerequisites

- Windows 11 (64-bit)
- [Git](https://git-scm.com/)
- [CMake](https://cmake.org/download/) 4.2 or later (first version with the Visual Studio 2026 generator)
- [Visual Studio 2026](https://visualstudio.microsoft.com/vs/) with the following components:
  - Desktop development with C++
  - C++ ATL for latest v145 build tools
  - Windows 11 SDK (10.0.22000.0 or later)
- Optional: [NASM](https://www.nasm.us/) on `PATH` (faster JPEG decoding in the OpenUSD build)
- About 30 GB of free disk for the OpenUSD build

## Step 1: Clone the repository

```powershell
git clone https://github.com/LoopsCreativeStudio/USDShellExtension.git
cd UsdShellExtension
```

## Step 2: Configure your environment

Copy the sample configuration file and edit it:

```powershell
Copy-Item .env.sample .env
notepad .env
```

`USD_SDK` is the OpenUSD SDK built in Step 3. All values have sensible defaults and can be left commented out.

| Key | Default | Description |
|-----|---------|-------------|
| `USD_SDK` | `D:\OpenUSD\install\v26.11.1-py312` | OpenUSD SDK built by `build-openusd.ps1` |
| `CONFIG` | `Release` | Build configuration: `Release` or `Debug` |
| `INSTALL_DIR` | `C:\Program Files\UsdShellExtension` | Installation directory |
| `OPENUSD_VERSION` | `v26.11.1` | OpenUSD release tag built by `build-openusd.ps1` |
| `PYTHON_VERSION` | `3.12.10` | Python runtime (NuGet `python` package) |
| `OPENUSD_DIR` | `D:\OpenUSD` | Root folder for the OpenUSD sources, build and SDK |

## Step 3: Build OpenUSD

```powershell
.\build-openusd.ps1
```

The script downloads Python 3.12 and its packages (PySide6, PyOpenGL), clones the OpenUSD release tag and builds it with its dependencies (TBB, OpenEXR, OpenImageIO, OpenColorIO, MaterialX, OpenSubdiv, Ptex, Alembic). The result is the SDK folder `D:\OpenUSD\install\v26.11.1-py312`, with the Python runtime and the license texts. Each step already done is skipped, so the script can be run again after a failure. Transcript in `build-openusd.log`.

## Step 4: Build

Open PowerShell in the repository root and run:

```powershell
.\build.ps1
```

This finds MSBuild automatically, compiles all projects, and assembles the output in `bin\v145\3.12\Release\`.

To also produce the setup `.exe`, run `.\build.ps1 -Installer` (needs [NSIS](https://nsis.sourceforge.io/) installed in `C:\Program Files\NSIS\`).

Expected duration for a first build from a fresh clone (no `bin\` folder yet, OpenUSD already built), measured on an Intel Core i7-11700KF (8 cores, 16 threads), 64 GB RAM, NVMe SSD, Windows 11 Pro:

| Command | Duration | What takes the time |
|---------|----------|---------------------|
| `.\build.ps1` | about 25 s | Compiling the projects and copying the USD and Python runtime (about 640 MB) from the SDK |
| `.\build.ps1 -Installer` (after the build above) | about 3 min | NSIS compressing the runtime into a setup `.exe` of about 120 MB |

OpenUSD is built once by Step 3, so nothing from USD itself is compiled here. Later builds are incremental and faster. A slower disk or antivirus scanning of the copied files can lengthen the copy step.

## Step 5: Install

Open an **Administrator** PowerShell and run:

```powershell
.\install.ps1
```

This copies the build output to `C:\Program Files\UsdShellExtension\` and registers the COM servers.

## Step 6: Done

Right-click any `.usd`, `.usda`, `.usdc`, or `.usdz` file in Explorer. You should see a **USD Tools** submenu with:

- **View / Edit**: open in usdview or your configured text editor
- **Crate / Uncrate / Flatten / Package / Unpackage**: format conversions
- **Validate / Fix Schemas / Layer Stack / Stage Statistics**: inspection tools
- **Stitch Layers**: available when 2 or more USD files are selected
- Thumbnails and 3D preview pane are active automatically

## Uninstall

```powershell
# Run as Administrator
.\install.ps1 -Uninstall
```

---

See [runbook.md](runbook.md) for configuration options, and [debug.md](debug.md) if something isn't working.
