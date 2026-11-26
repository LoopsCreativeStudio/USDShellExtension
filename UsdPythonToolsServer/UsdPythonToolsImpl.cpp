// USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
// Licensed under the MIT License. See LICENSE.txt for details.

#include "stdafx.h"
#include "UsdPythonToolsImpl.h"
#include "Module.h"
#include "shared\environment.h"
#include "shared\EventViewerLog.h"
#include "shared\ProcessUtil.h"
#include "shared\ThumbnailWorkerPool.h"
#include "UsdPythonToolsLocalServer_h.h"

#include <atomic>
#include <memory>
#include <mutex>
#include <vector>

// Throttle concurrent thumbnail renders to avoid GPU/CPU thrashing when
// Explorer requests many thumbnails at once: size of the warm worker pool,
// and limit of the fallback mode (named semaphore shared on the session).
static constexpr int kMaxConcurrentRenders = 3;
// Longest wait for a free render slot before giving up on a thumbnail.
static constexpr DWORD kRenderSlotTimeoutMs = 60000;
// Longest run time of one thumbnail subprocess before it is killed.
static constexpr DWORD kRenderTimeoutMs = 30000;
static HANDLE g_hRenderSemaphore = ::CreateSemaphoreW(
    nullptr, kMaxConcurrentRenders, kMaxConcurrentRenders,
    L"Local\\UsdShellExtension_ThumbnailSemaphore" );

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

// ---------------------------------------------------------------------------
// Embedded tool scripts
// ---------------------------------------------------------------------------

// Folder of the scripts extracted by this server process, under
// %TEMP%\UsdShellExtension. Each script is written once per process and
// never rewritten while a python.exe reads it (several tools or renders may
// run at once). Folders left by servers that crashed are removed first.
static CStringW PrepareScriptParentDirectory()
{
	wchar_t sTempPath[MAX_PATH];
	::GetTempPathW( ARRAYSIZE( sTempPath ), sTempPath );
	CStringW sParent = sTempPath;
	sParent += L"UsdShellExtension";

	CScriptDirectory::RemoveStaleDirectories( sParent );
	return sParent;
}

static CScriptDirectory &GetScriptDirectory()
{
	// Thread-safe first-use initialization; the destructor deletes the
	// folder when the server process exits.
	static CScriptDirectory s_scripts( PrepareScriptParentDirectory() );
	return s_scripts;
}

// Return the path of an embedded script (PYTHON resource), extracting it on
// first use. Logs and fails if the resource or the file is missing.
static HRESULT ExtractScript( UINT resourceId, LPCWSTR sFileName, CStringW &sPath )
{
	HRSRC hRes = ::FindResource( g_hInstance, MAKEINTRESOURCE( resourceId ), _T("PYTHON") );
	HGLOBAL hData = hRes ? ::LoadResource( g_hInstance, hRes ) : nullptr;
	void *pData = hData ? ::LockResource( hData ) : nullptr;
	if ( pData == nullptr )
	{
		CString sMsg;
		sMsg.Format( _T("Embedded script %ls not found in resources"), sFileName );
		LogEventMessage( PYTHONTOOLS_CATEGORY, sMsg, LogEventType::Error );
		return HRESULT_FROM_WIN32( ERROR_RESOURCE_NAME_NOT_FOUND );
	}

	HRESULT hr = GetScriptDirectory().GetFile( sFileName, pData, ::SizeofResource( g_hInstance, hRes ), sPath );
	if ( FAILED( hr ) )
	{
		CString sMsg;
		sMsg.Format( _T("Failed to extract %ls to %ls (0x%08X)"), sFileName, GetScriptDirectory().GetDirectory().GetString(), hr );
		LogEventMessage( PYTHONTOOLS_CATEGORY, sMsg, LogEventType::Error );
	}
	return hr;
}

// ---------------------------------------------------------------------------
// Thumbnails: warm worker pool, with the one python.exe per thumbnail mode
// as fallback
// ---------------------------------------------------------------------------

static std::mutex s_thumbnailPoolLock;
static std::unique_ptr<CThumbnailWorkerPool> s_pThumbnailPool;

// Shared pool of warm thumbnail workers, created on first use. Both scripts
// are extracted first: the worker imports UsdThumbnail from its own folder.
// Returns nullptr when the scripts cannot be extracted.
static CThumbnailWorkerPool *GetThumbnailWorkerPool()
{
	std::lock_guard<std::mutex> guard( s_thumbnailPoolLock );
	if ( s_pThumbnailPool )
		return s_pThumbnailPool.get();

	CStringW sThumbnailScript, sWorkerScript;
	if ( FAILED( ExtractScript( IDR_PYTHON_THUMBNAIL, L"UsdThumbnail.py", sThumbnailScript ) ) ||
	     FAILED( ExtractScript( IDR_PYTHON_THUMBNAIL_WORKER, L"UsdThumbnailWorker.py", sWorkerScript ) ) )
		return nullptr;

	CThumbnailWorkerPool::Settings settings;
	// -B: no __pycache__ next to the scripts (useless in a per-process folder).
	settings.commandLine.Format( L"\"%ls\" -B -u \"%ls\"", GetPythonExePath().c_str(), sWorkerScript.GetString() );
	settings.maxWorkers       = kMaxConcurrentRenders;
	settings.requestTimeoutMs = kRenderTimeoutMs;
	settings.slotTimeoutMs    = kRenderSlotTimeoutMs;
	s_pThumbnailPool = std::make_unique<CThumbnailWorkerPool>( settings );
	return s_pThumbnailPool.get();
}

void ShutdownThumbnailWorkerPool()
{
	std::lock_guard<std::mutex> guard( s_thumbnailPoolLock );
	s_pThumbnailPool.reset();
}

// Render on a warm worker. Returns THUMBNAIL_E_WORKER_UNAVAILABLE when no
// worker can run: the caller then falls back to RecordInSubprocess.
static HRESULT RecordWithWorkerPool( BSTR usdStagePath, int imageWidth, BSTR renderer, const CStringW &sImagePath )
{
	CThumbnailWorkerPool *pPool = GetThumbnailWorkerPool();
	if ( pPool == nullptr )
		return THUMBNAIL_E_WORKER_UNAVAILABLE;

	CStringW sError;
	HRESULT hr = pPool->Render( usdStagePath, sImagePath, imageWidth, renderer ? renderer : L"", sError );

	if ( hr == THUMBNAIL_E_WORKER_UNAVAILABLE )
	{
		// Logged once per process: the cause is usually permanent.
		static std::atomic<bool> s_bReported{ false };
		if ( !s_bReported.exchange( true ) )
		{
			CString sMsg;
			sMsg.Format( _T("Record: thumbnail worker unavailable, using one python.exe per thumbnail: %ls"), sError.GetString() );
			LogEventMessage( PYTHONTOOLS_CATEGORY, sMsg, LogEventType::Warning );
		}
	}
	else if ( FAILED( hr ) )
	{
		CString sMsg;
		sMsg.Format( _T("Record: thumbnail failed for %ls (0x%08X)\n\n%ls"), usdStagePath, hr, sError.GetString() );
		LogEventMessage( PYTHONTOOLS_CATEGORY, sMsg, LogEventType::Error );
	}
	return hr;
}

// Fallback: render in a new python.exe running UsdThumbnail.py.
static HRESULT RecordInSubprocess( BSTR usdStagePath, int imageWidth, BSTR renderer, const CStringW &sImagePath, const CStringW &sTempDir )
{
	HRESULT hr;

	// --- UsdThumbnail.py, extracted once per server process ---
	// UsdImagingGLEngine requires WGL context initialization driven by a Win32
	// message loop. Running it via PyRun_String on the COM thread blocks the loop
	// and causes "No renderer plugins found!". A subprocess gets its own process
	// with full message-pump capability (same fix as View/usdview).
	// The script is written once and only read afterwards, so the
	// kMaxConcurrentRenders renders running at once can share it safely.
	CStringW sScriptPath;
	hr = ExtractScript( IDR_PYTHON_THUMBNAIL, L"UsdThumbnail.py", sScriptPath );
	if ( FAILED( hr ) )
		return hr;

	// --- Build command line ---
	std::wstring sPythonExe = GetPythonExePath();

	CStringW sImageWidth;
	sImageWidth.Format( L"%d", imageWidth );

	CStringW sCommandLine;
	sCommandLine.Format( L"\"%ls\" \"%ls\" --imageWidth %ls",
	                     sPythonExe.c_str(), sScriptPath.GetString(), (LPCWSTR)sImageWidth );

	if ( renderer != nullptr && renderer[0] != L'\0' )
		sCommandLine.AppendFormat( L" --renderer %ls", renderer );

	sCommandLine.AppendFormat( L" \"%ls\" \"%ls\"", (LPCWSTR)usdStagePath, sImagePath.GetString() );

	// --- Per-call log receiving the subprocess stdout / stderr ---
	// Optional: without it the render still runs, only the failure details
	// are lost.
	CUniqueTempFile logFile;
	CHandle hLog;
	if ( SUCCEEDED( logFile.Create( sTempDir, L"UsdThumbnail_", L"log" ) ) )
		hLog.Attach( OpenInheritableForWrite( logFile.GetPath() ) );

	// --- Launch subprocess (throttled, every wait bounded) ---
	DWORD exitCode = 0;
	{
		// Wait for a render slot (max kMaxConcurrentRenders at once). If the
		// semaphore could not be created, render without throttling.
		CSemaphoreSlot renderSlot;
		if ( g_hRenderSemaphore != nullptr && !renderSlot.Acquire( g_hRenderSemaphore, kRenderSlotTimeoutMs ) )
		{
			CString sMsg;
			sMsg.Format( _T("Record: no render slot free after %lu s, thumbnail skipped for %ls"),
			             kRenderSlotTimeoutMs / 1000, usdStagePath );
			LogEventMessage( PYTHONTOOLS_CATEGORY, sMsg, LogEventType::Warning );
			return HRESULT_FROM_WIN32( ERROR_TIMEOUT );
		}

		hr = RunProcessAndWait( sCommandLine, hLog.m_h, kRenderTimeoutMs, exitCode );
		// The slot is released here, as soon as the subprocess is done.
	}
	hLog.Close();

	// --- Report failures with the subprocess output ---
	if ( FAILED( hr ) || exitCode != 0 )
	{
		// A failed or killed render may have left a partial image: Record's
		// imageFile deletes it.
		CStringA sLogContent = logFile.ReadAll();
		CString sErrorMsg;
		if ( hr == HRESULT_FROM_WIN32( ERROR_TIMEOUT ) )
			sErrorMsg.Format( _T("Record: thumbnail process timed out after %lu s for %ls"), kRenderTimeoutMs / 1000, usdStagePath );
		else if ( FAILED( hr ) )
			sErrorMsg.Format( _T("Record: CreateProcess failed (0x%08X): %ls"), hr, sCommandLine.GetString() );
		else
			sErrorMsg.Format( _T("Record: thumbnail failed for %ls (exit %lu)"), usdStagePath, exitCode );

		if ( !sLogContent.IsEmpty() )
			sErrorMsg.AppendFormat( _T("\n\n%hs"), sLogContent.GetString() );

		LogEventMessage( PYTHONTOOLS_CATEGORY, sErrorMsg.GetString(), LogEventType::Error );
		return FAILED( hr ) ? hr : E_FAIL;
	}

	return S_OK;
}

STDMETHODIMP CUsdPythonToolsImpl::Record( IN BSTR usdStagePath, IN int imageWidth, IN BSTR renderer, OUT BSTR *outputImagePath )
{
	DEBUG_RECORD_ENTRY();

	if ( outputImagePath == nullptr )
		return E_POINTER;
	*outputImagePath = nullptr;

	HRESULT hr;

	// --- Unique temp PNG output path ---
	wchar_t sTempPath[MAX_PATH];
	::GetTempPathW( ARRAYSIZE( sTempPath ), sTempPath );

	// Temp folder without the trailing backslash, for the per-call files.
	CStringW sTempDir = sTempPath;
	sTempDir.TrimRight( L'\\' );

	// The image name stays reserved (the file exists) until the render
	// writes it: parallel calls can never be given the same image. It is
	// deleted automatically on failure and handed to the caller on success.
	CUniqueTempFile imageFile;
	hr = imageFile.Create( sTempDir, L"UsdThumbnailImage_", L"png" );
	if ( FAILED( hr ) )
	{
		CString sMsg;
		sMsg.Format( _T("Record: failed to reserve the thumbnail image in %ls (0x%08X)"), sTempDir.GetString(), hr );
		LogEventMessage( PYTHONTOOLS_CATEGORY, sMsg, LogEventType::Error );
		return hr;
	}

	// --- Render on a warm worker, or in a new python.exe if none can run ---
	hr = RecordWithWorkerPool( usdStagePath, imageWidth, renderer, imageFile.GetPath() );
	if ( hr == THUMBNAIL_E_WORKER_UNAVAILABLE )
		hr = RecordInSubprocess( usdStagePath, imageWidth, renderer, imageFile.GetPath(), sTempDir );
	if ( FAILED( hr ) )
		return hr;	// imageFile deletes any partial image

	// Success: the caller (shell extension) now owns and deletes the image.
	CComBSTR bstrOutputFile( imageFile.Detach() );
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

	std::wstring sPythonExe = GetPythonExePath();

	// UsdViewWrapper.py patches Tf.Error.commentary before usdview starts
	// (CP1252/UTF-8 mismatch fix). Without it, usdview still runs unpatched.
	CStringW sWrapperPath;
	HRESULT hr = ExtractScript( IDR_PYTHON_VIEW, L"UsdViewWrapper.py", sWrapperPath );

	// Build: "python.exe" "wrapper.py" "usdview" [--renderer R] "file.usd"
	CStringW sCommandLine;
	if ( SUCCEEDED( hr ) )
		sCommandLine.Format( L"\"%ls\" \"%ls\" \"%ls\"", sPythonExe.c_str(), sWrapperPath.GetString(), sUsdViewPath.c_str() );
	else
		sCommandLine.Format( L"\"%ls\" \"%ls\"", sPythonExe.c_str(), sUsdViewPath.c_str() );

	if ( renderer && renderer[0] != L'\0' )
		sCommandLine.AppendFormat( L" --renderer %ls", renderer );

	sCommandLine.AppendFormat( L" \"%ls\"", usdStagePath );

	// Redirect stdout/stderr to a per-call log in the script folder: captures
	// Python errors without a visible console, and two usdview windows never
	// share a log. It must outlive this call (usdview keeps running), so it
	// is removed with the script folder when the server exits.
	CHandle hLog;
	{
		CUniqueTempFile logFile;
		if ( SUCCEEDED( logFile.Create( GetScriptDirectory().GetDirectory(), L"UsdView_", L"log" ) ) )
			hLog.Attach( OpenInheritableForWrite( logFile.Detach() ) );
	}

	hr = LaunchProcess( sCommandLine, hLog.m_h, CREATE_NO_WINDOW );
	if ( FAILED( hr ) )
	{
		CString sMsg;
		sMsg.Format( _T("View: CreateProcess failed (0x%08X): %ls"), hr, sCommandLine.GetString() );
		LogEventMessage( PYTHONTOOLS_CATEGORY, sMsg, LogEventType::Error );
	}
	return hr;
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

// Append each '|' separated path as a separate quoted argument.
static void AppendPipeSeparatedPaths( CStringW &sCommandLine, LPCWSTR sPaths )
{
	CStringW sPathsCopy = sPaths;
	int iStart = 0;
	while ( iStart <= sPathsCopy.GetLength() )
	{
		int iSep = sPathsCopy.Find( L'|', iStart );
		CStringW sPath = ( iSep >= 0 )
		    ? sPathsCopy.Mid( iStart, iSep - iStart )
		    : sPathsCopy.Mid( iStart );
		if ( !sPath.IsEmpty() )
			sCommandLine.AppendFormat( L" \"%ls\"", (LPCWSTR)sPath );
		if ( iSep < 0 ) break;
		iStart = iSep + 1;
	}
}

// Runs a command in a new console window that stays open after the tool exits.
// innerCommand must be the full inner command (e.g. L"\"python\" \"tool\" \"file\"").
static HRESULT RunInConsole( LPCWSTR innerCommand )
{
	// cmd /C ""inner" & pause" — /C exits after the command; & pause waits for a
	// keypress then closes the window. Outer quotes required by cmd when the inner
	// command contains quoted tokens.
	CStringW sCmd;
	sCmd.Format( L"cmd.exe /C \"%ls & pause\"", innerCommand );

	HRESULT hr = LaunchProcess( sCmd, nullptr, CREATE_NEW_CONSOLE );
	if ( FAILED( hr ) )
	{
		CString sMsg;
		sMsg.Format( _T("RunInConsole: CreateProcess failed (0x%08X): %ls"), hr, sCmd.GetString() );
		LogEventMessage( PYTHONTOOLS_CATEGORY, sMsg, LogEventType::Error );
	}
	return hr;
}

// Run an embedded Python script in a console: "python" "script" + arguments.
static HRESULT RunScriptInConsole( UINT resourceId, LPCWSTR sScriptName, LPCWSTR sArguments )
{
	CStringW sScriptPath;
	HRESULT hr = ExtractScript( resourceId, sScriptName, sScriptPath );
	if ( FAILED( hr ) )
		return hr;

	CStringW sInner;
	sInner.Format( L"\"%ls\" \"%ls\"%ls", GetPythonExePath().c_str(), sScriptPath.GetString(), sArguments );
	return RunInConsole( sInner );
}

// ---------------------------------------------------------------------------
// Validate — runs UsdValidate.py (pxr.UsdUtils.ComplianceChecker) in a console
// ---------------------------------------------------------------------------

STDMETHODIMP CUsdPythonToolsImpl::Validate( IN BSTR usdStagePath )
{
	DEBUG_RECORD_ENTRY();

	CStringW sArguments;
	AppendPipeSeparatedPaths( sArguments, usdStagePath );
	return RunScriptInConsole( IDR_PYTHON_VALIDATE, L"UsdValidate.py", sArguments );
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

	// UsdFixWrapper.py patches Tf.ErrorException.__str__ before the tool
	// starts (same pattern as View/UsdViewWrapper.py).
	CStringW sArguments;
	sArguments.Format( L" \"%ls\" \"%ls\"", sToolPath.c_str(), (LPCWSTR)usdStagePath );
	return RunScriptInConsole( IDR_PYTHON_FIX, L"UsdFixWrapper.py", sArguments );
}

// ---------------------------------------------------------------------------
// ShowLayerStack — runs UsdLayerStack.py in a console
// ---------------------------------------------------------------------------

STDMETHODIMP CUsdPythonToolsImpl::ShowLayerStack( IN BSTR usdStagePath )
{
	DEBUG_RECORD_ENTRY();

	CStringW sArguments;
	sArguments.Format( L" \"%ls\"", (LPCWSTR)usdStagePath );
	return RunScriptInConsole( IDR_PYTHON_LAYERSTACK, L"UsdLayerStack.py", sArguments );
}

// ---------------------------------------------------------------------------
// ShowStageStats — runs UsdStageStats.py in a console
// ---------------------------------------------------------------------------

STDMETHODIMP CUsdPythonToolsImpl::ShowStageStats( IN BSTR usdStagePath )
{
	DEBUG_RECORD_ENTRY();

	CStringW sArguments;
	sArguments.Format( L" \"%ls\"", (LPCWSTR)usdStagePath );
	return RunScriptInConsole( IDR_PYTHON_STAGESTATS, L"UsdStageStats.py", sArguments );
}

// ---------------------------------------------------------------------------
// Stitch — runs UsdStitch.py (pxr.UsdUtils.StitchLayers) in a console
// ---------------------------------------------------------------------------

STDMETHODIMP CUsdPythonToolsImpl::Stitch( IN BSTR inputPaths, IN BSTR outputPath )
{
	DEBUG_RECORD_ENTRY();

	// Output first, then each input path.
	CStringW sArguments;
	sArguments.Format( L" \"%ls\"", (LPCWSTR)outputPath );
	AppendPipeSeparatedPaths( sArguments, inputPaths );
	return RunScriptInConsole( IDR_PYTHON_STITCH, L"UsdStitch.py", sArguments );
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

	CStringW sArguments;
	sArguments.Format( L" \"%ls\" \"%ls\" \"%ls\"", sToolPath.c_str(), (LPCWSTR)path1, (LPCWSTR)path2 );
	return RunScriptInConsole( IDR_PYTHON_DIFF, L"UsdDiff.py", sArguments );
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