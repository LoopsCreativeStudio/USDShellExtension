# Quick Start

> **Just want to install?** Download the NVIDIA USD package and run the installer exe from the [latest release](https://github.com/LoopsCreativeStudio/USDShellExtension/releases/latest). See the [README](../README.md#quick-install) for the two-step instructions. No build required.

This guide gets the USD Shell Extension **built from source** and installed on a fresh Windows machine in about 15 minutes.

## Prerequisites

- Windows 11 (64-bit)
- [Git](https://git-scm.com/)
- [Visual Studio 2026](https://visualstudio.microsoft.com/vs/) with the following components:
  - Desktop development with C++
  - C++ ATL for latest v145 build tools
  - Windows 11 SDK (10.0.22000.0 or later)

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

The only required setting is `USD_SDK`, the path to the NVIDIA OpenUSD package (see Step 3).
All other values have sensible defaults and can be left commented out.

| Key | Default | Description |
|-----|---------|-------------|
| `USD_SDK` | *(required)* | Path to the NVIDIA OpenUSD pre-built package |
| `CONFIG` | `Release` | Build configuration: `Release` or `Debug` |
| `INSTALL_DIR` | `C:\Program Files\UsdShellExtension` | Installation directory |

## Step 3: Download the NVIDIA USD SDK

Go to the [NVIDIA OpenUSD page](https://developer.nvidia.com/openusd#section-getting-started) and download the pre-built Windows package:

> **usd.py312.windows-x86_64.usdview.release-v25.08**

Extract it to `D:\usd.py312.windows-x86_64.usdview.release-v25.08`, or to any path; then set `USD_SDK` in your `.env` accordingly.

## Step 4: Build

Open PowerShell in the repository root and run:

```powershell
.\build.ps1
```

This finds MSBuild automatically, compiles all projects, and assembles the output in `bin\v145\3.12\Release\`.

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
