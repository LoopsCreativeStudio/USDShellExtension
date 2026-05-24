// USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
// Licensed under the MIT License. See LICENSE.txt for details.

#pragma once

// CLSID strings for each IExplorerCommand — referenced in ShellExtModule.rgs
// and via __declspec(uuid) on the concrete C++ classes.
#define CLSID_STR_UsdCmdEdit      "EFAB0002-5B7E-4A23-8C6D-9F1234567890"
#define CLSID_STR_UsdCmdUsdTools  "EFABFF01-5B7E-4A23-8C6D-9F1234567890"

// Internal sub-commands — created programmatically, not registered as verbs
#define CLSID_STR_UsdCmdCompress        "EFAB0003-5B7E-4A23-8C6D-9F1234567890"
#define CLSID_STR_UsdCmdUncompress      "EFAB0004-5B7E-4A23-8C6D-9F1234567890"
#define CLSID_STR_UsdCmdFlatten         "EFAB0005-5B7E-4A23-8C6D-9F1234567890"
#define CLSID_STR_UsdCmdRefreshThumb    "EFAB0006-5B7E-4A23-8C6D-9F1234567890"
#define CLSID_STR_UsdCmdStageStats      "EFAB0007-5B7E-4A23-8C6D-9F1234567890"
#define CLSID_STR_UsdCmdPackage         "EFAB0008-5B7E-4A23-8C6D-9F1234567890"
#define CLSID_STR_UsdCmdPackageDefault  "EFAB0009-5B7E-4A23-8C6D-9F1234567890"
#define CLSID_STR_UsdCmdPackageARKit    "EFAB000A-5B7E-4A23-8C6D-9F1234567890"
#define CLSID_STR_UsdCmdViewLogs        "EFABFF02-5B7E-4A23-8C6D-9F1234567890"
#define CLSID_STR_UsdContextMenu        "EFABFF03-5B7E-4A23-8C6D-9F1234567890"
#define CLSID_STR_UsdCmdValidate        "EFAB000B-5B7E-4A23-8C6D-9F1234567890"
#define CLSID_STR_UsdCmdFix             "EFAB000C-5B7E-4A23-8C6D-9F1234567890"
#define CLSID_STR_UsdCmdLayerStack      "EFAB000D-5B7E-4A23-8C6D-9F1234567890"
#define CLSID_STR_UsdCmdUnpackage       "EFAB000E-5B7E-4A23-8C6D-9F1234567890"
#define CLSID_STR_UsdCmdStitch          "EFAB000F-5B7E-4A23-8C6D-9F1234567890"
