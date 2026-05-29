<h1 align="center">
  <br>
  <a href="https://github.com/LoopsCreativeStudio/USDShellExtension"><img src="docs/header.png" alt="loops-it" width="400"></a>
</h1>

<h4 align="center">Windows Explorer integration for  <a href="https://openusd.org/">Pixar USD</a> files - thumbnails, 3D preview, context menus, and metadata search.</h4>

<p align="center">
  <a href="https://github.com/LoopsCreativeStudio/USDShellExtension/actions/workflows/release.yaml">
    <img src="https://github.com/LoopsCreativeStudio/USDShellExtension/actions/workflows/release.yaml/badge.svg?branch=main" alt="Release">
  </a>
  <a href="https://github.com/googleapis/release-please">
    <img src="https://img.shields.io/badge/release--please-conventional--commits-brightgreen?logo=github" alt="release-please">
  </a>
  <a href="">
    <img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT">
  </a>
</p>


## Quick Install

No build required. Two steps:

**1. Download the NVIDIA OpenUSD pre-built package**

Go to the [NVIDIA OpenUSD page](https://developer.nvidia.com/openusd#section-getting-started) and download:

> `usd.py312.windows-x86_64.usdview.release-v25.08`

Extract it anywhere on your machine (e.g. `D:\usd.py312.windows-x86_64.usdview.release-v25.08`).

**2. Run the installer**

Download `UsdShellExtension-v*-setup.exe` from the [latest release](https://github.com/LoopsCreativeStudio/USDShellExtension/releases/latest) and run it as Administrator. The installer will ask for the path to the NVIDIA SDK and configure everything automatically.

That's it. Right-click any `.usd` / `.usda` / `.usdc` / `.usdz` file to get started.

> Building from source is only needed if you want to modify the code. See the [Quick Start](docs/quickstart.md) guide.

---

## Features

Supported formats: `.usd` `.usda` `.usdc` `.usdz`

| Feature | Description |
|---------|-------------|
| Thumbnails | Auto-generated 3D thumbnails via `usdrecord`, cached by Windows. Headlight is automatically disabled when the scene contains its own lights. |
| Preview pane | Live Hydra viewport with prim path bar, animation timeline, light controls (scene lights, camera light, dome light) and camera selection. |
| Context menu | View, Edit, Crate/Uncrate, Flatten, Package, Unpackage, Stitch, Diff, Validate, Fix, Layer Stack, Stage Statistics |
| Windows Search | USD metadata indexed and searchable (frame range, frame rate, format, custom layer data) |
| File type icons | Custom icons and friendly type names for each USD format |

See [Features](docs/features.md) for the full description of each command.

## Overview

### Context menu
![Context right clic](docs/img/feat_overview.gif)

### Windows preview pane
![Windows preview static](docs/img/feat_preview.gif)

### Timeline
![Windows preview animation](docs/img/feat_animation.gif)


Demo scenes: [KitchenSet and UsdSkel](https://openusd.org/release/dl_downloads.html#assets) (Pixar, Apache 2.0).

## Documentation

| Guide | Who it's for |
|-------|-------------|
| [Features](docs/features.md) | Full description of every feature and context menu command |
| [Quick Start](docs/quickstart.md) | First install, step by step |
| [Technical Guide](docs/technical.md) | Developers and contributors |
| [Runbook](docs/runbook.md) | IT / deployment / configuration |
| [Debug & FAQ](docs/debug.md) | Troubleshooting and known issues |

## Inspiration & Credit

This project is a complete rewrite, heavily inspired by [Activision/USDShellExtension](https://github.com/Activision/USDShellExtension).

The original Activision project laid the foundation for integrating USD into Windows Explorer. This version rethinks the architecture from the ground up: updated build toolchain (VS 2026, NVIDIA USD 25.08, Python 3.12), a process isolation model that keeps Python out of the Explorer process, modern Windows 11 context menu support via `IExplorerCommand`, and a streamlined install workflow.

The two main architectural differences from the Activision repo: the Activision version required two separate USD builds compiled from source (a bare-bones monolithic build with no Python for the Explorer DLL, and a full build for the Python tools), whereas this version uses a single NVIDIA pre-built SDK for everything. The Activision version enforced the "no Python in Explorer" rule by excluding Python from the SDK used by the DLL; this version enforces the same rule structurally, by routing all Python work through isolated COM Local Server executables. See the [Technical Guide](docs/technical.md) for a full comparison.


## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request; it covers the workspace setup, branch and commit conventions, pull request process, and coding style.

- **Bug reports**: open an issue at [github.com/LoopsCreativeStudio/USDShellExtension/issues](https://github.com/LoopsCreativeStudio/USDShellExtension/issues).
- **Feature requests and ideas**: use [Discussions](https://github.com/LoopsCreativeStudio/USDShellExtension/discussions) to propose and discuss new functionality before opening a pull request.

By participating in this project, you agree to abide by the [Code of Conduct](CONTRIBUTING.md#code-of-conduct).

## License

MIT - Copyright (C) 2025 Loops Creative Studio. See [LICENSE.txt](LICENSE.txt).

Third-party component notices, including logo attributions, are in [NOTICE.txt](NOTICE.txt).
