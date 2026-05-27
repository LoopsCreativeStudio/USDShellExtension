// USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
// Licensed under the MIT License. See LICENSE.txt for details.

#include "stdafx.h"
#include "UsdPythonToolsImpl.h"
#include "Module.h"
#include "shared\environment.h"
#include "shared\EventViewerLog.h"
#include "UsdPythonToolsLocalServer_h.h"

#include <vector>


HRESULT CUsdPythonToolsImpl::FinalConstruct()
{
	SetupPythonEnvironment( g_hInstance );

	return __super::FinalConstruct();
}

void CUsdPythonToolsImpl::FinalRelease()
{
	__super::FinalRelease();
}

static std::wstring FindRelativeFile(LPCWSTR sToolFileName)
{
	const std::vector<CString> &PathList = GetUsdPathList();

	for ( const CString &sDir : PathList )
	{
		TCHAR sFilePath[512];
		_tcscpy_s( sFilePath, sDir.GetString() );

		::PathCchAppend( sFilePath, ARRAYSIZE( sFilePath ), sToolFileName );

		DWORD nAttribs = ::GetFileAttributes( sFilePath );
		if ( (nAttribs != INVALID_FILE_ATTRIBUTES) && !(nAttribs & FILE_ATTRIBUTE_DIRECTORY) )
			return sFilePath;
	}

	return L"";
}



static std::wstring GetPythonExePath();

STDMETHODIMP CUsdPythonToolsImpl::Record( IN BSTR usdStagePath, IN int imageWidth, IN BSTR renderer, OUT BSTR *outputImagePath )
{
	DEBUG_RECORD_ENTRY();

	// --- Unique temp PNG output path ---
	wchar_t sTempPath[MAX_PATH];
	::GetTempPathW( ARRAYSIZE( sTempPath ), sTempPath );
	wchar_t sTempFileName[MAX_PATH];

	std::vector<CStringW> tempFileList;
	for ( ;; )
	{
		::GetTempFileNameW( sTempPath, L"usd", 0, sTempFileName );
		tempFileList.push_back( sTempFileName );
		::PathCchRenameExtension( sTempFileName, ARRAYSIZE( sTempFileName ), L"png" );
		if ( ::GetFileAttributesW( sTempFileName ) == INVALID_FILE_ATTRIBUTES )
			break;
	}
	for ( const CStringW &str : tempFileList )
		::DeleteFileW( str );

	// --- Extract UsdThumbnail.py to %TEMP% ---
	// UsdImagingGLEngine requires WGL context initialization driven by a Win32
	// message loop. Running it via PyRun_String on the COM thread blocks the loop
	// and causes "No renderer plugins found!". A subprocess gets its own process
	// with full message-pump capability (same fix as View/usdview).
	wchar_t sScriptPath[MAX_PATH] = {};
	wcscpy_s( sScriptPath, sTempPath );
	::PathCchAppend( sScriptPath, ARRAYSIZE( sScriptPath ), L"UsdThumbnailScript.py" );

	{
		HRSRC hRes = ::FindResource( g_hInstance, MAKEINTRESOURCE( IDR_PYTHON_THUMBNAIL ), _T("PYTHON") );
		if ( hRes == nullptr )
		{
			LogEventMessage( PYTHONTOOLS_CATEGORY, L"Record: IDR_PYTHON_THUMBNAIL resource not found", LogEventType::Error );
			return E_FAIL;
		}
		HGLOBAL hData = ::LoadResource( g_hInstance, hRes );
		void*   pData = ::LockResource( hData );
		DWORD   nSize = ::SizeofResource( g_hInstance, hRes );
		HANDLE  hFile = ::CreateFileW( sScriptPath, GENERIC_WRITE, 0, nullptr,
		                               CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr );
		if ( hFile == INVALID_HANDLE_VALUE )
		{
			LogEventMessage( PYTHONTOOLS_CATEGORY, L"Record: failed to write UsdThumbnailScript.py", LogEventType::Error );
			return E_FAIL;
		}
		DWORD nWritten = 0;
		::WriteFile( hFile, pData, nSize, &nWritten, nullptr );
		::CloseHandle( hFile );
	}

	// --- Build command line ---
	std::wstring sPythonExe = GetPythonExePath();

	CStringW sImageWidth;
	sImageWidth.Format( L"%d", imageWidth );

	CStringW sCommandLine;
	sCommandLine.Format( L"\"%ls\" \"%ls\" --imageWidth %ls",
	                     sPythonExe.c_str(), sScriptPath, (LPCWSTR)sImageWidth );

	if ( renderer != nullptr && renderer[0] != L'\0' )
		sCommandLine.AppendFormat( L" --renderer %ls", renderer );

	sCommandLine.AppendFormat( L" \"%ls\" \"%ls\"", (LPCWSTR)usdStagePath, sTempFileName );

	// --- Launch subprocess ---
	wchar_t sLogPath[MAX_PATH] = {};
	wcscpy_s( sLogPath, sTempPath );
	::PathCchAppend( sLogPath, ARRAYSIZE( sLogPath ), L"UsdThumbnail.log" );

	SECURITY_ATTRIBUTES sa = {};
	sa.nLength        = sizeof( sa );
	sa.bInheritHandle = TRUE;

	HANDLE hLog = ::CreateFileW( sLogPath, GENERIC_WRITE, FILE_SHARE_READ, &sa,
	                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr );

	STARTUPINFOW si = {};
	si.cb = sizeof( si );
	BOOL bInheritHandles = FALSE;

	if ( hLog != INVALID_HANDLE_VALUE )
	{
		si.dwFlags    = STARTF_USESTDHANDLES;
		si.hStdInput  = NULL;
		si.hStdOutput = hLog;
		si.hStdError  = hLog;
		bInheritHandles = TRUE;
	}

	PROCESS_INFORMATION pi = {};

	if ( !::CreateProcessW( nullptr, sCommandLine.GetBuffer(), nullptr, nullptr,
	                        bInheritHandles, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi ) )
	{
		DWORD err = ::GetLastError();
		CString sMsg;
		sMsg.Format( _T("Record: CreateProcess failed (0x%08X): %ls"), err, (LPCWSTR)sCommandLine );
		LogEventMessage( PYTHONTOOLS_CATEGORY, sMsg, LogEventType::Error );
		if ( hLog != INVALID_HANDLE_VALUE )
			::CloseHandle( hLog );
		return HRESULT_FROM_WIN32( err );
	}
	::CloseHandle( pi.hThread );

	constexpr DWORD kTimeoutMs = 60000;
	DWORD waitResult = ::WaitForSingleObject( pi.hProcess, kTimeoutMs );

	DWORD exitCode = 0;
	::GetExitCodeProcess( pi.hProcess, &exitCode );
	::CloseHandle( pi.hProcess );

	if ( hLog != INVALID_HANDLE_VALUE )
		::CloseHandle( hLog );

	if ( waitResult == WAIT_TIMEOUT )
	{
		LogEventMessage( PYTHONTOOLS_CATEGORY, L"Record: thumbnail process timed out after 60s", LogEventType::Error );
		return E_FAIL;
	}

	if ( exitCode != 0 )
	{
		CStringA sLogContent;
		HANDLE hLogRead = ::CreateFileW( sLogPath, GENERIC_READ, FILE_SHARE_READ, nullptr,
		                                  OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr );
		if ( hLogRead != INVALID_HANDLE_VALUE )
		{
			DWORD nLogSize = ::GetFileSize( hLogRead, nullptr );
			if ( nLogSize > 0 && nLogSize != INVALID_FILE_SIZE )
			{
				LPSTR pBuf = sLogContent.GetBufferSetLength( static_cast<int>(nLogSize) );
				DWORD nRead = 0;
				::ReadFile( hLogRead, pBuf, nLogSize, &nRead, nullptr );
				sLogContent.ReleaseBuffer( static_cast<int>(nRead) );
			}
			::CloseHandle( hLogRead );
		}

		CString sErrorMsg;
		if ( sLogContent.IsEmpty() )
			sErrorMsg.Format( _T("Record: thumbnail failed for %ls (exit %lu)"), usdStagePath, exitCode );
		else
			sErrorMsg.Format( _T("Record: thumbnail failed for %ls (exit %lu)\n\n%hs"),
			                  usdStagePath, exitCode, (LPCSTR)sLogContent );
		LogEventMessage( PYTHONTOOLS_CATEGORY, sErrorMsg.GetString(), LogEventType::Error );
		return E_FAIL;
	}

	CComBSTR bstrOutputFile( sTempFileName );
	*outputImagePath = bstrOutputFile.Detach();

	return S_OK;
}

STDMETHODIMP CUsdPythonToolsImpl::View( IN BSTR usdStagePath, IN BSTR renderer )
{
	DEBUG_RECORD_ENTRY();

	// usdview requires a fresh process with a proper Qt/OpenGL context.
	// Running it via PyRun_String inside the COM server's embedded interpreter
	// causes WGL initialization to fail (black viewport). We use CreateProcess
	// instead, which gives usdview the same environment as a direct subprocess
	// launch — identical to running it from PowerShell.

	std::wstring sUsdViewPath = FindRelativeFile( L"usdview" );
	if ( sUsdViewPath.empty() )
	{
		LogEventMessage( PYTHONTOOLS_CATEGORY, L"View: usdview not found in USD PATH", LogEventType::Error );
		return E_FAIL;
	}

	// Locate python.exe from [PYTHON] PATH in the INI config.
	std::vector<CStringW> configFiles = BuildConfigFileList( g_hInstance );
	CStringW sPythonDir;
	GetPrivateProfileStringAndExpandEnvironmentStrings( L"PYTHON", L"PATH", L"", sPythonDir, configFiles );

	wchar_t sPythonExe[MAX_PATH];
	if ( !sPythonDir.IsEmpty() )
	{
		wcscpy_s( sPythonExe, sPythonDir.GetString() );
		::PathCchAppend( sPythonExe, ARRAYSIZE( sPythonExe ), L"python.exe" );
	}
	else
	{
		wcscpy_s( sPythonExe, L"python.exe" );
	}

	// Write UsdView.py wrapper to a known temp-dir file so we can patch
	// Tf.Error.commentary before usdview starts (CP1252/UTF-8 mismatch fix).
	wchar_t sTempDir[MAX_PATH] = {};
	::GetTempPathW( ARRAYSIZE( sTempDir ), sTempDir );

	wchar_t sWrapperPath[MAX_PATH] = {};
	{
		wcscpy_s( sWrapperPath, sTempDir );
		::PathCchAppend( sWrapperPath, ARRAYSIZE( sWrapperPath ), L"UsdViewWrapper.py" );

		HRSRC hRes = ::FindResource( g_hInstance, MAKEINTRESOURCE( IDR_PYTHON_VIEW ), _T("PYTHON") );
		if ( hRes )
		{
			HGLOBAL hData  = ::LoadResource( g_hInstance, hRes );
			void*   pData  = ::LockResource( hData );
			DWORD   nSize  = ::SizeofResource( g_hInstance, hRes );
			HANDLE  hFile  = ::CreateFileW( sWrapperPath, GENERIC_WRITE, 0, nullptr,
			                                CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr );
			if ( hFile != INVALID_HANDLE_VALUE )
			{
				DWORD nWritten = 0;
				::WriteFile( hFile, pData, nSize, &nWritten, nullptr );
				::CloseHandle( hFile );
			}
		}
	}

	// Build: "python.exe" "wrapper.py" "usdview" [--renderer R] "file.usd"
	CStringW sCommandLine;
	if ( sWrapperPath[0] != L'\0' )
		sCommandLine.Format( L"\"%ls\" \"%ls\" \"%ls\"", sPythonExe, sWrapperPath, sUsdViewPath.c_str() );
	else
		sCommandLine.Format( L"\"%ls\" \"%ls\"", sPythonExe, sUsdViewPath.c_str() );

	if ( renderer && renderer[0] != L'\0' )
		sCommandLine.AppendFormat( L" --renderer %ls", renderer );

	sCommandLine.AppendFormat( L" \"%ls\"", usdStagePath );

	// Redirect stdout/stderr to a log file — captures Python errors without
	// creating a visible console window.  Log path: %TEMP%\UsdViewWrapper.log
	wchar_t sLogPath[MAX_PATH] = {};
	wcscpy_s( sLogPath, sTempDir );
	::PathCchAppend( sLogPath, ARRAYSIZE( sLogPath ), L"UsdViewWrapper.log" );

	SECURITY_ATTRIBUTES sa = {};
	sa.nLength        = sizeof( sa );
	sa.bInheritHandle = TRUE;

	HANDLE hLog = ::CreateFileW( sLogPath, GENERIC_WRITE, FILE_SHARE_READ, &sa,
	                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr );

	STARTUPINFOW si = {};
	si.cb = sizeof( si );
	BOOL bInheritHandles = FALSE;

	if ( hLog != INVALID_HANDLE_VALUE )
	{
		si.dwFlags    = STARTF_USESTDHANDLES;
		si.hStdInput  = NULL;
		si.hStdOutput = hLog;
		si.hStdError  = hLog;
		bInheritHandles = TRUE;
	}

	PROCESS_INFORMATION pi = {};

	if ( !::CreateProcessW( nullptr, sCommandLine.GetBuffer(), nullptr, nullptr,
	                        bInheritHandles, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi ) )
	{
		DWORD err = ::GetLastError();
		CString sMsg;
		sMsg.Format( _T("View: CreateProcess failed (0x%08X): %ls"), err, (LPCWSTR)sCommandLine );
		LogEventMessage( PYTHONTOOLS_CATEGORY, sMsg, LogEventType::Error );
		if ( hLog != INVALID_HANDLE_VALUE )
			::CloseHandle( hLog );
		return HRESULT_FROM_WIN32( err );
	}

	// Allow the newly spawned process to call SetForegroundWindow on its Qt window.
	::AllowSetForegroundWindow( pi.dwProcessId );

	::CloseHandle( pi.hThread );
	::CloseHandle( pi.hProcess );
	if ( hLog != INVALID_HANDLE_VALUE )
		::CloseHandle( hLog );

	return S_OK;
}

// ---------------------------------------------------------------------------
// Shared helpers for console-based tool launching
// ---------------------------------------------------------------------------

static std::wstring GetPythonExePath()
{
	std::vector<CStringW> configFiles = BuildConfigFileList( g_hInstance );
	CStringW sPythonDir;
	GetPrivateProfileStringAndExpandEnvironmentStrings( L"PYTHON", L"PATH", L"", sPythonDir, configFiles );

	wchar_t sPythonExe[MAX_PATH];
	if ( !sPythonDir.IsEmpty() )
	{
		wcscpy_s( sPythonExe, sPythonDir.GetString() );
		::PathCchAppend( sPythonExe, ARRAYSIZE( sPythonExe ), L"python.exe" );
	}
	else
	{
		wcscpy_s( sPythonExe, L"python.exe" );
	}
	return sPythonExe;
}

// Runs a command inside cmd.exe /K so the console stays open after the tool exits.
// commandLine must be the full inner command (e.g. L"\"python\" \"tool\" \"file\"").
static HRESULT RunInConsole( LPCWSTR innerCommand )
{
	// cmd /C ""inner" & pause" — /C exits after the command; & pause waits for a
	// keypress then closes the window. Outer quotes required by cmd when the inner
	// command contains quoted tokens.
	CStringW sCmd;
	sCmd.Format( L"cmd.exe /C \"%ls & pause\"", innerCommand );

	STARTUPINFOW si = {};
	si.cb = sizeof( si );
	PROCESS_INFORMATION pi = {};

	if ( !::CreateProcessW( nullptr, sCmd.GetBuffer(), nullptr, nullptr,
	                        FALSE, CREATE_NEW_CONSOLE, nullptr, nullptr, &si, &pi ) )
	{
		DWORD err = ::GetLastError();
		CString sMsg;
		sMsg.Format( _T("RunInConsole: CreateProcess failed (0x%08X): %ls"), err, (LPCWSTR)sCmd );
		LogEventMessage( PYTHONTOOLS_CATEGORY, sMsg, LogEventType::Error );
		return HRESULT_FROM_WIN32( err );
	}

	::AllowSetForegroundWindow( pi.dwProcessId );
	::CloseHandle( pi.hThread );
	::CloseHandle( pi.hProcess );
	return S_OK;
}

// ---------------------------------------------------------------------------
// Validate — runs UsdValidate.py (pxr.UsdUtils.ComplianceChecker) in a console
// ---------------------------------------------------------------------------

STDMETHODIMP CUsdPythonToolsImpl::Validate( IN BSTR usdStagePath )
{
	DEBUG_RECORD_ENTRY();

	wchar_t sTempDir[MAX_PATH] = {};
	::GetTempPathW( ARRAYSIZE( sTempDir ), sTempDir );

	wchar_t sScriptPath[MAX_PATH] = {};
	wcscpy_s( sScriptPath, sTempDir );
	::PathCchAppend( sScriptPath, ARRAYSIZE( sScriptPath ), L"UsdValidate.py" );

	HRSRC hRes = ::FindResource( g_hInstance, MAKEINTRESOURCE( IDR_PYTHON_VALIDATE ), _T("PYTHON") );
	if ( hRes )
	{
		HGLOBAL hData  = ::LoadResource( g_hInstance, hRes );
		void*   pData  = ::LockResource( hData );
		DWORD   nSize  = ::SizeofResource( g_hInstance, hRes );
		HANDLE  hFile  = ::CreateFileW( sScriptPath, GENERIC_WRITE, 0, nullptr,
		                                CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr );
		if ( hFile != INVALID_HANDLE_VALUE )
		{
			DWORD nWritten = 0;
			::WriteFile( hFile, pData, nSize, &nWritten, nullptr );
			::CloseHandle( hFile );
		}
	}

	std::wstring sPythonExe = GetPythonExePath();

	CStringW sInner;
	sInner.Format( L"\"%ls\" \"%ls\"", sPythonExe.c_str(), sScriptPath );

	// Append each pipe-delimited path as a separate quoted argument.
	CStringW sPathsCopy = usdStagePath;
	int iStart = 0;
	while ( iStart <= sPathsCopy.GetLength() )
	{
		int iSep = sPathsCopy.Find( L'|', iStart );
		CStringW sPath = ( iSep >= 0 )
		    ? sPathsCopy.Mid( iStart, iSep - iStart )
		    : sPathsCopy.Mid( iStart );
		if ( !sPath.IsEmpty() )
			sInner.AppendFormat( L" \"%ls\"", (LPCWSTR)sPath );
		if ( iSep < 0 ) break;
		iStart = iSep + 1;
	}

	return RunInConsole( sInner );
}

// ---------------------------------------------------------------------------
// Fix — runs usdfixbrokenpixarschemas in a visible console
// ---------------------------------------------------------------------------

STDMETHODIMP CUsdPythonToolsImpl::Fix( IN BSTR usdStagePath )
{
	DEBUG_RECORD_ENTRY();

	std::wstring sToolPath = FindRelativeFile( L"usdfixbrokenpixarschemas" );
	if ( sToolPath.empty() )
	{
		LogEventMessage( PYTHONTOOLS_CATEGORY, L"Fix: usdfixbrokenpixarschemas not found in USD PATH", LogEventType::Error );
		return E_FAIL;
	}

	// Write UsdFix.py wrapper to temp so we can patch Tf.ErrorException.__str__
	// before the tool starts (same pattern as View/UsdViewWrapper.py).
	wchar_t sTempDir[MAX_PATH] = {};
	::GetTempPathW( ARRAYSIZE( sTempDir ), sTempDir );

	wchar_t sWrapperPath[MAX_PATH] = {};
	wcscpy_s( sWrapperPath, sTempDir );
	::PathCchAppend( sWrapperPath, ARRAYSIZE( sWrapperPath ), L"UsdFixWrapper.py" );

	HRSRC hRes = ::FindResource( g_hInstance, MAKEINTRESOURCE( IDR_PYTHON_FIX ), _T("PYTHON") );
	if ( hRes )
	{
		HGLOBAL hData  = ::LoadResource( g_hInstance, hRes );
		void*   pData  = ::LockResource( hData );
		DWORD   nSize  = ::SizeofResource( g_hInstance, hRes );
		HANDLE  hFile  = ::CreateFileW( sWrapperPath, GENERIC_WRITE, 0, nullptr,
		                                CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr );
		if ( hFile != INVALID_HANDLE_VALUE )
		{
			DWORD nWritten = 0;
			::WriteFile( hFile, pData, nSize, &nWritten, nullptr );
			::CloseHandle( hFile );
		}
	}

	std::wstring sPythonExe = GetPythonExePath();

	CStringW sInner;
	sInner.Format( L"\"%ls\" \"%ls\" \"%ls\" \"%ls\"",
	               sPythonExe.c_str(), sWrapperPath, sToolPath.c_str(), (LPCWSTR)usdStagePath );
	return RunInConsole( sInner );
}

// ---------------------------------------------------------------------------
// ShowLayerStack — extracts UsdLayerStack.py to %TEMP% and runs it
// ---------------------------------------------------------------------------

STDMETHODIMP CUsdPythonToolsImpl::ShowLayerStack( IN BSTR usdStagePath )
{
	DEBUG_RECORD_ENTRY();

	wchar_t sTempDir[MAX_PATH] = {};
	::GetTempPathW( ARRAYSIZE( sTempDir ), sTempDir );

	wchar_t sScriptPath[MAX_PATH] = {};
	wcscpy_s( sScriptPath, sTempDir );
	::PathCchAppend( sScriptPath, ARRAYSIZE( sScriptPath ), L"UsdLayerStack.py" );

	HRSRC hRes = ::FindResource( g_hInstance, MAKEINTRESOURCE( IDR_PYTHON_LAYERSTACK ), _T("PYTHON") );
	if ( hRes )
	{
		HGLOBAL hData  = ::LoadResource( g_hInstance, hRes );
		void*   pData  = ::LockResource( hData );
		DWORD   nSize  = ::SizeofResource( g_hInstance, hRes );
		HANDLE  hFile  = ::CreateFileW( sScriptPath, GENERIC_WRITE, 0, nullptr,
		                                CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr );
		if ( hFile != INVALID_HANDLE_VALUE )
		{
			DWORD nWritten = 0;
			::WriteFile( hFile, pData, nSize, &nWritten, nullptr );
			::CloseHandle( hFile );
		}
	}

	std::wstring sPythonExe = GetPythonExePath();

	CStringW sInner;
	sInner.Format( L"\"%ls\" \"%ls\" \"%ls\"",
	               sPythonExe.c_str(), sScriptPath, (LPCWSTR)usdStagePath );
	return RunInConsole( sInner );
}

// ---------------------------------------------------------------------------
// ShowStageStats — extracts UsdStageStats.py to %TEMP% and runs it
// ---------------------------------------------------------------------------

STDMETHODIMP CUsdPythonToolsImpl::ShowStageStats( IN BSTR usdStagePath )
{
	DEBUG_RECORD_ENTRY();

	wchar_t sTempDir[MAX_PATH] = {};
	::GetTempPathW( ARRAYSIZE( sTempDir ), sTempDir );

	wchar_t sScriptPath[MAX_PATH] = {};
	wcscpy_s( sScriptPath, sTempDir );
	::PathCchAppend( sScriptPath, ARRAYSIZE( sScriptPath ), L"UsdStageStats.py" );

	HRSRC hRes = ::FindResource( g_hInstance, MAKEINTRESOURCE( IDR_PYTHON_STAGESTATS ), _T("PYTHON") );
	if ( hRes )
	{
		HGLOBAL hData  = ::LoadResource( g_hInstance, hRes );
		void*   pData  = ::LockResource( hData );
		DWORD   nSize  = ::SizeofResource( g_hInstance, hRes );
		HANDLE  hFile  = ::CreateFileW( sScriptPath, GENERIC_WRITE, 0, nullptr,
		                                CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr );
		if ( hFile != INVALID_HANDLE_VALUE )
		{
			DWORD nWritten = 0;
			::WriteFile( hFile, pData, nSize, &nWritten, nullptr );
			::CloseHandle( hFile );
		}
	}

	std::wstring sPythonExe = GetPythonExePath();

	CStringW sInner;
	sInner.Format( L"\"%ls\" \"%ls\" \"%ls\"",
	               sPythonExe.c_str(), sScriptPath, (LPCWSTR)usdStagePath );
	return RunInConsole( sInner );
}

// ---------------------------------------------------------------------------
// Stitch — runs UsdStitch.py (pxr.UsdUtils.StitchLayers) in a console
// ---------------------------------------------------------------------------

STDMETHODIMP CUsdPythonToolsImpl::Stitch( IN BSTR inputPaths, IN BSTR outputPath )
{
	DEBUG_RECORD_ENTRY();

	wchar_t sTempDir[MAX_PATH] = {};
	::GetTempPathW( ARRAYSIZE( sTempDir ), sTempDir );

	wchar_t sScriptPath[MAX_PATH] = {};
	wcscpy_s( sScriptPath, sTempDir );
	::PathCchAppend( sScriptPath, ARRAYSIZE( sScriptPath ), L"UsdStitch.py" );

	HRSRC hRes = ::FindResource( g_hInstance, MAKEINTRESOURCE( IDR_PYTHON_STITCH ), _T("PYTHON") );
	if ( hRes )
	{
		HGLOBAL hData = ::LoadResource( g_hInstance, hRes );
		void*   pData = ::LockResource( hData );
		DWORD   nSize = ::SizeofResource( g_hInstance, hRes );
		HANDLE  hFile = ::CreateFileW( sScriptPath, GENERIC_WRITE, 0, nullptr,
		                               CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr );
		if ( hFile != INVALID_HANDLE_VALUE )
		{
			DWORD nWritten = 0;
			::WriteFile( hFile, pData, nSize, &nWritten, nullptr );
			::CloseHandle( hFile );
		}
	}

	std::wstring sPythonExe = GetPythonExePath();

	CStringW sInner;
	sInner.Format( L"\"%ls\" \"%ls\" \"%ls\"",
	               sPythonExe.c_str(), sScriptPath, (LPCWSTR)outputPath );

	// Append each pipe-delimited input path as a quoted argument.
	CStringW sInputsCopy = inputPaths;
	int iStart = 0;
	while ( iStart <= sInputsCopy.GetLength() )
	{
		int iSep = sInputsCopy.Find( L'|', iStart );
		CStringW sPath = ( iSep >= 0 )
		    ? sInputsCopy.Mid( iStart, iSep - iStart )
		    : sInputsCopy.Mid( iStart );
		if ( !sPath.IsEmpty() )
			sInner.AppendFormat( L" \"%ls\"", (LPCWSTR)sPath );
		if ( iSep < 0 ) break;
		iStart = iSep + 1;
	}

	return RunInConsole( sInner );
}

// ---------------------------------------------------------------------------
// Diff — runs usddiff on two USD files in a visible console
// ---------------------------------------------------------------------------

STDMETHODIMP CUsdPythonToolsImpl::Diff( IN BSTR path1, IN BSTR path2 )
{
	DEBUG_RECORD_ENTRY();

	std::wstring sToolPath = FindRelativeFile( L"usddiff" );
	if ( sToolPath.empty() )
	{
		LogEventMessage( PYTHONTOOLS_CATEGORY, L"Diff: usddiff not found in USD PATH", LogEventType::Error );
		return E_FAIL;
	}

	wchar_t sTempDir[MAX_PATH] = {};
	::GetTempPathW( ARRAYSIZE( sTempDir ), sTempDir );

	wchar_t sWrapperPath[MAX_PATH] = {};
	wcscpy_s( sWrapperPath, sTempDir );
	::PathCchAppend( sWrapperPath, ARRAYSIZE( sWrapperPath ), L"UsdDiff.py" );

	HRSRC hRes = ::FindResource( g_hInstance, MAKEINTRESOURCE( IDR_PYTHON_DIFF ), _T("PYTHON") );
	if ( hRes )
	{
		HGLOBAL hData  = ::LoadResource( g_hInstance, hRes );
		void*   pData  = ::LockResource( hData );
		DWORD   nSize  = ::SizeofResource( g_hInstance, hRes );
		HANDLE  hFile  = ::CreateFileW( sWrapperPath, GENERIC_WRITE, 0, nullptr,
		                                CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr );
		if ( hFile != INVALID_HANDLE_VALUE )
		{
			DWORD nWritten = 0;
			::WriteFile( hFile, pData, nSize, &nWritten, nullptr );
			::CloseHandle( hFile );
		}
	}

	std::wstring sPythonExe = GetPythonExePath();

	CStringW sInner;
	sInner.Format( L"\"%ls\" \"%ls\" \"%ls\" \"%ls\" \"%ls\"",
	               sPythonExe.c_str(), sWrapperPath, sToolPath.c_str(),
	               (LPCWSTR)path1, (LPCWSTR)path2 );
	return RunInConsole( sInner );
}

HRESULT WINAPI CUsdPythonToolsImpl::UpdateRegistry(_In_ BOOL bRegister) throw()
{
	ATL::_ATL_REGMAP_ENTRY regMapEntries[] =
	{
		{ L"APPID", L"{8777F2C4-2318-408A-85D8-F65E15811971}" },
		{ L"CLSID_USDPYTHONTOOLS", L"{67F43831-59C3-450E-8956-AA76273F3E9F}" },
		{ nullptr, nullptr }
	};

	return g_AtlModule.UpdateRegistryFromResource(IDR_REGISTRY_USDTOOLSIMPL, bRegister, regMapEntries);
}