;--------------------------------
; UsdPathPage

Var hWndUsdPathDlg
Var hWndUsdPathEditSdkRoot
Var hWndUsdPathButtonBrowse

Function USDPathPage
    !insertmacro MUI_HEADER_TEXT "NVIDIA OpenUSD SDK" "Enter the root folder of your NVIDIA USD installation."

    nsDialogs::Create 1018
    Pop $hWndUsdPathDlg

    ${If} $hWndUsdPathDlg == error
        Abort
    ${EndIf}

    SetShellVarContext current

    ${NSD_CreateLabel} 0 0 100% 10u "NVIDIA USD SDK folder"
    !insertmacro ReadConfigFile "$LOCALAPPDATA\UsdShellExtension\UsdShellExtension.ini" "USD" "SDK_ROOT" ""
    Pop $R0
    ${NSD_CreateText} 0 10u 228u 12u $R0
    Pop $hWndUsdPathEditSdkRoot
    ${NSD_CreateButton} 232u 10u 60u 14u "Browse..."
    Pop $hWndUsdPathButtonBrowse
    ${NSD_OnClick} $hWndUsdPathButtonBrowse USDPathPageBrowseClick

    ${NSD_CreateLabel} 0 30u 100% 10u "Example: D:\usd.py312.windows-x86_64.usdview.release-v25.08"

    nsDialogs::Show
FunctionEnd

Function USDPathPageLeave
    SetShellVarContext current

    ${NSD_GetText} $hWndUsdPathEditSdkRoot $R0

    StrCpy $R1 $R0 1 -1
    ${If} $R1 == "\"
        StrCpy $R0 $R0 -1
    ${EndIf}

    !insertmacro WriteConfigFile "$LOCALAPPDATA\UsdShellExtension\UsdShellExtension.ini" "USD" "SDK_ROOT" $R0
    !insertmacro WriteConfigFile "$LOCALAPPDATA\UsdShellExtension\UsdShellExtension.ini" "USD" "PATH" "$R0\bin\;$R0\lib\"
    !insertmacro WriteConfigFile "$LOCALAPPDATA\UsdShellExtension\UsdShellExtension.ini" "USD" "PYTHONPATH" "$R0\lib\python"
    !insertmacro WriteConfigFile "$LOCALAPPDATA\UsdShellExtension\UsdShellExtension.ini" "USD" "PXR_PLUGINPATH_NAME" ""
    !insertmacro WriteConfigFile "$LOCALAPPDATA\UsdShellExtension\UsdShellExtension.ini" "PYTHON" "PATH" "$R0\python\"

FunctionEnd

Function USDPathPageBrowseClick
    ${NSD_GetText} $hWndUsdPathEditSdkRoot $R0
    nsDialogs::SelectFolderDialog "Select root folder of NVIDIA USD installation" $R0
    Pop $R0

    ${If} $R0 != error
        ${NSD_SetText} $hWndUsdPathEditSdkRoot $R0
    ${EndIf}

FunctionEnd
