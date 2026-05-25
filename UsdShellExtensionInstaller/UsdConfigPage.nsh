;--------------------------------
; UsdConfigPage

!define /ifndef WS_BORDER           0x00800000

!define USDCONFIGCONFIGPATH_STYLE   ${DEFAULT_STYLES}|${WS_BORDER}|${ES_AUTOHSCROLL}
!define USDCONFIGCONFIGPATH_EXSTYLE 0;${WS_EX_STATICEDGE}

Var hWndUsdConfigDlg
Var hWndUsdConfigLabelAll
Var hWndUsdConfigLabelCurrent
Var hWndUsdConfigConfigPathAll
Var hWndUsdConfigConfigPathCurrent
Var hWndUsdConfigButtonShowAll
Var hWndUsdConfigButtonShowCurrent

Function USDConfigPage
    !insertmacro MUI_HEADER_TEXT "USD Shell Extension Configuration File" ""

	nsDialogs::Create 1018
	Pop $hWndUsdConfigDlg

	${If} $hWndUsdConfigDlg == error
		Abort
	${EndIf}

    ${NSD_CreateLabel} 0 0 100% 40u "This file contains the configuration for the USD Shell Extension. \
        The configuration can be modified at any time and the changes will be reflected immediately.$\r$\n$\r$\n\
        The local user configuration file overrides the all users configuration file."

    ${NSD_CreateLabel} 0 50u 100% 10u "All Users (C:\ProgramData)"
    Pop $hWndUsdConfigLabelAll
    nsDialogs::CreateControl "${__NSD_Text_CLASS}" "${USDCONFIGCONFIGPATH_STYLE}" "${USDCONFIGCONFIGPATH_EXSTYLE}" 0 60u 100% 12u "$COMMONAPPDATA\UsdShellExtension\UsdShellExtension.ini"
    Pop $hWndUsdConfigConfigPathAll
    ${NSD_Edit_SetReadOnly} $hWndUsdConfigConfigPathAll 1
    ${NSD_CreateButton} -100u 75u 100u 15u "Show in Explorer"
    Pop $hWndUsdConfigButtonShowAll
    ${NSD_OnClick} $hWndUsdConfigButtonShowAll USDConfigPageShowAllClick

    ${NSD_CreateLabel} 0 95u 100% 10u "Local User (%LOCALAPPDATA%)"
    Pop $hWndUsdConfigLabelCurrent
    nsDialogs::CreateControl "${__NSD_Text_CLASS}" "${USDCONFIGCONFIGPATH_STYLE}" "${USDCONFIGCONFIGPATH_EXSTYLE}" 0 105u 100% 12u "$LOCALAPPDATA\UsdShellExtension\UsdShellExtension.ini"
    Pop $hWndUsdConfigConfigPathCurrent
    ${NSD_Edit_SetReadOnly} $hWndUsdConfigConfigPathCurrent 1
    ${NSD_CreateButton} -100u 120u 100u 15u "Show in Explorer"
    Pop $hWndUsdConfigButtonShowCurrent
    ${NSD_OnClick} $hWndUsdConfigButtonShowCurrent USDConfigPageShowCurrentClick

	nsDialogs::Show
FunctionEnd

Function USDConfigPageLeave

FunctionEnd

Function USDConfigPageShowAllClick
    ExecWait 'explorer.exe /n,/select,"$COMMONAPPDATA\UsdShellExtension\UsdShellExtension.ini"'
FunctionEnd

Function USDConfigPageShowCurrentClick
    ExecWait 'explorer.exe /n,/select,"$LOCALAPPDATA\UsdShellExtension\UsdShellExtension.ini"'
FunctionEnd
