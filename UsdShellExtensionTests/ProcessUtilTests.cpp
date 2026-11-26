// USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
// Licensed under the MIT License. See LICENSE.txt for details.

// Tests for shared/ProcessUtil: semaphore slots, unique temp files and
// child process execution, the building blocks of thumbnail rendering.

#include "stdafx.h"
#include "shared/ProcessUtil.h"

#include <set>
#include <thread>

using namespace Microsoft::VisualStudio::CppUnitTestFramework;

namespace
{
	// Return %TEMP% without the trailing backslash.
	CStringW GetTempDir()
	{
		wchar_t sTempPath[MAX_PATH];
		::GetTempPathW( ARRAYSIZE( sTempPath ), sTempPath );
		CStringW sDir = sTempPath;
		sDir.TrimRight( L'\\' );
		return sDir;
	}

	bool FileExists( const CStringW &sPath )
	{
		return ::GetFileAttributesW( sPath ) != INVALID_FILE_ATTRIBUTES;
	}

	// True when the semaphore has a free slot right now (the probe slot is
	// given back immediately).
	bool HasFreeSlot( HANDLE hSemaphore )
	{
		if( ::WaitForSingleObject( hSemaphore, 0 ) != WAIT_OBJECT_0 )
			return false;
		::ReleaseSemaphore( hSemaphore, 1, nullptr );
		return true;
	}
}

TEST_CLASS( SemaphoreSlotTests )
{
	CHandle m_hSemaphore;

public:
	TEST_METHOD_INITIALIZE( CreateSemaphore )
	{
		// One slot only: easy to observe taken / free.
		m_hSemaphore.Attach( ::CreateSemaphoreW( nullptr, 1, 1, nullptr ) );
	}

	TEST_METHOD( AcquiresAFreeSlotAndReleasesItOnDestruction )
	{
		{
			CSemaphoreSlot slot;
			Assert::IsTrue( slot.Acquire( m_hSemaphore, 0 ) );
			Assert::IsTrue( slot.IsAcquired() );
			Assert::IsFalse( HasFreeSlot( m_hSemaphore ) );
		}
		Assert::IsTrue( HasFreeSlot( m_hSemaphore ) );
	}

	TEST_METHOD( GivesUpAfterTheTimeoutWhenNoSlotIsFree )
	{
		CSemaphoreSlot holder;
		holder.Acquire( m_hSemaphore, 0 );

		ULONGLONG start = ::GetTickCount64();
		CSemaphoreSlot waiter;
		bool bAcquired = waiter.Acquire( m_hSemaphore, 100 );
		ULONGLONG elapsed = ::GetTickCount64() - start;

		Assert::IsFalse( bAcquired );
		Assert::IsFalse( waiter.IsAcquired() );
		Assert::IsTrue( elapsed >= 90 && elapsed < 2000, L"waited for the timeout only" );
	}

	TEST_METHOD( FailedAcquireDoesNotReleaseAnotherOwnersSlot )
	{
		CSemaphoreSlot holder;
		holder.Acquire( m_hSemaphore, 0 );
		{
			CSemaphoreSlot waiter;
			waiter.Acquire( m_hSemaphore, 0 );
		}
		// The failed waiter must not have "returned" the holder's slot.
		Assert::IsFalse( HasFreeSlot( m_hSemaphore ) );
	}

	TEST_METHOD( NullSemaphoreIsNotAcquired )
	{
		CSemaphoreSlot slot;
		Assert::IsFalse( slot.Acquire( nullptr, 0 ) );
	}
};

TEST_CLASS( UniqueTempFileTests )
{
public:
	TEST_METHOD( CreatesAnEmptyFileWithPrefixAndExtension )
	{
		CUniqueTempFile file;
		Assert::AreEqual( S_OK, file.Create( GetTempDir(), L"UsdTest", L"py" ) );

		Assert::IsTrue( FileExists( file.GetPath() ) );
		Assert::IsTrue( file.GetPath().Find( L"\\UsdTest" ) > 0 );
		Assert::IsTrue( file.GetPath().Right( 3 ) == L".py" );
	}

	TEST_METHOD( DeletesTheFileOnDestruction )
	{
		CStringW sPath;
		{
			CUniqueTempFile file;
			file.Create( GetTempDir(), L"UsdTest", L"log" );
			sPath = file.GetPath();
			Assert::IsTrue( FileExists( sPath ) );
		}
		Assert::IsFalse( FileExists( sPath ) );
	}

	TEST_METHOD( WritesThenReadsBackContent )
	{
		CUniqueTempFile file;
		file.Create( GetTempDir(), L"UsdTest", L"py" );

		const char content[] = "print('hello')\n";
		Assert::AreEqual( S_OK, file.Write( content, static_cast<DWORD>( strlen( content ) ) ) );

		Assert::AreEqual( "print('hello')\n", file.ReadAll().GetString() );
	}

	TEST_METHOD( ConcurrentCreationsNeverShareAPath )
	{
		// Regression for the thumbnail race: parallel renders used to
		// rewrite the same %TEMP%\UsdThumbnailScript.py.
		constexpr int kThreads = 16;
		std::vector<CUniqueTempFile> files( kThreads );
		std::vector<HRESULT> results( kThreads, E_FAIL );
		std::vector<std::thread> threads;
		CStringW sTempDir = GetTempDir();

		for( int index = 0; index < kThreads; ++index )
		{
			threads.emplace_back( [&, index]()
			{
				const char content[] = "x";
				results[index] = files[index].Create( sTempDir, L"UsdTest", L"py" );
				if( SUCCEEDED( results[index] ) )
					results[index] = files[index].Write( content, 1 );
			} );
		}
		for( std::thread &thread : threads )
			thread.join();

		std::set<std::wstring> paths;
		for( int index = 0; index < kThreads; ++index )
		{
			Assert::AreEqual( S_OK, results[index] );
			paths.insert( files[index].GetPath().GetString() );
		}
		Assert::AreEqual( static_cast<size_t>( kThreads ), paths.size() );
	}

	TEST_METHOD( DetachKeepsTheFileAndHandsOverItsPath )
	{
		// Used for the thumbnail image: kept on success, owned by the caller.
		CStringW sPath;
		{
			CUniqueTempFile file;
			file.Create( GetTempDir(), L"UsdTest", L"png" );
			sPath = file.Detach();
			Assert::IsTrue( file.GetPath().IsEmpty() );
		}
		Assert::IsTrue( FileExists( sPath ) );
		::DeleteFileW( sPath );
	}

	TEST_METHOD( CreateFailsInAMissingDirectory )
	{
		CUniqueTempFile file;
		Assert::IsTrue( FAILED( file.Create( L"Z:\\no\\such\\dir", L"UsdTest", L"py" ) ) );
		Assert::IsTrue( file.GetPath().IsEmpty() );
	}
};

TEST_CLASS( RunProcessAndWaitTests )
{
public:
	TEST_METHOD( ReturnsTheChildExitCode )
	{
		DWORD exitCode = 0;
		HRESULT hr = RunProcessAndWait( L"cmd.exe /c exit 3", nullptr, 10000, exitCode );

		Assert::AreEqual( S_OK, hr );
		Assert::AreEqual( 3UL, exitCode );
	}

	TEST_METHOD( RedirectsOutputToTheGivenFile )
	{
		CUniqueTempFile log;
		log.Create( GetTempDir(), L"UsdTest", L"log" );
		CHandle hLog( OpenInheritableForWrite( log.GetPath() ) );
		Assert::IsTrue( hLog != nullptr );

		DWORD exitCode = 1;
		HRESULT hr = RunProcessAndWait( L"cmd.exe /c echo hello", hLog, 10000, exitCode );
		hLog.Close();

		Assert::AreEqual( S_OK, hr );
		Assert::AreEqual( 0UL, exitCode );
		Assert::IsTrue( log.ReadAll().Find( "hello" ) >= 0 );
	}

	TEST_METHOD( KillsTheChildAfterTheTimeout )
	{
		ULONGLONG start = ::GetTickCount64();
		DWORD exitCode = 0;
		// ping waits about 1 s per echo: 10 s if not killed.
		HRESULT hr = RunProcessAndWait( L"cmd.exe /c ping -n 11 127.0.0.1", nullptr, 300, exitCode );
		ULONGLONG elapsed = ::GetTickCount64() - start;

		Assert::AreEqual( HRESULT_FROM_WIN32( ERROR_TIMEOUT ), hr );
		Assert::IsTrue( elapsed < 5000, L"returned soon after the timeout" );
	}

	TEST_METHOD( ReportsAMissingExecutable )
	{
		DWORD exitCode = 0;
		HRESULT hr = RunProcessAndWait( L"\"C:\\no\\such\\tool.exe\"", nullptr, 1000, exitCode );

		Assert::IsTrue( FAILED( hr ) );
		Assert::AreNotEqual( HRESULT_FROM_WIN32( ERROR_TIMEOUT ), hr );
	}
};
