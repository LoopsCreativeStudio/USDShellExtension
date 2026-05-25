# Changelog

## [1.6.0](https://github.com/LoopsCreativeStudio/USDShellExtension/compare/v1.5.0...v1.6.0) (2026-05-25)


### Features

* add Diff command for two-file USD comparison via usddiff ([8e0f58e](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/8e0f58ebbf4f713f5a915b46b6787c226db3745d))
* add OpenUSD Documentation link to context menu ([c8f894b](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/c8f894bd9f0bf6ad396f083d31ae17810e92f14b))
* batch validate for multi-file selection (Validate, Fix, Layer Stack) ([05832b2](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/05832b2aae453e23c98cbd72c97c1d97f4e40c90))
* group format conversions under Convert to... submenu ([e263f18](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/e263f18a70626e5907fd43d1334a8ef2931fe829))

## [1.5.0](https://github.com/LoopsCreativeStudio/USDShellExtension/compare/v1.4.0...v1.5.0) (2026-05-25)


### Features

* add animation timeline to preview pane ([3669840](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/36698402fc99871082f8dfa5d844a68d2c002181))
* add persistent prim path bar with placeholder in preview pane ([9aab91f](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/9aab91f373f347330e2028b9bbfc2258d9a66fde))
* add prim path display on hover and left-click selection in preview pane ([95c46f2](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/95c46f2b3487ad95ca36084c52d978f26834bd54))
* add Stitch Layers command for multi-selection USD files ([58a005c](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/58a005cacfb7837a675a934a59d8f29d3a898877))
* add Unpackage command for .usdz files ([a684134](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/a68413433633b9f3a1ab53f9069a32f58b6f572b))
* add usd-shell.ps1 utility to configure USD environment ([6549a2c](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/6549a2ccbf04a3039364101dab5061e12bd411b9))
* add Validate, Fix and Layer Stack context menu commands ([5628800](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/562880070c356e6c7959e1c35e0107b578e26967))
* add Validate, Fix, Layer Stack, Stage Stats context menu commands ([5745b7d](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/5745b7d2ce9504787f6b7b38208a6fc398f87d66))
* first commit ([9f02dc5](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/9f02dc5a3ca354b240ac2f10028a27052c732ad6))


### Bug Fixes

* correct FriendlyTypeName for usda/usdc/usdz and remove PropertyStore noise ([4b0f9ff](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/4b0f9ff644000660ddf5176fa00ab5a9fbeb598a))
* fix PySide6/USD 25.08 compatibility in preview handler Python script ([649d58d](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/649d58d29da6f8c731332286605eb5e9116af1b6))
* handle locked DLLs and Windows Search in install.ps1 ([d00c248](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/d00c248d2ef0645c91d36c7edd09f784badfbe68))
* improve console pause and stage stats output in UsdSdkTools ([66ae2db](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/66ae2dbda38e4d53758d0a75a1ca58237ac3ebeb))
* kill Explorer before polling python312.dll lock in install.ps1 ([895e5d9](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/895e5d95f61774f982b60d248e6c36e7968e472a))
* open USD files with FILE_SHARE_DELETE in ArResolver ([8ec75d0](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/8ec75d0a5c5ced9fb06065be820920fdcb213c16))

## [1.4.0](https://github.com/LoopsCreativeStudio/USDShellExtension/compare/v1.3.0...v1.4.0) (2026-05-25)


### Features

* add Stitch Layers command for multi-selection USD files ([f11d802](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/f11d802a04c4680fa5f41881617828ca3dafc26b))
* add Unpackage command for .usdz files ([e794fa0](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/e794fa06e5342e903d22b4df126ab5e7afef861b))
* add Validate, Fix, Layer Stack, Stage Stats context menu commands ([2237c5e](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/2237c5edf9dc8ae3449fefe8ab16595b81f76196))


### Bug Fixes

* correct FriendlyTypeName for usda/usdc/usdz and remove PropertyStore noise ([6063d47](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/6063d477619b31078d6847c4e85556c7941c2ef1))

## [1.3.0](https://github.com/LoopsCreativeStudio/USDShellExtension/compare/v1.2.0...v1.3.0) (2026-05-23)


### Features

* add animation timeline to preview pane ([3669840](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/36698402fc99871082f8dfa5d844a68d2c002181))
* add usd-shell.ps1 utility to configure USD environment ([6549a2c](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/6549a2ccbf04a3039364101dab5061e12bd411b9))
* add Validate, Fix and Layer Stack context menu commands ([5628800](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/562880070c356e6c7959e1c35e0107b578e26967))


### Bug Fixes

* handle locked DLLs and Windows Search in install.ps1 ([d00c248](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/d00c248d2ef0645c91d36c7edd09f784badfbe68))
* improve console pause and stage stats output in UsdSdkTools ([66ae2db](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/66ae2dbda38e4d53758d0a75a1ca58237ac3ebeb))
* kill Explorer before polling python312.dll lock in install.ps1 ([895e5d9](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/895e5d95f61774f982b60d248e6c36e7968e472a))
* open USD files with FILE_SHARE_DELETE in ArResolver ([8ec75d0](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/8ec75d0a5c5ced9fb06065be820920fdcb213c16))

## [1.2.0](https://github.com/LoopsCreativeStudio/USDShellExtension/compare/v1.1.1...v1.2.0) (2026-05-22)


### Features

* add persistent prim path bar with placeholder in preview pane ([9aab91f](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/9aab91f373f347330e2028b9bbfc2258d9a66fde))
* add prim path display on hover and left-click selection in preview pane ([95c46f2](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/95c46f2b3487ad95ca36084c52d978f26834bd54))

## [1.1.1](https://github.com/LoopsCreativeStudio/USDShellExtension/compare/v1.1.0...v1.1.1) (2026-05-22)


### Bug Fixes

* fix PySide6/USD 25.08 compatibility in preview handler Python script ([649d58d](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/649d58d29da6f8c731332286605eb5e9116af1b6))

## [1.1.0](https://github.com/LoopsCreativeStudio/USDShellExtension/compare/v1.0.0...v1.1.0) (2026-05-22)


### Features

* first commit ([9f02dc5](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/9f02dc5a3ca354b240ac2f10028a27052c732ad6))

## CHANGELOG
