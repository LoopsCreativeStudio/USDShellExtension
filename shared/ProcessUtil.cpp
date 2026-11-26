// USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
// Licensed under the MIT License. See LICENSE.txt for details.

#include "stdafx.h"
#include "ProcessUtil.h"

#include <vector>

// ---------------------------------------------------------------------------
// CSemaphoreSlot
// ---------------------------------------------------------------------------
CSemaphoreSlot::~CSemaphoreSlot()
{
	// Give the slot back only if this object actually took it.
	if( m_hSemaphore != nullptr )
		::ReleaseSemaphore( m_hSemaphore, 1, nullptr );
}

bool CSemaphoreSlot::Acquire( HANDLE hSemaphore, DWORD timeoutMs )
{
	if( hSemaphore == nullptr || m_hSemaphore != nullptr )
		return false;

	// Remember the semaphore only on success, so a timed out wait never
	// releases a slot owned by someone else.
	if( ::WaitForSingleObject( hSemaphore, timeoutMs ) != WAIT_OBJECT_0 )
		return false;

	m_hSemaphore = hSemaphore;
	return true;
}

// ---------------------------------------------------------------------------
// CUniqueTempFile
// ---------------------------------------------------------------------------
CUniqueTempFile::~CUniqueTempFile()
{
	if( !m_sPath.IsEmpty() )
		::DeleteFileW( m_sPath );
}

HRESULT CUniqueTempFile::Create( LPCWSTR sDirectory, LPCWSTR sPrefix, LPCWSTR sExtension )
{
	// A GUID makes the name unique across threads and processes.
	GUID guid;
	HRESULT hr = ::CoCreateGuid( &guid );
	if( FAILED( hr ) )
		return hr;

	wchar_t sGuid[64];
	::StringFromGUID2( guid, sGuid, ARRAYSIZE( sGuid ) );
	CStringW sName = sGuid;
	sName.Trim( L"{}" );

	CStringW sPath;
	sPath.Format( L"%ls\\%ls%ls.%ls", sDirectory, sPrefix, sName.GetString(), sExtension );

	// CREATE_NEW fails instead of reusing an existing file.
	CHandle hFile( ::CreateFileW( sPath, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr,
	                              CREATE_NEW, FILE_ATTRIBUTE_TEMPORARY, nullptr ) );
	if( hFile == INVALID_HANDLE_VALUE )
	{
		hFile.Detach();
		return HRESULT_FROM_WIN32( ::GetLastError() );
	}

	m_sPath = sPath;
	return S_OK;
}

HRESULT CUniqueTempFile::Write( const void *pData, DWORD nSize )
{
	if( m_sPath.IsEmpty() )
		return E_UNEXPECTED;

	CHandle hFile( ::CreateFileW( m_sPath, GENERIC_WRITE, FILE_SHARE_READ, nullptr,
	                              TRUNCATE_EXISTING, FILE_ATTRIBUTE_TEMPORARY, nullptr ) );
	if( hFile == INVALID_HANDLE_VALUE )
	{
		hFile.Detach();
		return HRESULT_FROM_WIN32( ::GetLastError() );
	}

	DWORD nWritten = 0;
	if( !::WriteFile( hFile, pData, nSize, &nWritten, nullptr ) )
		return HRESULT_FROM_WIN32( ::GetLastError() );

	// A short write would leave a truncated script behind.
	return nWritten == nSize ? S_OK : HRESULT_FROM_WIN32( ERROR_WRITE_FAULT );
}

CStringA CUniqueTempFile::ReadAll() const
{
	CStringA sContent;
	if( m_sPath.IsEmpty() )
		return sContent;

	// Share write: a child process may still hold the file open.
	CHandle hFile( ::CreateFileW( m_sPath, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
	                              nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr ) );
	if( hFile == INVALID_HANDLE_VALUE )
	{
		hFile.Detach();
		return sContent;
	}

	LARGE_INTEGER size = {};
	if( !::GetFileSizeEx( hFile, &size ) || size.QuadPart <= 0 || size.QuadPart > MAXDWORD / 2 )
		return sContent;

	DWORD nSize = static_cast<DWORD>( size.QuadPart );
	LPSTR pBuffer = sContent.GetBufferSetLength( static_cast<int>( nSize ) );
	DWORD nRead = 0;
	::ReadFile( hFile, pBuffer, nSize, &nRead, nullptr );
	sContent.ReleaseBuffer( static_cast<int>( nRead ) );
	return sContent;
}

// ---------------------------------------------------------------------------
// Child processes
// ---------------------------------------------------------------------------
HANDLE OpenInheritableForWrite( LPCWSTR sPath )
{
	SECURITY_ATTRIBUTES sa = {};
	sa.nLength        = sizeof( sa );
	sa.bInheritHandle = TRUE;

	HANDLE hFile = ::CreateFileW( sPath, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_DELETE, &sa,
	                              CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, nullptr );
	return hFile == INVALID_HANDLE_VALUE ? nullptr : hFile;
}

HRESULT RunProcessAndWait( LPCWSTR sCommandLine, HANDLE hStdOutErr, DWORD timeoutMs, DWORD &exitCode )
{
	exitCode = 0;

	// CreateProcessW may modify the command line: work on a private copy.
	CStringW sCommandLineCopy = sCommandLine;

	STARTUPINFOEXW si = {};
	si.StartupInfo.cb = sizeof( si );
	DWORD creationFlags = CREATE_NO_WINDOW;
	BOOL bInheritHandles = FALSE;

	// When redirecting, restrict inheritance to the output handle only:
	// otherwise the child would also inherit the logs of renders running in
	// parallel threads and keep them open.
	std::vector<BYTE> attributeListBuffer;
	LPPROC_THREAD_ATTRIBUTE_LIST pAttributeList = nullptr;
	HANDLE handlesToInherit[] = { hStdOutErr };

	if( hStdOutErr != nullptr )
	{
		SIZE_T nAttributeListSize = 0;
		::InitializeProcThreadAttributeList( nullptr, 1, 0, &nAttributeListSize );
		attributeListBuffer.resize( nAttributeListSize );
		pAttributeList = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>( attributeListBuffer.data() );

		if( !::InitializeProcThreadAttributeList( pAttributeList, 1, 0, &nAttributeListSize ) )
			return HRESULT_FROM_WIN32( ::GetLastError() );

		if( !::UpdateProcThreadAttribute( pAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
		                                  handlesToInherit, sizeof( handlesToInherit ), nullptr, nullptr ) )
		{
			DWORD err = ::GetLastError();
			::DeleteProcThreadAttributeList( pAttributeList );
			return HRESULT_FROM_WIN32( err );
		}

		si.StartupInfo.dwFlags    = STARTF_USESTDHANDLES;
		si.StartupInfo.hStdInput  = nullptr;
		si.StartupInfo.hStdOutput = hStdOutErr;
		si.StartupInfo.hStdError  = hStdOutErr;
		si.lpAttributeList        = pAttributeList;
		creationFlags            |= EXTENDED_STARTUPINFO_PRESENT;
		bInheritHandles           = TRUE;
	}

	PROCESS_INFORMATION pi = {};
	BOOL bCreated = ::CreateProcessW( nullptr, sCommandLineCopy.GetBuffer(), nullptr, nullptr, bInheritHandles,
	                                  creationFlags, nullptr, nullptr, &si.StartupInfo, &pi );
	DWORD createError = ::GetLastError();
	sCommandLineCopy.ReleaseBuffer();

	if( pAttributeList != nullptr )
		::DeleteProcThreadAttributeList( pAttributeList );

	if( !bCreated )
		return HRESULT_FROM_WIN32( createError );

	CHandle hProcess( pi.hProcess );
	CHandle hThread( pi.hThread );

	// Bounded wait: a hung child is killed instead of blocking the caller.
	DWORD waitResult = ::WaitForSingleObject( hProcess, timeoutMs );
	if( waitResult == WAIT_TIMEOUT )
	{
		::TerminateProcess( hProcess, 1 );
		// Make sure it is gone before its files are deleted by the caller.
		::WaitForSingleObject( hProcess, 5000 );
		return HRESULT_FROM_WIN32( ERROR_TIMEOUT );
	}
	if( waitResult != WAIT_OBJECT_0 )
		return HRESULT_FROM_WIN32( ::GetLastError() );

	if( !::GetExitCodeProcess( hProcess, &exitCode ) )
		return HRESULT_FROM_WIN32( ::GetLastError() );

	return S_OK;
}
