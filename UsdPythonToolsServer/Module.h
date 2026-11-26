// USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
// Licensed under the MIT License. See LICENSE.txt for details.

#pragma once

#include "UsdPythonToolsLocalServer_h.h"
#include "resource.h"

#include <atomic>

// Stop the warm thumbnail workers (UsdPythonToolsImpl.cpp); called when the
// server leaves its message loop, before static destruction.
void ShutdownThumbnailWorkerPool();

// Using an ATL module here because it removes a lot of the 
// boiler-plate COM work that we would have to implement ourselves.

class CUsdPythonToolsLocalServerModule : public CAtlExeModuleT<CUsdPythonToolsLocalServerModule>
{
public:
	DECLARE_LIBID( LIBID_UsdPythonToolsLib )
	DECLARE_REGISTRY_APPID_RESOURCEID( IDR_REGISTRY_MODULE, "{8777F2C4-2318-408A-85D8-F65E15811971}" )

	// One shared server process (REGCLS_MULTIPLEUSE) keeps the warm thumbnail
	// workers alive between calls. It used to be REGCLS_SINGLEUSE (one process
	// per object) to isolate Python run inside the server; the server no
	// longer runs Python itself, every tool runs in a subprocess.
	//
	// Idle shutdown: ATL quits as soon as the last object is released (its
	// m_dwTimeOut is no longer used), and COM suspends the class factory when
	// the server-process count reaches 0, so the next client would start a new
	// server with cold workers. Instead the server holds one server-process
	// reference of its own (keep-alive) and an idle monitor releases it only
	// after kServerIdleTimeoutMs without any client.
	static constexpr DWORD kServerIdleTimeoutMs = 120000;

	CUsdPythonToolsLocalServerModule()
	{
		// Auto-reset: signaled each time the last client leaves.
		m_hIdleEvent.Attach( ::CreateEventW( nullptr, FALSE, FALSE, nullptr ) );
	}

	LONG Lock() throw() override
	{
		++m_nClientLocks;
		return ::CoAddRefServerProcess();
	}

	LONG Unlock() throw() override
	{
		LONG lRet = ::CoReleaseServerProcess();
		if ( --m_nClientLocks == 0 )
			::SetEvent( m_hIdleEvent );	// only the keep-alive remains
		return lRet;
	}

	HRESULT PreMessageLoop( _In_ int /*nShowCmd*/ ) throw()
	{
		CUsdPythonToolsLocalServerModule* pT = static_cast<CUsdPythonToolsLocalServerModule*>(this);

		HRESULT hr = pT->RegisterClassObjects( CLSCTX_LOCAL_SERVER, REGCLS_MULTIPLEUSE | REGCLS_SUSPENDED );
		if ( FAILED( hr ) )
			return hr;

		// Keep-alive reference, then the idle monitor. The server starts idle:
		// if no client ever comes, it still quits after the timeout.
		::CoAddRefServerProcess();
		CHandle hMonitor( ::CreateThread( nullptr, 0, IdleMonitorProc, this, 0, nullptr ) );
		if ( !hMonitor || !m_hIdleEvent )
		{
			::CoReleaseServerProcess();
			pT->RevokeClassObjects();
			return E_FAIL;
		}
		::SetEvent( m_hIdleEvent );

		hr = ::CoResumeClassObjects();
		if ( FAILED( hr ) )
			pT->RevokeClassObjects();
		return hr;
	}

	// Stop the thumbnail workers while the process is still fully alive,
	// rather than in static destruction at exit.
	HRESULT PostMessageLoop() throw()
	{
		ShutdownThumbnailWorkerPool();
		return CAtlExeModuleT<CUsdPythonToolsLocalServerModule>::PostMessageLoop();
	}

private:
	static DWORD WINAPI IdleMonitorProc( _In_ void *pv ) throw()
	{
		static_cast<CUsdPythonToolsLocalServerModule *>( pv )->MonitorIdle();
		return 0;
	}

	// Wait for the last client to leave, then for kServerIdleTimeoutMs more.
	// A client coming back meanwhile cancels the countdown.
	void MonitorIdle() throw()
	{
		for ( ;; )
		{
			::WaitForSingleObject( m_hIdleEvent, INFINITE );

			// Restart the countdown each time the last client leaves again.
			while ( ::WaitForSingleObject( m_hIdleEvent, kServerIdleTimeoutMs ) == WAIT_OBJECT_0 )
				;

			if ( m_nClientLocks > 0 )
				continue;	// busy again: wait for the next idle period

			// Release the keep-alive. At 0 COM suspends the class factory, so
			// no new client can reach this process: safe to quit.
			if ( ::CoReleaseServerProcess() == 0 )
			{
				::PostThreadMessage( m_dwMainThreadID, WM_QUIT, 0, 0 );
				return;
			}
			// A client arrived in between: keep serving, keep the keep-alive.
			::CoAddRefServerProcess();
		}
	}

	CHandle m_hIdleEvent;
	std::atomic<LONG> m_nClientLocks{ 0 };};

extern CUsdPythonToolsLocalServerModule g_AtlModule;
extern HMODULE g_hInstance;
// Helpful for debugging zombie processes.
// Set to the last method that was called in IUSDTools. Atomic: the shared
// free threaded server runs calls on several threads at once (a CString
// written concurrently would corrupt the heap). Points to __FUNCTION__ literals.
extern std::atomic<LPCTSTR> g_DebugIUsdPythonToolsMethod;

#define DEBUG_RECORD_ENTRY() \
	g_DebugIUsdPythonToolsMethod = _T(__FUNCTION__)
