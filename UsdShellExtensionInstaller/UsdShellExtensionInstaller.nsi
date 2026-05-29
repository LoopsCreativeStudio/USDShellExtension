; Copyright (C) 2025 Loops Creative Studio 
;
; Licensed under the Apache License, Version 2.0 (the "License");
; you may not use this file except in compliance with the License.
; You may obtain a copy of the License at
;
;     http://www.apache.org/licenses/LICENSE-2.0
;
; Unless required by applicable law or agreed to in writing, software
; distributed under the License is distributed on an "AS IS" BASIS,
; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
; See the License for the specific language governing permissions and
; limitations under the License.

;--------------------------------
;Includes

!include "MUI2.nsh"
!include "Library.nsh"
!include "logiclib.nsh"
!include "x64.nsh"

!define LIBRARY_X64

!define /ifndef OUT_FILE "setup.exe"

!define /ifndef VER_MAJOR 0
!define /ifndef VER_MINOR 00
!define /ifndef VER_REVISION 00
!define /ifndef VER_BUILD 00
!define /ifndef VER_PRODUCTNAME ""
!define /ifndef VER_COMPANYNAME ""
!define /ifndef VER_COPYRIGHT ""

!define /ifndef VERSION "${VER_MAJOR}.${VER_MINOR}"
!define /ifndef USD_VERSION "Unknown Version"
!define /ifndef PYTHON_VERSION "Unknown Version"
!define /ifndef GITHUB_URL "https://github.com/LoopsCreativeStudio/USDShellExtension"

; The name of the installer
Name "${VER_PRODUCTNAME}"

; The file to write
OutFile "${OUT_FILE}"

; Request application privileges for Windows Vista and higher
RequestExecutionLevel admin

; Build Unicode installer
Unicode True

;SetCompress off
SetCompressor LZMA

; The default installation directory
InstallDir $PROGRAMFILES64\UsdShellExtension

; Registry key to check for directory (so if you install again, it will 
; overwrite the old one automatically)
InstallDirRegKey HKLM "SOFTWARE\UsdShellExtension" "Install_Dir"

!define MUI_BGCOLOR "FFFFFF"
!define MUI_ICON "..\..\..\..\shared\usd.ico"
!define MUI_UNICON "..\..\..\..\shared\usd.ico"
!define MUI_WELCOMEFINISHPAGE_BITMAP "..\..\..\..\shared\installerWelcome.bmp"
!define MUI_WELCOMEFINISHPAGE_BITMAP_STRETCH "NoStretchNoCropNoAlign"
!define MUI_UNWELCOMEFINISHPAGE_BITMAP "..\..\..\..\shared\installerWelcome.bmp"
!define MUI_UNWELCOMEFINISHPAGE_BITMAP_STRETCH "NoStretchNoCropNoAlign"

!define MUI_WELCOMEPAGE_TITLE "${VER_PRODUCTNAME}$\r$\nVersion ${VERSION}"
!define MUI_WELCOMEPAGE_TEXT "Setup will guide you through the installation of $(^NameDA).$\r$\n$\r$\nUSD Version: ${USD_VERSION}$\r$\nPython Version: ${PYTHON_VERSION}$\r$\n$\r$\nIt is recommended that you close all other applications before starting Setup. This will make it possible to update relevant system files without having to reboot your computer.$\r$\n$\r$\n$_CLICK"

;--------------------------------
;Utilities
Var ConfigFilePath
Var COMMONAPPDATA
Var LogFilePath
!include "${__FILEDIR__}\UsdConfigUtils.nsh"
!include "${__FILEDIR__}\RestartManager.nsh"
!include "${__FILEDIR__}\ShellLinkSetRunAs.nsh"
!include "${__FILEDIR__}\CmdLineArgs.nsh"

;--------------------------------
;Interface Settings

!define MUI_ABORTWARNING

;--------------------------------
;Pages
!include "${__FILEDIR__}\UsdPathPage.nsh"
!include "${__FILEDIR__}\UsdConfigPage.nsh"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "LICENSE.txt"
Page custom USDPathPage USDPathPageLeave
Page custom USDConfigPage USDConfigPageLeave
ShowInstDetails show
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_WELCOME
ShowUnInstDetails show
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_UNPAGE_FINISH

;--------------------------------
;Languages

!insertmacro MUI_LANGUAGE "English"

;--------------------------------
;Version information

!ifdef VER_MAJOR & VER_MINOR & VER_REVISION & VER_BUILD
VIProductVersion ${VER_MAJOR}.${VER_MINOR}.${VER_REVISION}.${VER_BUILD}
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "FileDescription" "${VER_PRODUCTNAME} Setup"
VIAddVersionKey "ProductName" "${VER_PRODUCTNAME}"
VIAddVersionKey "LegalCopyright" "${VER_COPYRIGHT}"
VIAddVersionKey "CompanyName" "${VER_COMPANYNAME}"
!endif

SetPluginUnload  alwaysoff

;--------------------------------
Function LogWrite
    Exch $0
    Push $1
    FileOpen $1 $LogFilePath a
    ${If} $1 != ""
        FileWrite $1 "$0$\r$\n"
        FileClose $1
    ${EndIf}
    Pop $1
    Pop $0
FunctionEnd

;--------------------------------
Function un.LogWrite
    Exch $0
    Push $1
    FileOpen $1 $LogFilePath a
    ${If} $1 != ""
        FileWrite $1 "$0$\r$\n"
        FileClose $1
    ${EndIf}
    Pop $1
    Pop $0
FunctionEnd

;--------------------------------
Function .onInit

SetShellVarContext all
StrCpy $COMMONAPPDATA $APPDATA
SetShellVarContext current

StrCpy $LogFilePath "$TEMP\UsdShellExtension_setup.log"
FileOpen $0 $LogFilePath w
${If} $0 != ""
    FileWriteByte $0 255
    FileWriteByte $0 254
    FileWrite $0 "USD Shell Extension Setup Log$\r$\n"
    FileClose $0
${EndIf}

Call ParseCommandLine

FunctionEnd

;--------------------------------
Function un.onInit

SetShellVarContext all
StrCpy $COMMONAPPDATA $APPDATA
SetShellVarContext current

StrCpy $LogFilePath "$TEMP\UsdShellExtension_uninstall.log"
FileOpen $0 $LogFilePath w
${If} $0 != ""
    FileWriteByte $0 255
    FileWriteByte $0 254
    FileWrite $0 "USD Shell Extension Uninstall Log$\r$\n"
    FileClose $0
${EndIf}

FunctionEnd

;--------------------------------
Section "-ShutdownProcesses"

${DisableX64FSRedirection}
SetRegView 64

Push "Shutting down processes"
Call LogWrite

Call ShutdownExplorer
Call ShutdownWindowsSearch
Call ShutdownApplications
Call ShutdownCOMServers

SetDetailsPrint textonly
DetailPrint "Adding Windows Defender exclusion..."
SetDetailsPrint listonly
nsExec::ExecToStack "powershell.exe -NonInteractive -ExecutionPolicy Bypass -Command $\"try { Add-MpPreference -ExclusionPath '$INSTDIR' -ErrorAction Stop } catch {}$\""
    Pop $0
Sleep 2000

!ifdef PYTHONDLL
Push "$INSTDIR\${PYTHONDLL}"
Call WaitForDllRelease
!endif

SectionEnd

;--------------------------------
Section "-UninstallPrevious" 

${DisableX64FSRedirection}
SetRegView 64

ReadRegStr $R0 HKLM \
"Software\Microsoft\Windows\CurrentVersion\Uninstall\UsdShellExtension" \
"UninstallString"
StrCmp $R0 "" done

SetDetailsPrint textonly
DetailPrint "Uninstalling previous installation..."
SetDetailsPrint listonly
DetailPrint "Uninstalling previous installation"

ClearErrors
ExecWait '$R0 /S _?=$INSTDIR' ;Do not copy the uninstaller to a temp file
IfErrors no_remove_uninstaller done
;You can either use Delete /REBOOTOK in the uninstaller or add some code
;here to remove the uninstaller. Use a registry key to check
;whether the user has chosen to uninstall. If you are using an uninstaller
;components page, make sure all sections are uninstalled.
no_remove_uninstaller:

done:

SectionEnd

;--------------------------------

; The stuff to install
Section "Install"

${DisableX64FSRedirection}
SetRegView 64

Push "Installing files"
Call LogWrite

SetDetailsPrint textonly
DetailPrint "Installing files..."
SetDetailsPrint listonly

; All Users config template (C:\ProgramData\UsdShellExtension\)
SetShellVarContext all
${Unless} ${FileExists} "$COMMONAPPDATA\UsdShellExtension\UsdShellExtension.ini"
    SetOutPath "$COMMONAPPDATA\UsdShellExtension"
    File UsdShellExtension.ini
${EndUnless}

; Current User config template (%LOCALAPPDATA%\UsdShellExtension\)
SetShellVarContext current
${Unless} ${FileExists} "$LOCALAPPDATA\UsdShellExtension\UsdShellExtension.ini"
    SetOutPath "$LOCALAPPDATA\UsdShellExtension"
    File UsdShellExtension.ini
${EndUnless}

SetShellVarContext all
SetOutPath "$INSTDIR"
File plugInfo.json
File LICENSE.txt
File NOTICE.txt

SetOutPath "$INSTDIR\usd"
File /r .\usd\*

SetOutPath "$INSTDIR\plugin\usd"
File /r .\plugin\usd\*

SetDetailsPrint textonly
DetailPrint "Installing Python runtime..."
SetDetailsPrint listonly
SetOutPath "$INSTDIR\python"
File /r .\python\*

SetDetailsPrint textonly
DetailPrint "Installing Python packages..."
SetDetailsPrint listonly
SetOutPath "$INSTDIR\pip-packages"
File /r .\pip-packages\*

SetDetailsPrint textonly
DetailPrint "Installing pxr Python bindings..."
SetDetailsPrint listonly
SetOutPath "$INSTDIR\lib\python"
File /r .\lib\python\*

SetOutPath "$INSTDIR\scripts"
File /r .\scripts\*

SetOutPath "$INSTDIR"

!insertmacro InstallLib DLL NOTSHARED REBOOT_NOTPROTECTED tbb.dll "$INSTDIR\tbb.dll" $INSTDIR
!insertmacro InstallLib DLL NOTSHARED REBOOT_NOTPROTECTED tbbmalloc.dll "$INSTDIR\tbbmalloc.dll" $INSTDIR
!insertmacro InstallLib DLL NOTSHARED REBOOT_NOTPROTECTED ${BOOSTDLL} "$INSTDIR\${BOOSTDLL}" $INSTDIR
!if /FileExists "${PYTHONDLL}"
    !insertmacro InstallLib DLL NOTSHARED REBOOT_NOTPROTECTED ${PYTHONDLL} "$INSTDIR\${PYTHONDLL}" $INSTDIR
!endif
!insertmacro InstallLib DLL NOTSHARED REBOOT_NOTPROTECTED UsdPreviewHandler.pyd "$INSTDIR\UsdPreviewHandler.pyd" $INSTDIR

SetDetailsPrint textonly
DetailPrint "Installing USD runtime libraries..."
SetDetailsPrint listonly
File vcruntime140.dll
File tbbmalloc_proxy.dll
File python3.dll
File usd_*.dll

; Image format and MaterialX runtime libraries
File Iex-3_3.dll
File IlmThread-3_3.dll
File Imath-3_1.dll
File jpeg8.dll
File libpng16.dll
File MaterialXCore.dll
File MaterialXFormat.dll
File MaterialXGenGlsl.dll
File MaterialXGenMdl.dll
File MaterialXGenMsl.dll
File MaterialXGenOsl.dll
File MaterialXGenShader.dll
File MaterialXRender.dll
File MaterialXRenderGlsl.dll
File MaterialXRenderHw.dll
File MaterialXRenderOsl.dll
File OpenEXR-3_3.dll
File OpenEXRCore-3_3.dll
File OpenEXRUtil-3_3.dll
File OpenImageIO.dll
File OpenImageIO_Util.dll
File tiff.dll
File turbojpeg.dll
File zlib1.dll

; USD tools and entry points
File sdfdump.exe
File sdffilter.exe
File usdcat.exe
File usdchecker.exe
File usdtree.exe
File usdview
File usdrecord
File usddiff
File usddumpcrate
File usdedit
File usdfixbrokenpixarschemas
File usdGenSchema
File usdgenschemafromsdr
File usdInitSchema
File usdmeasureperformance
File usdresolve
File usdstitch
File usdstitchclips
File usdzip
File usdBakeMaterialX

!insertmacro InstallLib REGEXE NOTSHARED REBOOT_NOTPROTECTED UsdPreviewLocalServer.exe "$INSTDIR\UsdPreviewLocalServer.exe" $INSTDIR
!insertmacro InstallLib REGEXE NOTSHARED REBOOT_NOTPROTECTED UsdPythonToolsLocalServer.exe "$INSTDIR\UsdPythonToolsLocalServer.exe" $INSTDIR
!insertmacro InstallLib REGEXE NOTSHARED REBOOT_NOTPROTECTED UsdSdkToolsLocalServer.exe "$INSTDIR\UsdSdkToolsLocalServer.exe" $INSTDIR
!insertmacro InstallLib DLL NOTSHARED REBOOT_NOTPROTECTED UsdShellExtension.dll "$INSTDIR\UsdShellExtension.dll" $INSTDIR
ExecWait '"$SYSDIR\regsvr32.exe" /s /n /i:"/force" "$INSTDIR\UsdShellExtension.dll"' $R0
${If} $R0 != 0
    DetailPrint "UsdShellExtension.dll registration failed (error $R0)"
    SetErrorLevel 2
    MessageBox MB_OK|MB_ICONEXCLAMATION "UsdShellExtension.dll registration failed (error $R0).$\r$\nThe extension will not appear in Windows Explorer.$\r$\nTry running the installer again as Administrator."
${EndIf}

; Write the installation path into the registry
WriteRegStr HKLM SOFTWARE\UsdShellExtension "Install_Dir" "$INSTDIR"

; Write the uninstall keys for Windows
WriteRegStr   HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\UsdShellExtension" "DisplayName"    "${VER_PRODUCTNAME}"
WriteRegStr   HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\UsdShellExtension" "DisplayVersion" "${VER_MAJOR}.${VER_MINOR}.${VER_REVISION}.${VER_BUILD}"
WriteRegStr   HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\UsdShellExtension" "Publisher"      "${VER_COMPANYNAME}"
WriteRegStr   HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\UsdShellExtension" "DisplayIcon"    "$INSTDIR\UsdShellExtension.dll,0"
WriteRegStr   HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\UsdShellExtension" "UninstallString" '"$INSTDIR\uninstall.exe"'
WriteRegStr   HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\UsdShellExtension" "InstallLocation" "$INSTDIR"
WriteRegStr   HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\UsdShellExtension" "URLInfoAbout"   "${GITHUB_URL}"
WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\UsdShellExtension" "VersionMajor"  ${VER_MAJOR}
WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\UsdShellExtension" "VersionMinor"  ${VER_MINOR}
WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\UsdShellExtension" "NoModify"      1
WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\UsdShellExtension" "NoRepair"      1
WriteUninstaller "$INSTDIR\uninstall.exe"

; Install start menu items
SetShellVarContext current
CreateDirectory '$SMPROGRAMS\USD Shell Extension'
CreateShortCut '$SMPROGRAMS\USD Shell Extension\USD Shell Extension Configuration (Current User).lnk' '"$SYSDIR\NOTEPAD.EXE"' '"$LOCALAPPDATA\UsdShellExtension\USDShellExtension.ini"' '$SYSDIR\imageres.dll' 64

SetShellVarContext all
CreateDirectory '$SMPROGRAMS\USD Shell Extension'
CreateShortCut '$SMPROGRAMS\USD Shell Extension\USD Shell Extension Configuration (All Users).lnk' '"$SYSDIR\NOTEPAD.EXE"' '"$LOCALAPPDATA\UsdShellExtension\USDShellExtension.ini"' '$SYSDIR\imageres.dll' 64
!insertmacro ShellLinkSetRunAs "$SMPROGRAMS\USD Shell Extension\USD Shell Extension Configuration (All Users).lnk"

; Write version info to registry
WriteRegStr HKLM "SOFTWARE\UsdShellExtension" "Version" "${VER_MAJOR}.${VER_MINOR}.${VER_REVISION}.${VER_BUILD}"
WriteRegStr HKLM "SOFTWARE\UsdShellExtension" "USD Version" "${USD_VERSION}"
WriteRegStr HKLM "SOFTWARE\UsdShellExtension" "Python Version" "${PYTHON_VERSION}"
WriteRegStr HKLM "SOFTWARE\UsdShellExtension" "Installer" "${OUT_FILE}"

SectionEnd

;--------------------------------
Section "-RestartProcesses"

${DisableX64FSRedirection}
SetRegView 64

Push "Restarting processes"
Call LogWrite

SetDetailsPrint textonly
DetailPrint "Removing Windows Defender exclusion..."
SetDetailsPrint listonly
nsExec::ExecToStack "powershell.exe -NonInteractive -ExecutionPolicy Bypass -Command $\"try { Remove-MpPreference -ExclusionPath '$INSTDIR' } catch {}$\""
    Pop $0

Call RestartExplorer
Call RestartWindowsSearch
Call RestartApplications

Push "Installation complete"
Call LogWrite
DetailPrint "Install log: $LogFilePath"

SectionEnd

;--------------------------------
Function PatchConfigFileAll

!insertmacro PatchConfigFile "$ConfigFilePath" "USD" "PATH" ""
!insertmacro PatchConfigFile "$ConfigFilePath" "USD" "PYTHONPATH" ""
!insertmacro PatchConfigFile "$ConfigFilePath" "USD" "PXR_PLUGINPATH_NAME" ""
!insertmacro PatchConfigFile "$ConfigFilePath" "USD" "EDITOR" ""

!insertmacro PatchConfigFile "$ConfigFilePath" "RENDERER" "PREVIEW" "GL"
!insertmacro PatchConfigFile "$ConfigFilePath" "RENDERER" "THUMBNAIL" "GL"
!insertmacro PatchConfigFile "$ConfigFilePath" "RENDERER" "VIEW" "GL"

!insertmacro PatchConfigFile "$ConfigFilePath" "PYTHON" "PATH" ""
!insertmacro PatchConfigFile "$ConfigFilePath" "PYTHON" "PYTHONPATH" "$INSTDIR\pip-packages"

FunctionEnd

;--------------------------------
Function ForceConfigFileAll

${If} $CmdLineUsdPath != ""
    !insertmacro WriteConfigFile "$ConfigFilePath" "USD" "PATH" $CmdLineUsdPath
${EndIf}

${If} $CmdLineUsdPythonPath != ""
    !insertmacro WriteConfigFile "$ConfigFilePath" "USD" "PYTHONPATH" $CmdLineUsdPythonPath
${EndIf}

${If} $CmdLineUsdPxrPluginPathName != ""
    !insertmacro WriteConfigFile "$ConfigFilePath" "USD" "PXR_PLUGINPATH_NAME" $CmdLineUsdPxrPluginPathName
${EndIf}

${If} $CmdLinePythonPath != ""
    !insertmacro WriteConfigFile "$ConfigFilePath" "PYTHON" "PATH" $CmdLinePythonPath
${EndIf}

${If} $CmdLinePythonPythonPath != ""
    !insertmacro WriteConfigFile "$ConfigFilePath" "PYTHON" "PYTHONPATH" $CmdLinePythonPythonPath
${EndIf}

${If} $CmdLineRendererPreview != ""
    !insertmacro WriteConfigFile "$ConfigFilePath" "RENDERER" "PREVIEW" $CmdLineRendererPreview
${EndIf}

${If} $CmdLineRendererThumbnail != ""
    !insertmacro WriteConfigFile "$ConfigFilePath" "RENDERER" "THUMBNAIL" $CmdLineRendererThumbnail
${EndIf}

${If} $CmdLineRendererView != ""
    !insertmacro WriteConfigFile "$ConfigFilePath" "RENDERER" "VIEW" $CmdLineRendererView
${EndIf}

FunctionEnd

;--------------------------------
Section "-UpdateConfigFile" 

${DisableX64FSRedirection}
SetRegView 64

; In order to support updates to the config file and allow for us 
; to support going back to older versions of the shell extension, 
; we will "patch" the existing config file using GetPrivateProfileStringW 
; to determine if a value is already set and SetPrivateProfileStringW 
; to enter a blank / default value if no value was set.

SetDetailsPrint textonly
DetailPrint "Updating config file..."
SetDetailsPrint listonly

SetShellVarContext current
StrCpy $ConfigFilePath "$LOCALAPPDATA\UsdShellExtension\UsdShellExtension.ini"
Call PatchConfigFileAll
; Force-write install-dir paths: these are not user customisations and must
; always match the current $INSTDIR after every install or update.
!insertmacro WriteConfigFile "$ConfigFilePath" "USD" "PATH" "$INSTDIR;$INSTDIR\scripts"
!insertmacro WriteConfigFile "$ConfigFilePath" "USD" "PYTHONPATH" "$INSTDIR\lib\python"
!insertmacro WriteConfigFile "$ConfigFilePath" "USD" "PXR_PLUGINPATH_NAME" "$INSTDIR\usd;$INSTDIR\plugin\usd"
!insertmacro WriteConfigFile "$ConfigFilePath" "PYTHON" "PATH" "$INSTDIR\python\"
; Repair [PYTHON] PYTHONPATH if a previous installer wrote an empty value.
ReadINIStr $R0 "$ConfigFilePath" "PYTHON" "PYTHONPATH"
${If} $R0 == ""
    WriteINIStr "$ConfigFilePath" "PYTHON" "PYTHONPATH" "$INSTDIR\pip-packages"
${EndIf}

SetShellVarContext all
StrCpy $ConfigFilePath "$COMMONAPPDATA\UsdShellExtension\UsdShellExtension.ini"
Call PatchConfigFileAll
!insertmacro WriteConfigFile "$ConfigFilePath" "USD" "PATH" "$INSTDIR;$INSTDIR\scripts"
!insertmacro WriteConfigFile "$ConfigFilePath" "USD" "PYTHONPATH" "$INSTDIR\lib\python"
!insertmacro WriteConfigFile "$ConfigFilePath" "USD" "PXR_PLUGINPATH_NAME" "$INSTDIR\usd;$INSTDIR\plugin\usd"
!insertmacro WriteConfigFile "$ConfigFilePath" "PYTHON" "PATH" "$INSTDIR\python\"
ReadINIStr $R0 "$ConfigFilePath" "PYTHON" "PYTHONPATH"
${If} $R0 == ""
    WriteINIStr "$ConfigFilePath" "PYTHON" "PYTHONPATH" "$INSTDIR\pip-packages"
${EndIf}

; Force command-line settings into the current user config (highest priority).
SetShellVarContext current
StrCpy $ConfigFilePath "$LOCALAPPDATA\UsdShellExtension\UsdShellExtension.ini"
Call ForceConfigFileAll

SectionEnd

;--------------------------------

; Uninstaller

;--------------------------------
Section "-Un.ShutdownProcesses"

${DisableX64FSRedirection}
SetRegView 64

Push "Shutting down processes"
Call un.LogWrite

; Add Defender exclusion early so it releases DLL handles before deletion.
SetDetailsPrint textonly
DetailPrint "Adding Windows Defender exclusion..."
SetDetailsPrint listonly
nsExec::ExecToStack "powershell.exe -NonInteractive -ExecutionPolicy Bypass -Command $\"try { Add-MpPreference -ExclusionPath '$INSTDIR' -ErrorAction Stop } catch {}$\""
    Pop $0
Sleep 2000

Call un.ShutdownExplorer
Call un.ShutdownWindowsSearch
Call un.ShutdownApplications
Call un.ShutdownCOMServers

!ifdef PYTHONDLL
Push "$INSTDIR\${PYTHONDLL}"
Call un.WaitForDllRelease
!endif

SectionEnd

;--------------------------------
Section "Uninstall"

${DisableX64FSRedirection}
SetRegView 64
SetShellVarContext all

Push "Uninstalling files"
Call un.LogWrite

SetDetailsPrint textonly
DetailPrint "Uninstalling files..."
SetDetailsPrint listonly

ExecWait '"$SYSDIR\regsvr32.exe" /s /u "$INSTDIR\UsdShellExtension.dll"'
!insertmacro UnInstallLib DLL NOTSHARED REBOOT_NOTPROTECTED "$INSTDIR\UsdShellExtension.dll"
!insertmacro UnInstallLib REGEXE NOTSHARED REBOOT_NOTPROTECTED "$INSTDIR\UsdPreviewLocalServer.exe"
!insertmacro UnInstallLib REGEXE NOTSHARED REBOOT_NOTPROTECTED "$INSTDIR\UsdPythonToolsLocalServer.exe"
!insertmacro UnInstallLib REGEXE NOTSHARED REBOOT_NOTPROTECTED "$INSTDIR\UsdSdkToolsLocalServer.exe"
!insertmacro UnInstallLib DLL NOTSHARED REBOOT_NOTPROTECTED "$INSTDIR\tbb.dll"
!insertmacro UnInstallLib DLL NOTSHARED REBOOT_NOTPROTECTED "$INSTDIR\tbbmalloc.dll"
!insertmacro UnInstallLib DLL NOTSHARED REBOOT_NOTPROTECTED "$INSTDIR\${BOOSTDLL}"
!if /FileExists "${PYTHONDLL}"
    !insertmacro UnInstallLib DLL NOTSHARED REBOOT_NOTPROTECTED "$INSTDIR\${PYTHONDLL}"
!endif
!insertmacro UnInstallLib DLL NOTSHARED REBOOT_NOTPROTECTED "$INSTDIR\UsdPreviewHandler.pyd"
Delete /REBOOTOK "$INSTDIR\vcruntime140.dll"
Delete /REBOOTOK "$INSTDIR\tbbmalloc_proxy.dll"
Delete /REBOOTOK "$INSTDIR\python3.dll"
Delete /REBOOTOK "$INSTDIR\usd_*.dll"

; Remove registry keys
DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\UsdShellExtension"
DeleteRegKey HKLM SOFTWARE\UsdShellExtension

; Remove file type associations; extension keys are exclusively ours so delete
; the whole key, but only if the default value still points to our ProgID.
ReadRegStr $R0 HKCR ".usd" ""
${If} $R0 == "OpenUSD.USD"
    DeleteRegKey HKCR ".usd"
${EndIf}
ReadRegStr $R0 HKCR ".usda" ""
${If} $R0 == "OpenUSD.USDA"
    DeleteRegKey HKCR ".usda"
${EndIf}
ReadRegStr $R0 HKCR ".usdc" ""
${If} $R0 == "OpenUSD.USDC"
    DeleteRegKey HKCR ".usdc"
${EndIf}
ReadRegStr $R0 HKCR ".usdz" ""
${If} $R0 == "OpenUSD.USDZ"
    DeleteRegKey HKCR ".usdz"
${EndIf}

; Remove ProgID keys; entirely ours, safe to delete unconditionally.
DeleteRegKey HKCR "OpenUSD.USD"
DeleteRegKey HKCR "OpenUSD.USDA"
DeleteRegKey HKCR "OpenUSD.USDC"
DeleteRegKey HKCR "OpenUSD.USDZ"

; Remove property descriptions registered by PSRegisterPropertySchema.
; Delete only the PropertyDescriptions sub-key; leave the parent only
; if another app has populated it.
DeleteRegKey HKCR "SystemFileAssociations\.usd\PropertyDescriptions"
DeleteRegKey /ifempty HKCR "SystemFileAssociations\.usd"
DeleteRegKey HKCR "SystemFileAssociations\.usda\PropertyDescriptions"
DeleteRegKey /ifempty HKCR "SystemFileAssociations\.usda"
DeleteRegKey HKCR "SystemFileAssociations\.usdc\PropertyDescriptions"
DeleteRegKey /ifempty HKCR "SystemFileAssociations\.usdc"
DeleteRegKey HKCR "SystemFileAssociations\.usdz\PropertyDescriptions"
DeleteRegKey /ifempty HKCR "SystemFileAssociations\.usdz"

; Remove files and uninstaller
;Delete /REBOOTOK "$LOCALAPPDATA\UsdShellExtension\UsdShellExtension.ini"
Delete /REBOOTOK "$INSTDIR\plugInfo.json"
Delete /REBOOTOK "$INSTDIR\LICENSE.txt"
Delete /REBOOTOK "$INSTDIR\NOTICE.txt"
RMDir /r /REBOOTOK "$INSTDIR\usd"
RMDir /r /REBOOTOK "$INSTDIR\plugin\usd"
RMDir /REBOOTOK "$INSTDIR\plugin"
RMDir /r /REBOOTOK "$INSTDIR\python"
RMDir /r /REBOOTOK "$INSTDIR\pip-packages"
RMDir /r /REBOOTOK "$INSTDIR\lib"
RMDir /r /REBOOTOK "$INSTDIR\scripts"
Delete /REBOOTOK "$INSTDIR\UsdPropertyKeys.propdesc"

Delete /REBOOTOK "$INSTDIR\uninstall.exe"

Push "Uninstall complete"
Call un.LogWrite

; Remove directories
RMDir "$INSTDIR"

; Remove start menu items
SetShellVarContext current
Delete  '$SMPROGRAMS\USD Shell Extension\USD Shell Extension Configuration (Current User).lnk'
SetShellVarContext all
Delete  '$SMPROGRAMS\USD Shell Extension\USD Shell Extension Configuration (All Users).lnk'
RMDir '$SMPROGRAMS\USD Shell Extension'

SectionEnd

;--------------------------------
Section "-Un.RestartProcesses"

${DisableX64FSRedirection}
SetRegView 64

Push "Restarting processes"
Call un.LogWrite

Call un.RestartExplorer
Call un.RestartWindowsSearch
Call un.RestartApplications

; Remove the Defender exclusion added during shutdown.
SetDetailsPrint textonly
DetailPrint "Removing Windows Defender exclusion..."
SetDetailsPrint listonly
nsExec::ExecToStack "powershell.exe -NonInteractive -ExecutionPolicy Bypass -Command $\"try { Remove-MpPreference -ExclusionPath '$INSTDIR' } catch {}$\""
    Pop $0

SectionEnd
