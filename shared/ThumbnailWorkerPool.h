// USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
// Licensed under the MIT License. See LICENSE.txt for details.

#pragma once

// Pool of warm thumbnail workers (UsdThumbnailWorker.py). A worker loads
// Python, USD, Qt and its GL context once, then renders each request in
// ~30-170 ms instead of ~0.9 s for a new python.exe per thumbnail.
//
// Protocol: one JSON line per request on the worker stdin, one JSON line per
// result on its stdout (see UsdThumbnailWorker.py). ASCII only: non-ASCII
// characters are \u escaped, so the worker code page does not matter.

#include <atlbase.h>
#include <atlstr.h>

#include <condition_variable>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// The worker process could not be started: the caller should fall back to
// the one python.exe per thumbnail mode.
#define THUMBNAIL_E_WORKER_UNAVAILABLE MAKE_HRESULT( SEVERITY_ERROR, FACILITY_ITF, 0x0201 )

// One parsed result line.
struct ThumbnailResult
{
	long long id = -1;
	bool ok = false;
	CStringW error;
};

// Escape a string for a JSON string literal, ASCII only (\uXXXX otherwise).
std::string JsonEscape( LPCWSTR sText );

// Build the request line (with its trailing newline) for one render.
std::string BuildRenderRequest( long long id, LPCWSTR sUsdPath, LPCWSTR sOutputPath, int width, LPCWSTR sRenderer );

// Parse one result line. Returns false when it is not a result.
bool ParseRenderResult( const std::string &line, ThumbnailResult &result );

class CThumbnailWorkerPool
{
public:
	struct Settings
	{
		CStringW commandLine;				// starts one worker
		size_t maxWorkers = 3;				// renders running at once
		DWORD requestTimeoutMs = 30000;		// per render
		DWORD startupTimeoutMs = 90000;		// added to the first render of a worker (cold start)
		DWORD slotTimeoutMs = 60000;		// wait for a free worker
		unsigned maxRendersPerWorker = 50;	// then the worker is recycled
		DWORD idleTimeoutMs = 120000;		// unused workers are stopped
	};

	explicit CThumbnailWorkerPool( const Settings &settings );
	~CThumbnailWorkerPool();

	CThumbnailWorkerPool( const CThumbnailWorkerPool & ) = delete;
	CThumbnailWorkerPool &operator=( const CThumbnailWorkerPool & ) = delete;

	// Render one thumbnail on a warm worker. Returns S_OK; E_FAIL when the
	// worker reports a failure (sError holds its message);
	// HRESULT_FROM_WIN32( ERROR_TIMEOUT ) when the worker was killed after
	// requestTimeoutMs; HRESULT_FROM_WIN32( ERROR_BROKEN_PIPE ) when it died
	// or answered garbage; HRESULT_FROM_WIN32( ERROR_BUSY ) when no worker
	// was free within slotTimeoutMs; THUMBNAIL_E_WORKER_UNAVAILABLE when no
	// worker could be started.
	HRESULT Render( LPCWSTR sUsdPath, LPCWSTR sOutputPath, int width, LPCWSTR sRenderer, CStringW &sError );

	// Number of worker processes currently alive (busy or idle).
	size_t GetWorkerCount();

private:
	struct Worker;

	HRESULT StartWorker( std::unique_ptr<Worker> &pWorker, CStringW &sError );
	HRESULT Exchange( Worker &worker, long long id, const std::string &request, ThumbnailResult &result, CStringW &sError );
	static void StopWorker( Worker &worker, bool bGraceful );
	void StopIdleWorkersLoop();

	Settings m_settings;
	CHandle m_hJob;						// kills every worker if the pool or its process dies

	std::mutex m_lock;
	std::condition_variable m_workerFreed;
	std::vector<std::unique_ptr<Worker>> m_workers;
	size_t m_startingWorkers = 0;		// slots reserved by workers being started
	long long m_nextRequestId = 1;

	bool m_bStopping = false;
	std::condition_variable m_stopRequested;
	std::thread m_idleThread;
};
