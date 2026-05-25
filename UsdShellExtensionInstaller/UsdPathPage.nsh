;--------------------------------
; UsdPathPage

Var hWndUsdPathDlg
Var hWndUsdPathEditPath
Var hWndUsdPathEditPythonPath
Var hWndUsdPathEditPxrPluginPath
Var hWndUsdPathEditPythonExePath
Var hWndUsdPathButtonBuild

Function USDPathPage
    !insertmacro MUI_HEADER_TEXT "USD Libraries and Tools" "Please set the following USD environment variables."

	nsDialogs::Create 1018
	Pop $hWndUsdPathDlg

	${If} $hWndUsdPathDlg == error
		Abort
	${EndIf}

    SetShellVarContext current

    ${NSD_CreateLabel} 0 0 100% 10u "USD PATH"
    !insertmacro ReadConfigFile "$LOCALAPPDATA\UsdShellExtension\UsdShellExtension.ini" "USD" "PATH" ""
    Pop $R0
    ${NSD_CreateText} 0 10u 100% 12u $R0
    Pop $hWndUsdPathEditPath

    ${NSD_CreateLabel} 0 28u 100% 10u "USD PYTHONPATH"
    !insertmacro ReadConfigFile "$LOCALAPPDATA\UsdShellExtension\UsdShellExtension.ini" "USD" "PYTHONPATH" ""
    Pop $R0
    ${NSD_CreateText} 0 38u 100% 12u $R0
    Pop $hWndUsdPathEditPythonPath

    ${NSD_CreateLabel} 0 56u 100% 10u "PXR_PLUGINPATH_NAME"
    !insertmacro ReadConfigFile "$LOCALAPPDATA\UsdShellExtension\UsdShellExtension.ini" "USD" "PXR_PLUGINPATH_NAME" ""
    Pop $R0
    ${NSD_CreateText} 0 66u 100% 12u $R0
    Pop $hWndUsdPathEditPxrPluginPath

    ${NSD_CreateLabel} 0 84u 100% 10u "Python PATH (path to python.exe directory)"
    !insertmacro ReadConfigFile "$LOCALAPPDATA\UsdShellExtension\UsdShellExtension.ini" "PYTHON" "PATH" ""
    Pop $R0
    ${NSD_CreateText} 0 94u 100% 12u $R0
    Pop $hWndUsdPathEditPythonExePath

    ${NSD_CreateButton} -140u 113u 140u 15u "Set using root USD folder"
    Pop $hWndUsdPathButtonBuild
    ${NSD_OnClick} $hWndUsdPathButtonBuild USDPathPageBuildClick

	nsDialogs::Show
FunctionEnd

Function USDPathPageLeave
    SetShellVarContext current

	${NSD_GetText} $hWndUsdPathEditPath $0
	!insertmacro WriteConfigFile "$LOCALAPPDATA\UsdShellExtension\UsdShellExtension.ini" "USD" "PATH" $0

	${NSD_GetText} $hWndUsdPathEditPythonPath $0
	!insertmacro WriteConfigFile "$LOCALAPPDATA\UsdShellExtension\UsdShellExtension.ini" "USD" "PYTHONPATH" $0

	${NSD_GetText} $hWndUsdPathEditPxrPluginPath $0
	!insertmacro WriteConfigFile "$LOCALAPPDATA\UsdShellExtension\UsdShellExtension.ini" "USD" "PXR_PLUGINPATH_NAME" $0

	${NSD_GetText} $hWndUsdPathEditPythonExePath $0
	!insertmacro WriteConfigFile "$LOCALAPPDATA\UsdShellExtension\UsdShellExtension.ini" "PYTHON" "PATH" $0

FunctionEnd

Function USDPathPageBuildClick

    nsDialogs::SelectFolderDialog "Select root folder of NVIDIA USD installation"
    Pop $R0

	${If} $R0 != error
        ${NSD_SetText} $hWndUsdPathEditPath "$R0\bin\;$R0\lib\"
        ${NSD_SetText} $hWndUsdPathEditPythonPath "$R0\lib\python"
        ${NSD_SetText} $hWndUsdPathEditPxrPluginPath ""
        ${NSD_SetText} $hWndUsdPathEditPythonExePath "$R0\python\"
	${EndIf}

FunctionEnd
