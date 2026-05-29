;--------------------------------
!define MAX_PATH 260
!define CCH_RM_SESSION_KEY 33
!define RmForceShutdown 0x1
!define RmShutdownOnlyRegistered 0x10

;--------------------------------
Var RmExplorerSession
Var RmApplicationSession
Var RmWindowsSearchSession

;--------------------------------
!macro ShutdownExplorer UN
Function ${UN}ShutdownExplorer

SetDetailsPrint textonly
DetailPrint "Shutting down Windows Explorer..."
SetDetailsPrint listonly

System::StrAlloc ${CCH_RM_SESSION_KEY}
Pop $0
System::Call 'Rstrtmgr::RmStartSession(*i .R1, i 0, p $0) i.R0'
System::Free $0
StrCpy $RmExplorerSession $R1

StrCpy $0 "$WINDIR\explorer.exe"
System::Call '*(w r0)p.R1 ?2'
System::Call 'Rstrtmgr::RmRegisterResources(i $RmExplorerSession, i 1, p R1, i 0, p n, i 0, p n) i.R0'

; Use taskkill /F (non-blocking from NSIS point of view via ExecToStack, but
; /F terminates immediately so the call returns in < 1 s), then poll so the
; UI can show elapsed time instead of appearing frozen.
FindWindow $R0 "Shell_TrayWnd"
${If} $R0 != 0
    DetailPrint "Stopping Windows Explorer"
    nsExec::ExecToStack '"$SYSDIR\taskkill.exe" /F /IM explorer.exe'
    Pop $0

    ; /F is immediate; check right away first to avoid an unnecessary 1 s sleep.
    FindWindow $R0 "Shell_TrayWnd"
    ${If} $R0 == 0
        DetailPrint "Windows Explorer stopped"
    ${Else}
        StrCpy $1 0
        ${Do}
            Sleep 1000
            IntOp $1 $1 + 1
            FindWindow $R0 "Shell_TrayWnd"
            ${If} $R0 == 0
                SetDetailsPrint listonly
                DetailPrint "Windows Explorer stopped after $1s"
                ${ExitDo}
            ${EndIf}
            SetDetailsPrint textonly
            DetailPrint "Stopping Windows Explorer... $1s"
            SetDetailsPrint listonly
            ${If} $1 >= 15
                DetailPrint "Warning: Windows Explorer did not stop within 15s"
                ${ExitDo}
            ${EndIf}
        ${Loop}
    ${EndIf}
${Else}
    DetailPrint "Windows Explorer already stopped"
${EndIf}

FunctionEnd
!macroend
!insertmacro ShutdownExplorer ""
!insertmacro ShutdownExplorer "un."


;--------------------------------
!macro RestartExplorer UN
Function ${UN}RestartExplorer

SetDetailsPrint textonly
DetailPrint "Restarting Windows Explorer..."
SetDetailsPrint listonly

System::Call 'Rstrtmgr::RmRestart(i $RmExplorerSession, i 0, p n) i.R0'
System::Call 'Rstrtmgr::RmEndSession(i $RmExplorerSession) i.R0'

; Wait up to 6s for Shell_TrayWnd to appear
StrCpy $1 0
${Do}
    Sleep 1000
    IntOp $1 $1 + 1
    FindWindow $R0 "Shell_TrayWnd"
    ${If} $R0 != 0
        DetailPrint "Windows Explorer restarted after $1s"
        ${ExitDo}
    ${EndIf}
    SetDetailsPrint textonly
    DetailPrint "Waiting for Windows Explorer... $1s"
    SetDetailsPrint listonly
    ${If} $1 >= 6
        ${ExitDo}
    ${EndIf}
${Loop}

FindWindow $R0 "Shell_TrayWnd"
${If} $R0 == 0
    DetailPrint "Forcing Explorer restart..."
    nsExec::ExecToStack '"$SYSDIR\taskkill.exe" /F /IM explorer.exe'
    Pop $0
    Sleep 1000
    Exec '$WINDIR\explorer.exe'
    ; Wait up to 10s for the forced Explorer to appear
    StrCpy $2 0
    ${Do}
        Sleep 1000
        IntOp $2 $2 + 1
        FindWindow $R0 "Shell_TrayWnd"
        ${If} $R0 != 0
            DetailPrint "Windows Explorer restarted after $2s"
            ${ExitDo}
        ${EndIf}
        SetDetailsPrint textonly
        DetailPrint "Waiting for Windows Explorer... $2s"
        SetDetailsPrint listonly
        ${If} $2 >= 10
            DetailPrint "Warning: Windows Explorer did not restart within timeout"
            ${ExitDo}
        ${EndIf}
    ${Loop}
${EndIf}

FunctionEnd
!macroend
!insertmacro RestartExplorer ""
!insertmacro RestartExplorer "un."


;--------------------------------
!macro ShutdownWindowsSearch UN 
Function ${UN}ShutdownWindowsSearch 

SetDetailsPrint textonly
DetailPrint "Shutting down Windows Search..."
SetDetailsPrint listonly

System::StrAlloc ${CCH_RM_SESSION_KEY}
Pop $0
System::Call 'Rstrtmgr::RmStartSession(*i .R1, i 0, p $0) i.R0'
System::Free $0

StrCpy $RmWindowsSearchSession $R1

DetailPrint "Shutting down Windows Search"

StrCpy $0 "wsearch"
System::Call '*(w r0)p.R1 ?2'
System::Call 'Rstrtmgr::RmRegisterResources(i $RmWindowsSearchSession, i 0, p n, i 0, p n, i 1, p R1) i.R0'

System::Call 'Rstrtmgr::RmShutdown(i $RmWindowsSearchSession, i 0, p n) i.R0'

FunctionEnd
!macroend
!insertmacro ShutdownWindowsSearch "" 
!insertmacro ShutdownWindowsSearch "un."

;--------------------------------
!macro RestartWindowsSearch UN 
Function ${UN}RestartWindowsSearch 

SetDetailsPrint textonly
DetailPrint "Restarting Windows Search..."
SetDetailsPrint listonly

DetailPrint "Restarting Windows Search"

System::Call 'Rstrtmgr::RmRestart(i $RmWindowsSearchSession, i 0, p n) i.R0'

System::Call 'Rstrtmgr::RmEndSession(i $RmWindowsSearchSession) i.R0'

FunctionEnd
!macroend
!insertmacro RestartWindowsSearch "" 
!insertmacro RestartWindowsSearch "un."


;--------------------------------
!macro ShutdownApplications UN 
Function ${UN}ShutdownApplications 

SetDetailsPrint textonly
DetailPrint "Shutting down applications..."
SetDetailsPrint listonly

System::StrAlloc ${CCH_RM_SESSION_KEY}
Pop $0
System::Call 'Rstrtmgr::RmStartSession(*i .R1, i 0, p $0) i.R0'
System::Free $0

StrCpy $RmApplicationSession $R1

StrCpy $0 "$INSTDIR\UsdShellExtension.dll"
StrCpy $1 "$INSTDIR\tbb.dll"
StrCpy $2 "$INSTDIR\tbbmalloc.dll"
StrCpy $3 "$INSTDIR\${BOOSTDLL}"
StrCpy $4 "$INSTDIR\${PYTHONDLL}"
StrCpy $5 "$INSTDIR\UsdPreviewHandler.pyd"
System::Call '*(w r0, w r1, w r2, w r3, w r4, w r5)p.R1 ?2'
System::Call 'Rstrtmgr::RmRegisterResources(i $RmApplicationSession, i 6, p R1, i 0, p n, i 1, p R2) i.R0'

DetailPrint "Shutting down applications using the USD Shell Extension"

; only shutdown applications that can restart
System::Call 'Rstrtmgr::RmShutdown(i $RmApplicationSession, i ${RmShutdownOnlyRegistered}, p n) i.R0'

FunctionEnd
!macroend
!insertmacro ShutdownApplications "" 
!insertmacro ShutdownApplications "un."

;--------------------------------
!macro RestartApplications UN 
Function ${UN}RestartApplications 

SetDetailsPrint textonly
DetailPrint "Restarting Applications..."
SetDetailsPrint listonly

DetailPrint "Restarting applications that were using the Shell Extension"

System::Call 'Rstrtmgr::RmRestart(i $RmApplicationSession, i 0, p n) i.R0'

System::Call 'Rstrtmgr::RmEndSession(i $RmApplicationSession) i.R0'

FunctionEnd
!macroend
!insertmacro RestartApplications "" 
!insertmacro RestartApplications "un."


;--------------------------------
!macro ShutdownCOMServers UN 
Function ${UN}ShutdownCOMServers 

SetDetailsPrint textonly
DetailPrint "Shutting down COM servers..."
SetDetailsPrint listonly

System::StrAlloc ${CCH_RM_SESSION_KEY}
Pop $0
System::Call 'Rstrtmgr::RmStartSession(*i .R9, i 0, p $0) i.R0'
System::Free $0

StrCpy $0 "$INSTDIR\UsdPreviewLocalServer.exe"
StrCpy $1 "$INSTDIR\UsdPythonToolsLocalServer.exe"
StrCpy $2 "$INSTDIR\UsdSdkToolsLocalServer.exe"

System::Call '*(w r0, w r1, w r2)p.R1 ?2'
System::Call 'Rstrtmgr::RmRegisterResources(i R9, i 3, p R1, i 0, p n, i 0, p n) i.R0'

System::Call 'Rstrtmgr::RmShutdown(i R9, i ${RmForceShutdown}, p n) i.R0'

System::Call 'Rstrtmgr::RmEndSession(i R9) i.R0'

FunctionEnd
!macroend
!insertmacro ShutdownCOMServers ""
!insertmacro ShutdownCOMServers "un."


;--------------------------------
; Waits up to 30s for a file to be fully released by Windows Defender and other scanners.
; Push the full file path on the stack before calling.
!macro WaitForDllRelease UN
Function ${UN}WaitForDllRelease

Pop $0

SetDetailsPrint textonly
DetailPrint "Waiting for file locks to be released..."
SetDetailsPrint listonly

${If} ${FileExists} $0
    StrCpy $1 0
    ${Do}
        ; Exclusive open with no sharing to detect any remaining handle.
        System::Call 'kernel32::CreateFileW(w r0, i 0xC0000000, i 0, i 0, i 3, i 0x80, i 0) i.R0'
        ${If} $R0 > 0
            System::Call 'kernel32::CloseHandle(i R0)'
            ${If} $1 > 0
                DetailPrint "File lock released after $1s"
            ${EndIf}
            ${ExitDo}
        ${EndIf}
        ${If} $1 == 0
            DetailPrint "$0 is locked, waiting..."
        ${EndIf}
        ${If} $1 >= 30
            DetailPrint "Warning: $0 still locked after 30s"
            ${ExitDo}
        ${EndIf}
        IntOp $1 $1 + 1
        Sleep 1000
    ${Loop}
${EndIf}

FunctionEnd
!macroend
!insertmacro WaitForDllRelease ""
!insertmacro WaitForDllRelease "un."
