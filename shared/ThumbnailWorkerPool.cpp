// USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
// Licensed under the MIT License. See LICENSE.txt for details.

#include "stdafx.h"
#include "ThumbnailWorkerPool.h"
#include "ProcessUtil.h"

#include <algorithm>
#include <chrono>

// ---------------------------------------------------------------------------
// JSON helpers (the protocol is small: flat objects, strings, integers)
// ---------------------------------------------------------------------------

std::string JsonEscape( LPCWSTR sText )
{
	static const char kHex[] = "0123456789abcdef";
	std::string escaped;

	// Walk UTF-16 code units: ASCII is copied (special characters escaped),
	// everything else becomes \uXXXX (surrogate pairs stay valid JSON).
	for( const wchar_t *p = sText; p && *p; ++p )
	{
		wchar_t c = *p;
		switch( c )
		{
		case L'"':  escaped += "\\\""; break;
		case L'\\': escaped += "\\\\"; break;
		case L'\n': escaped += "\\n";  break;
		case L'\r': escaped += "\\r";  break;
		case L'\t': escaped += "\\t";  break;
		default:
			if( c >= 0x20 && c < 0x7F )
			{
				escaped += static_cast<char>( c );
			}
			else
			{
				escaped += "\\u";
				escaped += kHex[( c >> 12 ) & 0xF];
				escaped += kHex[( c >> 8 ) & 0xF];
				escaped += kHex[( c >> 4 ) & 0xF];
				escaped += kHex[c & 0xF];
			}
			break;
		}
	}
	return escaped;
}

std::string BuildRenderRequest( long long id, LPCWSTR sUsdPath, LPCWSTR sOutputPath, int width, LPCWSTR sRenderer )
{
	std::string request = "{\"id\": " + std::to_string( id );
	request += ", \"usd\": \"" + JsonEscape( sUsdPath ) + "\"";
	request += ", \"out\": \"" + JsonEscape( sOutputPath ) + "\"";
	request += ", \"width\": " + std::to_string( width );
	request += ", \"renderer\": \"" + JsonEscape( sRenderer ? sRenderer : L"" ) + "\"}\n";
	return request;
}

// Position just after "key": (whitespace skipped), or npos.
static size_t FindJsonValue( const std::string &line, const char *key )
{
	std::string quotedKey = std::string( "\"" ) + key + "\"";
	size_t pos = line.find( quotedKey );
	if( pos == std::string::npos )
		return std::string::npos;
	pos = line.find( ':', pos + quotedKey.size() );
	if( pos == std::string::npos )
		return std::string::npos;
	return line.find_first_not_of( " \t", pos + 1 );
}

// Decode a JSON string literal starting at its opening quote.
static bool ReadJsonString( const std::string &line, size_t pos, std::wstring &value )
{
	if( pos == std::string::npos || pos >= line.size() || line[pos] != '"' )
		return false;

	std::string utf8;		// raw bytes are UTF-8; \u escapes are UTF-16
	std::wstring decoded;
	auto flush = [&]()
	{
		if( !utf8.empty() )
		{
			decoded += static_cast<LPCWSTR>( ATL::CA2W( utf8.c_str(), CP_UTF8 ) );
			utf8.clear();
		}
	};

	for( size_t i = pos + 1; i < line.size(); ++i )
	{
		char c = line[i];
		if( c == '"' )
		{
			flush();
			value = decoded;
			return true;
		}
		if( c != '\\' )
		{
			utf8 += c;
			continue;
		}
		if( ++i >= line.size() )
			return false;
		switch( line[i] )
		{
		case '"':  utf8 += '"';  break;
		case '\\': utf8 += '\\'; break;
		case '/':  utf8 += '/';  break;
		case 'n':  utf8 += '\n'; break;
		case 'r':  utf8 += '\r'; break;
		case 't':  utf8 += '\t'; break;
		case 'b':  utf8 += '\b'; break;
		case 'f':  utf8 += '\f'; break;
		case 'u':
			if( i + 4 >= line.size() )
				return false;
			flush();
			decoded += static_cast<wchar_t>( std::stoul( line.substr( i + 1, 4 ), nullptr, 16 ) );
			i += 4;
			break;
		default:
			return false;
		}
	}
	return false;	// no closing quote
}

bool ParseRenderResult( const std::string &line, ThumbnailResult &result )
{
	result = ThumbnailResult();

	size_t okPos = FindJsonValue( line, "ok" );
	if( okPos == std::string::npos )
		return false;
	if( line.compare( okPos, 4, "true" ) == 0 )
		result.ok = true;
	else if( line.compare( okPos, 5, "false" ) != 0 )
		return false;

	size_t idPos = FindJsonValue( line, "id" );
	if( idPos != std::string::npos && ( isdigit( static_cast<unsigned char>( line[idPos] ) ) || line[idPos] == '-' ) )
		result.id = std::stoll( line.substr( idPos ) );

	std::wstring error;
	if( ReadJsonString( line, FindJsonValue( line, "error" ), error ) )
		result.error = error.c_str();
	return true;
}

// ---------------------------------------------------------------------------
// Workers
// ---------------------------------------------------------------------------

struct CThumbnailWorkerPool::Worker
{
	CHandle hProcess;
	CHandle hInput;				// write end of the worker stdin
	CHandle hOutput;			// read end of the worker stdout
	DWORD processId = 0;
	unsigned renderCount = 0;
	ULONGLONG lastUsedTick = 0;
	bool bBusy = false;
	std::string pendingOutput;	// bytes read past the last complete line
};

CThumbnailWorkerPool::CThumbnailWorkerPool( const Settings &settings ) :
	m_settings( settings )
{
	// Every worker joins this job: when the pool's process ends (normally or
	// not) the job handle closes and Windows kills the workers.
	m_hJob.Attach( ::CreateJobObjectW( nullptr, nullptr ) );
	if( m_hJob )
	{
		JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {};
		limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
		::SetInformationJobObject( m_hJob, JobObjectExtendedLimitInformation, &limits, sizeof( limits ) );
	}

	m_idleThread = std::thread( [this]() { StopIdleWorkersLoop(); } );
}

CThumbnailWorkerPool::~CThumbnailWorkerPool()
{
	std::vector<std::unique_ptr<Worker>> workers;
	{
		std::lock_guard<std::mutex> guard( m_lock );
		m_bStopping = true;
		workers.swap( m_workers );
	}
	m_stopRequested.notify_all();
	if( m_idleThread.joinable() )
		m_idleThread.join();

	for( std::unique_ptr<Worker> &pWorker : workers )
		StopWorker( *pWorker, true );
	// m_hJob closes last and kills anything still running.
}

size_t CThumbnailWorkerPool::GetWorkerCount()
{
	std::lock_guard<std::mutex> guard( m_lock );
	return m_workers.size();
}

HRESULT CThumbnailWorkerPool::StartWorker( std::unique_ptr<Worker> &pWorker, CStringW &sError )
{
	pWorker = std::make_unique<Worker>();

	// Pipes: the child ends are inheritable, the pool ends are not.
	SECURITY_ATTRIBUTES sa = {};
	sa.nLength        = sizeof( sa );
	sa.bInheritHandle = TRUE;

	HANDLE hChildInput = nullptr, hInputWrite = nullptr;
	HANDLE hOutputRead = nullptr, hChildOutput = nullptr;
	if( !::CreatePipe( &hChildInput, &hInputWrite, &sa, 0 ) )
		return THUMBNAIL_E_WORKER_UNAVAILABLE;
	CHandle childInput( hChildInput );
	pWorker->hInput.Attach( hInputWrite );

	if( !::CreatePipe( &hOutputRead, &hChildOutput, &sa, 0 ) )
		return THUMBNAIL_E_WORKER_UNAVAILABLE;
	CHandle childOutput( hChildOutput );
	pWorker->hOutput.Attach( hOutputRead );

	::SetHandleInformation( pWorker->hInput, HANDLE_FLAG_INHERIT, 0 );
	::SetHandleInformation( pWorker->hOutput, HANDLE_FLAG_INHERIT, 0 );

	// stderr goes nowhere: a flood of USD warnings must never fill a pipe
	// nobody reads and block the worker.
	CHandle childError( ::CreateFileW( L"NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa,
	                                   OPEN_EXISTING, 0, nullptr ) );

	// Created suspended so it joins the job before running any code.
	PROCESS_INFORMATION pi;
	HRESULT hr = CreateChildProcess( m_settings.commandLine, ChildStdHandles{ childInput, childOutput, childError },
	                                 CREATE_NO_WINDOW | CREATE_SUSPENDED, pi );
	if( FAILED( hr ) )
	{
		sError.Format( L"cannot start thumbnail worker (0x%08X): %ls", hr, m_settings.commandLine.GetString() );
		return THUMBNAIL_E_WORKER_UNAVAILABLE;
	}

	if( m_hJob )
		::AssignProcessToJobObject( m_hJob, pi.hProcess );
	::ResumeThread( pi.hThread );
	::CloseHandle( pi.hThread );

	pWorker->hProcess.Attach( pi.hProcess );
	pWorker->processId = pi.dwProcessId;
	return S_OK;
	// The child ends of the pipes close here: the worker holds its own copies,
	// so its death closes the pipes and unblocks the reader.
}

HRESULT CThumbnailWorkerPool::Exchange( Worker &worker, long long id, const std::string &request,
                                        ThumbnailResult &result, CStringW &sError )
{
	// Send the request line.
	DWORD nWritten = 0;
	if( !::WriteFile( worker.hInput, request.data(), static_cast<DWORD>( request.size() ), &nWritten, nullptr ) ||
	    nWritten != request.size() )
	{
		sError = L"thumbnail worker exited before receiving the request";
		return HRESULT_FROM_WIN32( ERROR_BROKEN_PIPE );
	}

	// Read until one complete line. Anonymous pipes have no timeout: poll
	// the available bytes, the worker state and the deadline.
	ULONGLONG deadline = ::GetTickCount64() + m_settings.requestTimeoutMs;
	for( ;; )
	{
		size_t endOfLine = worker.pendingOutput.find( '\n' );
		if( endOfLine != std::string::npos )
		{
			std::string line = worker.pendingOutput.substr( 0, endOfLine );
			worker.pendingOutput.erase( 0, endOfLine + 1 );
			if( !ParseRenderResult( line, result ) || result.id != id )
			{
				sError.Format( L"thumbnail worker answered an invalid result: %hs", line.substr( 0, 200 ).c_str() );
				return HRESULT_FROM_WIN32( ERROR_BROKEN_PIPE );
			}
			return S_OK;
		}

		DWORD nAvailable = 0;
		if( !::PeekNamedPipe( worker.hOutput, nullptr, 0, nullptr, &nAvailable, nullptr ) )
		{
			sError = L"thumbnail worker exited during the render";
			return HRESULT_FROM_WIN32( ERROR_BROKEN_PIPE );
		}

		if( nAvailable > 0 )
		{
			char buffer[4096];
			DWORD nRead = 0;
			if( ::ReadFile( worker.hOutput, buffer, (std::min)( nAvailable, static_cast<DWORD>( sizeof( buffer ) ) ), &nRead, nullptr ) )
				worker.pendingOutput.append( buffer, nRead );
			continue;
		}

		if( ::GetTickCount64() >= deadline )
		{
			sError.Format( L"thumbnail worker did not answer within %lu s", m_settings.requestTimeoutMs / 1000 );
			return HRESULT_FROM_WIN32( ERROR_TIMEOUT );
		}
		::Sleep( 2 );
	}
}

void CThumbnailWorkerPool::StopWorker( Worker &worker, bool bGraceful )
{
	if( bGraceful && worker.hInput )
	{
		// Ask politely, then close stdin (end of input also stops it).
		static const char kExit[] = "{\"cmd\": \"exit\"}\n";
		DWORD nWritten = 0;
		::WriteFile( worker.hInput, kExit, sizeof( kExit ) - 1, &nWritten, nullptr );
	}
	worker.hInput.Close();

	if( worker.hProcess )
	{
		if( !bGraceful || ::WaitForSingleObject( worker.hProcess, 2000 ) != WAIT_OBJECT_0 )
		{
			::TerminateProcess( worker.hProcess, 1 );
			::WaitForSingleObject( worker.hProcess, 2000 );
		}
	}
	worker.hOutput.Close();
	worker.hProcess.Close();
}

HRESULT CThumbnailWorkerPool::Render( LPCWSTR sUsdPath, LPCWSTR sOutputPath, int width, LPCWSTR sRenderer, CStringW &sError )
{
	sError.Empty();
	Worker *pWorker = nullptr;
	long long id = 0;

	// --- Take an idle worker, start a new one, or wait for one to free up ---
	{
		std::unique_lock<std::mutex> lock( m_lock );
		auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds( m_settings.slotTimeoutMs );
		for( ;; )
		{
			for( std::unique_ptr<Worker> &pCandidate : m_workers )
			{
				if( !pCandidate->bBusy )
				{
					pWorker = pCandidate.get();
					break;
				}
			}
			if( pWorker != nullptr )
				break;

			if( m_workers.size() + m_startingWorkers < m_settings.maxWorkers )
			{
				// Reserve the slot, start the process without holding the lock.
				++m_startingWorkers;
				lock.unlock();
				std::unique_ptr<Worker> pNewWorker;
				HRESULT hr = StartWorker( pNewWorker, sError );
				lock.lock();
				--m_startingWorkers;
				if( FAILED( hr ) )
				{
					m_workerFreed.notify_one();
					return hr;
				}
				pWorker = pNewWorker.get();
				m_workers.push_back( std::move( pNewWorker ) );
				break;
			}

			if( m_workerFreed.wait_until( lock, deadline ) == std::cv_status::timeout )
			{
				sError.Format( L"no thumbnail worker free within %lu s", m_settings.slotTimeoutMs / 1000 );
				return HRESULT_FROM_WIN32( ERROR_BUSY );
			}
		}
		pWorker->bBusy = true;
		id = m_nextRequestId++;
	}

	// --- Render on the worker, without holding the lock ---
	ThumbnailResult result;
	HRESULT hr = Exchange( *pWorker, id, BuildRenderRequest( id, sUsdPath, sOutputPath, width, sRenderer ), result, sError );
	if( SUCCEEDED( hr ) && !result.ok )
	{
		sError = result.error;
		hr = E_FAIL;
	}

	// --- Give the worker back, or retire it ---
	// A worker that timed out, died or answered garbage is discarded; one
	// that reached its render limit is recycled (bounded memory growth).
	std::unique_ptr<Worker> pRetired;
	bool bGraceful = false;
	{
		std::lock_guard<std::mutex> guard( m_lock );
		pWorker->renderCount += ( hr == S_OK || hr == E_FAIL ) ? 1 : 0;
		pWorker->lastUsedTick = ::GetTickCount64();
		pWorker->bBusy = false;

		bool bBroken = hr != S_OK && hr != E_FAIL;
		bool bWornOut = pWorker->renderCount >= m_settings.maxRendersPerWorker;
		if( bBroken || bWornOut )
		{
			for( auto it = m_workers.begin(); it != m_workers.end(); ++it )
			{
				if( it->get() == pWorker )
				{
					pRetired = std::move( *it );
					m_workers.erase( it );
					break;
				}
			}
			bGraceful = !bBroken;
		}
	}
	m_workerFreed.notify_one();

	if( pRetired )
		StopWorker( *pRetired, bGraceful );
	return hr;
}

void CThumbnailWorkerPool::StopIdleWorkersLoop()
{
	// Check a few times per idle period, stop workers unused for too long.
	auto checkPeriod = std::chrono::milliseconds( (std::max)( 50UL, (std::min)( 1000UL, m_settings.idleTimeoutMs / 4 ) ) );

	std::unique_lock<std::mutex> lock( m_lock );
	while( !m_bStopping )
	{
		m_stopRequested.wait_for( lock, checkPeriod );
		if( m_bStopping )
			break;

		std::vector<std::unique_ptr<Worker>> idleWorkers;
		ULONGLONG now = ::GetTickCount64();
		for( auto it = m_workers.begin(); it != m_workers.end(); )
		{
			if( !( *it )->bBusy && now - ( *it )->lastUsedTick >= m_settings.idleTimeoutMs )
			{
				idleWorkers.push_back( std::move( *it ) );
				it = m_workers.erase( it );
			}
			else
			{
				++it;
			}
		}

		if( !idleWorkers.empty() )
		{
			lock.unlock();
			for( std::unique_ptr<Worker> &pWorker : idleWorkers )
				StopWorker( *pWorker, true );
			lock.lock();
		}
	}
}
