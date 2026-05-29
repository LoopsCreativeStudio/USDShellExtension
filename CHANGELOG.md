# Changelog

## [1.9.0](https://github.com/LoopsCreativeStudio/USDShellExtension/compare/v1.8.0...v1.9.0) (2026-05-29)


### Features

* add Light and Select Camera submenus to preview pane context menu ([c6feedb](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/c6feedbea1d83556b3d841fd59b8f7cf0be78481))


### Bug Fixes

* add copy constructor and assignment to CPyObject, CPyString and CPyStringW to resolve C5272 warnings on CPyException throw ([e50176d](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/e50176d6d31a340d77f0854bf08b3b03f9657a13))
* add UTF-16 LE BOM to installer and uninstaller log files ([be71a40](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/be71a4003bed5638275e081b59045ed7dc1937da))
* auto-detect pip-packages directory when [PYTHON] PYTHONPATH is empty or invalid ([52cbf46](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/52cbf46a3d2652d489c0ab4fc220039380c43aa3))
* bundle Python runtime and pip-packages, improve installer logging and registry entries ([8a0a0c8](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/8a0a0c843973c5dc7dd1a7a744c4e61dcb1fd1fb))
* replace RmShutdown with taskkill /F and add polling for Explorer shutdown and restart ([9346600](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/934660086a6c7b2e4b951f4ef1ea4db1f8c0ad22))
* resolve usd.ico from registry when Python exe is outside install dir ([ee14f28](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/ee14f28b72b93688abaf7ffa4abbd25e22036b40))
* stage python and pip-packages directories for installer build ([c1a4209](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/c1a4209d88b9340d57984b219d062175fb56c65e))


### Performance Improvements

* throttle concurrent thumbnail renders to 3 slots via named semaphore ([0db6bb3](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/0db6bb31d5453b34d5bc3f9243dfa4a77a87a548))

## [1.8.0](https://github.com/LoopsCreativeStudio/USDShellExtension/compare/v1.7.0...v1.8.0) (2026-05-27)


### Features

* display time-based status messages on the preview load screen ([b59e5f2](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/b59e5f216a01af6a720f162d7055dcd3df255e7e))


### Bug Fixes

* add Defender exclusion during install and Restart Manager unlock for python312.dll ([d69b9b2](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/d69b9b29b8de44c0f808aa6540f1ba94c14c02ad))
* correct thumbnail camera orientation and restore PBR materials ([81c0e21](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/81c0e21233d23c115764265a07ef9fb346161bde))
* **nsis:** add Defender exclusion and DLL lock wait before uninstall deletion ([05691bf](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/05691bf0a894d1853d905397da8f65f0548c5025))
* rebuild Hydra Renderer context menu on right-click ([3db837d](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/3db837d8f9451d4aff2a7af02d15c2bdd57cb393))
* release USD stage on preview quit and fix uninstaller registry/explorer restart ([4ef670d](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/4ef670d343aa4552b2e93ef344fd0599b793a56e))
* release USD stage on preview quit and fix uninstaller registry/explorer restart ([d43112f](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/d43112f9bfb8c2f7f807b2edd610c4f8525a0052))
* resolve PSScriptAnalyzer warnings in install and uninstaller scripts ([885b2ed](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/885b2edaea54d22953a7bd0e534a0cc7b427bb10))
* run UsdThumbnailScript as Python subprocess to fix WGL renderer init ([5e0d1f7](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/5e0d1f73dc49acc3812b1045a71bb92cc5499939))
* use robocopy /PURGE for pip-packages to handle locked qwindows.dll ([0d48d78](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/0d48d781caf941755f7fc2f0ce71d466ed48d7a0))

## [1.7.0](https://github.com/LoopsCreativeStudio/USDShellExtension/compare/v1.6.0...v1.7.0) (2026-05-25)


### Features

* add -Installer switch to build.ps1 for NSIS packaging ([1e3f8cb](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/1e3f8cbc9bc81a17fc5b715f200ad627aba5793a))


### Bug Fixes

* declare COMMONAPPDATA var and remove usd_ms.dll from NSIS installer ([ff331e9](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/ff331e93242a1ea8a09f166dfaad1d1d1bbf50ec))
* installer config paths — All Users uses ProgramData, add Python PATH field ([6a0823c](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/6a0823ce3c5dbd128573d7da7600627d1a6cade7))
* use regsvr32 /n /i:"/force" in NSIS installer to bypass Python verification in DllRegisterServer ([841beaf](https://github.com/LoopsCreativeStudio/USDShellExtension/commit/841beaf4522b401234cd41c250b96f029538c6af))

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
