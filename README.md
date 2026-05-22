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


## Features

| Feature | Description |
|---------|-------------|
| Thumbnails | Auto-generated 3D thumbnails in Explorer |
| Preview pane | Live Hydra viewport in the Explorer preview pane |
| Context menus | Open, Edit, Compress/Uncrate, Package, Flatten |
| Windows Search | USD metadata indexed and searchable |

Supported formats: `.usd` `.usda` `.usdc` `.usdz`

## Overview

### Open & Tools

![Usd Tools](docs/img/demo_06.png)

![Usd Tools](docs/img/demo_05.png)

### Open in usdview

![Open in usdview](docs/img/demo_01.gif)

### Crate / Uncrate

![Crate, uncrate and open in editor](docs/img/demo_03.gif)

### Thumbnail

![Windows thumbnails](docs/img/demo_02.gif)

Demo scenes: [KitchenSet and UsdSkel](https://openusd.org/release/dl_downloads.html#assets) (Pixar, Apache 2.0), [ALab](https://animallogic.com/technology/alab/) (Animal Logic, CC BY 4.0).

## Documentation

| Guide | Who it's for |
|-------|-------------|
| [Quick Start](docs/QUICKSTART.md) | First install, step by step |
| [Technical Guide](docs/TECHNICAL.md) | Developers and contributors |
| [Runbook](docs/RUNBOOK.md) | IT / deployment / configuration |
| [Debug & FAQ](docs/DEBUG.md) | Troubleshooting and known issues |

## Inspiration & Credit

This project is a complete rewrite, heavily inspired by [Activision/USDShellExtension](https://github.com/Activision/USDShellExtension).

The original Activision project laid the foundation for integrating USD into Windows Explorer. This version rethinks the architecture from the ground up: updated build toolchain (VS 2026, NVIDIA USD 25.08, Python 3.12), a process isolation model that keeps Python out of the Explorer process, modern Windows 11 context menu support via `IExplorerCommand`, and a streamlined install workflow.


## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request; it covers the workspace setup, branch and commit conventions, pull request process, and coding style.

By participating in this project, you agree to abide by the [Code of Conduct](CONTRIBUTING.md#code-of-conduct).

## License

MIT - Copyright (C) 2025 Loops Creative Studio. See [LICENSE](LICENSE).

Third-party component notices, including logo attributions, are in [NOTICE.txt](NOTICE.txt).
