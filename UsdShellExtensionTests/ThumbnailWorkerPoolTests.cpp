// USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
// Licensed under the MIT License. See LICENSE.txt for details.

// Tests for shared/ThumbnailWorkerPool: the pool of warm thumbnail workers,
// driven with fake_worker.py (same protocol, no USD, no OpenGL).

#include "stdafx.h"
#include "shared/ThumbnailWorkerPool.h"
#include "shared/ProcessUtil.h"

#include <atomic>
#include <set>
#include <thread>

using namespace Microsoft::VisualStudio::CppUnitTestFramework;

namespace
{
	// Python of the SDK and the fake worker, set by the project file.
	CStringW FakeWorkerCommandLine()
	{
		CStringW sCommandLine;
		sCommandLine.Format( L"\"%lspython.exe\" -u \"%lsfake_worker.py\"", TEST_PYTHON_HOME, TEST_SOURCE_DIR );
		return sCommandLine;
	}

	CThumbnailWorkerPool::Settings FastSettings()
	{
		CThumbnailWorkerPool::Settings settings;
		settings.commandLine = FakeWorkerCommandLine();
		settings.maxWorkers = 3;
		settings.requestTimeoutMs = 10000;
		settings.slotTimeoutMs = 10000;
		settings.maxRendersPerWorker = 50;
		settings.idleTimeoutMs = 60000;
		return settings;
	}

	CStringW TempDir()
	{
		wchar_t sTempPath[MAX_PATH];
		::GetTempPathW( ARRAYSIZE( sTempPath ), sTempPath );
		CStringW sDir = sTempPath;
		sDir.TrimRight( L'\\' );
		return sDir;
	}

	// What the fake worker wrote into the "image": pid, count, usd path.
	struct FakeImage
	{
		DWORD pid = 0;
		int count = 0;
		std::wstring usd;
	};

	FakeImage ReadFakeImage( const CStringW &sPath )
	{
		FakeImage image;
		CHandle hFile( ::CreateFileW( sPath, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, 0, nullptr ) );
		if( hFile == INVALID_HANDLE_VALUE )
		{
			hFile.Detach();
			return image;
		}
		char buffer[4096] = {};
		DWORD nRead = 0;
		::ReadFile( hFile, buffer, sizeof( buffer ) - 1, &nRead, nullptr );
		std::string text( buffer, nRead );

		unsigned long pid = 0;
		int count = 0;
		sscanf_s( text.c_str(), "pid=%lu count=%d", &pid, &count );
		image.pid = pid;
		image.count = count;
		size_t usdPos = text.find( "usd=" );
		if( usdPos != std::string::npos )
			image.usd = static_cast<LPCWSTR>( ATL::CA2W( text.substr( usdPos + 4 ).c_str(), CP_UTF8 ) );
		return image;
	}

	bool IsProcessAlive( DWORD pid )
	{
		HANDLE hProcess = ::OpenProcess( SYNCHRONIZE, FALSE, pid );
		if( hProcess == nullptr )
			return false;
		bool bAlive = ::WaitForSingleObject( hProcess, 0 ) == WAIT_TIMEOUT;
		::CloseHandle( hProcess );
		return bAlive;
	}

	// Wait up to timeoutMs for a process to end.
	bool WaitProcessGone( DWORD pid, DWORD timeoutMs )
	{
		HANDLE hProcess = ::OpenProcess( SYNCHRONIZE, FALSE, pid );
		if( hProcess == nullptr )
			return true;
		bool bGone = ::WaitForSingleObject( hProcess, timeoutMs ) == WAIT_OBJECT_0;
		::CloseHandle( hProcess );
		return bGone;
	}

	// Render one fake thumbnail into a unique temp file; returns what the
	// fake worker wrote (pid 0 when nothing was written).
	HRESULT RenderFake( CThumbnailWorkerPool &pool, LPCWSTR sUsd, FakeImage &image, CStringW &sError )
	{
		CUniqueTempFile out;
		out.Create( TempDir(), L"UsdTestImage", L"png" );
		HRESULT hr = pool.Render( sUsd, out.GetPath(), 256, L"", sError );
		image = ReadFakeImage( out.GetPath() );
		return hr;
	}
}

TEST_CLASS( ThumbnailJsonTests )
{
public:
	TEST_METHOD( EscapesWindowsPathsQuotesAndControlCharacters )
	{
		Assert::AreEqual( std::string( "C:\\\\a b\\\\\\\"q\\\".usd" ), JsonEscape( L"C:\\a b\\\"q\".usd" ) );
		Assert::AreEqual( std::string( "line\\nnext\\ttab" ), JsonEscape( L"line\nnext\ttab" ) );
		Assert::AreEqual( std::string( "\\u0001" ), JsonEscape( L"\x01" ) );
	}

	TEST_METHOD( EscapesNonAsciiSoTheProtocolIgnoresCodePages )
	{
		// Python reads a pipe with the locale code page (cp1252), not UTF-8:
		// an ASCII-only protocol is decoded the same way everywhere.
		Assert::AreEqual( std::string( "sc\\u00e8ne" ), JsonEscape( L"sc\u00E8ne" ) );
		Assert::AreEqual( std::string( "\\ud83d\\ude00" ), JsonEscape( L"\U0001F600" ) );
	}

	TEST_METHOD( BuildsARequestLine )
	{
		std::string line = BuildRenderRequest( 7, L"C:\\a.usd", L"C:\\a.png", 128, L"GL" );
		Assert::AreEqual( std::string( "{\"id\": 7, \"usd\": \"C:\\\\a.usd\", \"out\": \"C:\\\\a.png\", \"width\": 128, \"renderer\": \"GL\"}\n" ), line );
	}

	TEST_METHOD( ParsesASuccessfulResult )
	{
		ThumbnailResult result;
		Assert::IsTrue( ParseRenderResult( "{\"id\": 7, \"ok\": true, \"error\": \"\"}", result ) );
		Assert::AreEqual( 7LL, result.id );
		Assert::IsTrue( result.ok );
		Assert::IsTrue( result.error.IsEmpty() );
	}

	TEST_METHOD( ParsesAFailureWithAnEscapedMessage )
	{
		ThumbnailResult result;
		Assert::IsTrue( ParseRenderResult( "{\"id\": 3, \"ok\": false, \"error\": \"bad \\\"file\\\"\\n@C:\\\\a.usd@ \\u00e8\"}", result ) );
		Assert::IsFalse( result.ok );
		Assert::AreEqual( L"bad \"file\"\n@C:\\a.usd@ \u00E8", result.error.GetString() );
	}

	TEST_METHOD( RejectsLinesThatAreNotResults )
	{
		ThumbnailResult result;
		Assert::IsFalse( ParseRenderResult( "this is not json", result ) );
		Assert::IsFalse( ParseRenderResult( "{\"id\": 1, \"error\": \"\"}", result ) );	// no "ok"
	}
};

TEST_CLASS( ThumbnailWorkerPoolTests )
{
public:
	TEST_METHOD( RendersThroughAWarmWorkerAndReusesIt )
	{
		CThumbnailWorkerPool pool( FastSettings() );
		FakeImage first, second;
		CStringW sError;

		Assert::AreEqual( S_OK, RenderFake( pool, L"C:\\scenes\\a.usda", first, sError ) );
		Assert::AreEqual( S_OK, RenderFake( pool, L"C:\\scenes\\b.usda", second, sError ) );

		Assert::IsTrue( first.pid != 0 );
		Assert::AreEqual( first.pid, second.pid, L"same warm worker" );
		Assert::AreEqual( 2, second.count );
		Assert::AreEqual( size_t( 1 ), pool.GetWorkerCount() );
	}

	TEST_METHOD( PassesPathsUnchanged )
	{
		CThumbnailWorkerPool pool( FastSettings() );
		FakeImage image;
		CStringW sError;

		Assert::AreEqual( S_OK, RenderFake( pool, L"D:\\Projets \"2026\"\\sc\u00E8ne #1.usda", image, sError ) );
		Assert::AreEqual( std::wstring( L"D:\\Projets \"2026\"\\sc\u00E8ne #1.usda" ), image.usd );
	}

	TEST_METHOD( ReportsARenderFailureAndKeepsTheWorker )
	{
		CThumbnailWorkerPool pool( FastSettings() );
		FakeImage failed, next;
		CStringW sError;

		Assert::AreEqual( E_FAIL, RenderFake( pool, L"C:\\fail.usda", failed, sError ) );
		Assert::AreEqual( L"fake failure", sError.GetString() );

		Assert::AreEqual( S_OK, RenderFake( pool, L"C:\\ok.usda", next, sError ) );
		Assert::AreEqual( 2, next.count, L"the same worker handled both" );
	}

	TEST_METHOD( KillsAHungWorkerAfterTheTimeout )
	{
		CThumbnailWorkerPool::Settings settings = FastSettings();
		settings.requestTimeoutMs = 800;
		CThumbnailWorkerPool pool( settings );
		FakeImage image;
		CStringW sError;

		// Warm a worker first and note its pid.
		RenderFake( pool, L"C:\\warm.usda", image, sError );
		DWORD hungPid = image.pid;

		ULONGLONG start = ::GetTickCount64();
		HRESULT hr = RenderFake( pool, L"C:\\hang.usda", image, sError );
		ULONGLONG elapsed = ::GetTickCount64() - start;

		Assert::AreEqual( HRESULT_FROM_WIN32( ERROR_TIMEOUT ), hr );
		Assert::IsTrue( elapsed < 4000, L"returned soon after the timeout" );
		Assert::IsTrue( WaitProcessGone( hungPid, 5000 ), L"hung worker killed" );
		Assert::AreEqual( size_t( 0 ), pool.GetWorkerCount() );

		Assert::AreEqual( S_OK, RenderFake( pool, L"C:\\after.usda", image, sError ) );
		Assert::AreNotEqual( hungPid, image.pid );
	}

	TEST_METHOD( ReplacesACrashedWorker )
	{
		CThumbnailWorkerPool pool( FastSettings() );
		FakeImage image;
		CStringW sError;

		RenderFake( pool, L"C:\\warm.usda", image, sError );
		DWORD crashedPid = image.pid;

		Assert::AreEqual( HRESULT_FROM_WIN32( ERROR_BROKEN_PIPE ), RenderFake( pool, L"C:\\crash.usda", image, sError ) );
		Assert::AreEqual( size_t( 0 ), pool.GetWorkerCount() );

		Assert::AreEqual( S_OK, RenderFake( pool, L"C:\\after.usda", image, sError ) );
		Assert::AreNotEqual( crashedPid, image.pid );
	}

	TEST_METHOD( ReplacesAWorkerThatAnswersGarbage )
	{
		CThumbnailWorkerPool pool( FastSettings() );
		FakeImage image;
		CStringW sError;

		Assert::AreEqual( HRESULT_FROM_WIN32( ERROR_BROKEN_PIPE ), RenderFake( pool, L"C:\\badjson.usda", image, sError ) );
		Assert::AreEqual( size_t( 0 ), pool.GetWorkerCount() );
		Assert::AreEqual( S_OK, RenderFake( pool, L"C:\\after.usda", image, sError ) );
	}

	TEST_METHOD( RecyclesAWorkerAfterItsRenderLimit )
	{
		CThumbnailWorkerPool::Settings settings = FastSettings();
		settings.maxRendersPerWorker = 3;
		CThumbnailWorkerPool pool( settings );
		FakeImage image;
		CStringW sError;

		RenderFake( pool, L"C:\\1.usda", image, sError );
		DWORD firstPid = image.pid;
		RenderFake( pool, L"C:\\2.usda", image, sError );
		RenderFake( pool, L"C:\\3.usda", image, sError );
		Assert::AreEqual( firstPid, image.pid );

		Assert::IsTrue( WaitProcessGone( firstPid, 5000 ), L"retired after 3 renders" );
		RenderFake( pool, L"C:\\4.usda", image, sError );
		Assert::AreNotEqual( firstPid, image.pid );
		Assert::AreEqual( 1, image.count );
	}

	TEST_METHOD( RunsUpToMaxWorkersInParallel )
	{
		CThumbnailWorkerPool::Settings settings = FastSettings();
		settings.maxWorkers = 2;
		CThumbnailWorkerPool pool( settings );

		// 4 renders of 600 ms on 2 workers: about 2 rounds.
		constexpr int kRenders = 4;
		std::vector<FakeImage> images( kRenders );
		std::vector<HRESULT> results( kRenders, E_FAIL );
		std::vector<std::thread> threads;
		ULONGLONG start = ::GetTickCount64();
		for( int index = 0; index < kRenders; ++index )
		{
			threads.emplace_back( [&, index]()
			{
				CStringW sError;
				results[index] = RenderFake( pool, L"C:\\slow:600.usda", images[index], sError );
			} );
		}
		for( std::thread &thread : threads )
			thread.join();
		ULONGLONG elapsed = ::GetTickCount64() - start;

		std::set<DWORD> pids;
		for( int index = 0; index < kRenders; ++index )
		{
			Assert::AreEqual( S_OK, results[index] );
			pids.insert( images[index].pid );
		}
		Assert::AreEqual( size_t( 2 ), pids.size(), L"never more than 2 workers" );
		Assert::IsTrue( elapsed >= 1100 && elapsed < 2400, L"two rounds of 600 ms in parallel" );
	}

	TEST_METHOD( GivesUpWhenNoWorkerFreesInTime )
	{
		CThumbnailWorkerPool::Settings settings = FastSettings();
		settings.maxWorkers = 1;
		settings.slotTimeoutMs = 300;
		CThumbnailWorkerPool pool( settings );

		std::thread busy( [&]()
		{
			FakeImage image;
			CStringW sError;
			RenderFake( pool, L"C:\\slow:1500.usda", image, sError );
		} );
		::Sleep( 300 );	// let the busy render take the only worker

		FakeImage image;
		CStringW sError;
		HRESULT hr = RenderFake( pool, L"C:\\waiting.usda", image, sError );
		busy.join();

		Assert::AreEqual( HRESULT_FROM_WIN32( ERROR_BUSY ), hr );
	}

	TEST_METHOD( StopsWorkersAfterTheIdleTimeout )
	{
		CThumbnailWorkerPool::Settings settings = FastSettings();
		settings.idleTimeoutMs = 300;
		CThumbnailWorkerPool pool( settings );
		FakeImage image;
		CStringW sError;

		RenderFake( pool, L"C:\\a.usda", image, sError );
		Assert::IsTrue( IsProcessAlive( image.pid ) );

		Assert::IsTrue( WaitProcessGone( image.pid, 5000 ), L"idle worker stopped" );
		Assert::AreEqual( size_t( 0 ), pool.GetWorkerCount() );
	}

	TEST_METHOD( KillsItsWorkersWhenDestroyed )
	{
		FakeImage image;
		{
			CThumbnailWorkerPool pool( FastSettings() );
			CStringW sError;
			RenderFake( pool, L"C:\\a.usda", image, sError );
			Assert::IsTrue( IsProcessAlive( image.pid ) );
		}
		Assert::IsTrue( WaitProcessGone( image.pid, 5000 ), L"no orphan worker" );
	}

	TEST_METHOD( ReportsAWorkerThatCannotStart )
	{
		CThumbnailWorkerPool::Settings settings = FastSettings();
		settings.commandLine = L"\"C:\\no\\such\\python.exe\" worker.py";
		CThumbnailWorkerPool pool( settings );
		FakeImage image;
		CStringW sError;

		Assert::AreEqual( THUMBNAIL_E_WORKER_UNAVAILABLE, RenderFake( pool, L"C:\\a.usda", image, sError ) );
		Assert::IsFalse( sError.IsEmpty() );
	}
};
