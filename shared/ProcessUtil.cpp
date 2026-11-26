// USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
// Licensed under the MIT License. See LICENSE.txt for details.

#include "stdafx.h"
#include "ProcessUtil.h"

#include <algorithm>
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

CStringW CUniqueTempFile::Detach()
{
	CStringW sPath = m_sPath;
	m_sPath.Empty();
	return sPath;
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

HRESULT CreateChildProcess( LPCWSTR sCommandLine, const ChildStdHandles &stdHandles, DWORD creationFlags, PROCESS_INFORMATION &pi )
{
	// CreateProcessW may modify the command line: work on a private copy.
	CStringW sCommandLineCopy = sCommandLine;

	STARTUPINFOEXW si = {};
	si.StartupInfo.cb = sizeof( si );
	BOOL bInheritHandles = FALSE;
	pi = {};

	// Restrict inheritance to the standard handles given: otherwise the child
	// would also inherit the handles of jobs running in parallel threads
	// (logs, worker pipes) and keep them open. The list must not contain
	// duplicates (stdout and stderr are often the same handle).
	std::vector<HANDLE> handlesToInherit;
	for( HANDLE handle : { stdHandles.input, stdHandles.output, stdHandles.error } )
	{
		if( handle != nullptr && std::find( handlesToInherit.begin(), handlesToInherit.end(), handle ) == handlesToInherit.end() )
			handlesToInherit.push_back( handle );
	}

	std::vector<BYTE> attributeListBuffer;
	LPPROC_THREAD_ATTRIBUTE_LIST pAttributeList = nullptr;

	if( !handlesToInherit.empty() )
	{
		SIZE_T nAttributeListSize = 0;
		::InitializeProcThreadAttributeList( nullptr, 1, 0, &nAttributeListSize );
		attributeListBuffer.resize( nAttributeListSize );
		pAttributeList = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>( attributeListBuffer.data() );

		if( !::InitializeProcThreadAttributeList( pAttributeList, 1, 0, &nAttributeListSize ) )
			return HRESULT_FROM_WIN32( ::GetLastError() );

		if( !::UpdateProcThreadAttribute( pAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
		                                  handlesToInherit.data(), handlesToInherit.size() * sizeof( HANDLE ),
		                                  nullptr, nullptr ) )
		{
			DWORD err = ::GetLastError();
			::DeleteProcThreadAttributeList( pAttributeList );
			return HRESULT_FROM_WIN32( err );
		}

		si.StartupInfo.dwFlags    = STARTF_USESTDHANDLES;
		si.StartupInfo.hStdInput  = stdHandles.input;
		si.StartupInfo.hStdOutput = stdHandles.output;
		si.StartupInfo.hStdError  = stdHandles.error;
		si.lpAttributeList        = pAttributeList;
		creationFlags            |= EXTENDED_STARTUPINFO_PRESENT;
		bInheritHandles           = TRUE;
	}

	BOOL bCreated = ::CreateProcessW( nullptr, sCommandLineCopy.GetBuffer(), nullptr, nullptr, bInheritHandles,
	                                  creationFlags, nullptr, nullptr, &si.StartupInfo, &pi );
	DWORD createError = ::GetLastError();
	sCommandLineCopy.ReleaseBuffer();

	if( pAttributeList != nullptr )
		::DeleteProcThreadAttributeList( pAttributeList );

	return bCreated ? S_OK : HRESULT_FROM_WIN32( createError );
}

HRESULT RunProcessAndWait( LPCWSTR sCommandLine, HANDLE hStdOutErr, DWORD timeoutMs, DWORD &exitCode,
                           DWORD creationFlags )
{
	exitCode = 0;

	PROCESS_INFORMATION pi;
	HRESULT hr = CreateChildProcess( sCommandLine, ChildStdHandles{ nullptr, hStdOutErr, hStdOutErr }, creationFlags, pi );
	if( FAILED( hr ) )
		return hr;

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

HRESULT LaunchProcess( LPCWSTR sCommandLine, HANDLE hStdOutErr, DWORD creationFlags )
{
	PROCESS_INFORMATION pi;
	HRESULT hr = CreateChildProcess( sCommandLine, ChildStdHandles{ nullptr, hStdOutErr, hStdOutErr }, creationFlags, pi );
	if( FAILED( hr ) )
		return hr;

	// The tool opens its own window: let it come to the foreground, then
	// stop tracking it (it outlives this call).
	::AllowSetForegroundWindow( pi.dwProcessId );
	::CloseHandle( pi.hThread );
	::CloseHandle( pi.hProcess );
	return S_OK;
}

// ---------------------------------------------------------------------------
// CScriptDirectory
// ---------------------------------------------------------------------------

// Delete a folder with everything below it, e.g. the __pycache__ Python may
// write next to a script (best effort: files still open are left for a
// later cleanup). Reparse points (links) are removed, never followed.
static void DeleteDirectoryTree( const CStringW &sDirectory )
{
	WIN32_FIND_DATAW findData;
	HANDLE hFind = ::FindFirstFileW( sDirectory + L"\\*", &findData );
	if( hFind != INVALID_HANDLE_VALUE )
	{
		do
		{
			CStringW sName = findData.cFileName;
			if( sName == L"." || sName == L".." )
				continue;

			CStringW sPath = sDirectory + L"\\" + sName;
			bool bDirectory = ( findData.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY ) != 0;
			bool bLink = ( findData.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT ) != 0;
			if( bDirectory && !bLink )
				DeleteDirectoryTree( sPath );
			else if( bDirectory )
				::RemoveDirectoryW( sPath );
			else
				::DeleteFileW( sPath );
		} while( ::FindNextFileW( hFind, &findData ) );
		::FindClose( hFind );
	}
	::RemoveDirectoryW( sDirectory );
}

// True when a process with this id still runs (or exists but is not ours).
static bool IsProcessRunning( DWORD processId )
{
	HANDLE hProcess = ::OpenProcess( PROCESS_QUERY_LIMITED_INFORMATION, FALSE, processId );
	if( hProcess == nullptr )
		return ::GetLastError() == ERROR_ACCESS_DENIED;	// exists, other user

	DWORD exitCode = 0;
	BOOL bOk = ::GetExitCodeProcess( hProcess, &exitCode );
	::CloseHandle( hProcess );
	return bOk && exitCode == STILL_ACTIVE;
}

CScriptDirectory::CScriptDirectory( LPCWSTR sParentDirectory ) :
	m_sParentDirectory( sParentDirectory )
{
	// <pid>_<guid>: unique per instance, and the pid tells whether the owner
	// still runs (see RemoveStaleDirectories). Created lazily by GetFile.
	GUID guid = {};
	::CoCreateGuid( &guid );
	wchar_t sGuid[64];
	::StringFromGUID2( guid, sGuid, ARRAYSIZE( sGuid ) );
	CStringW sName = sGuid;
	sName.Trim( L"{}" );

	m_sDirectory.Format( L"%ls\\%lu_%ls", sParentDirectory, ::GetCurrentProcessId(), sName.GetString() );
}

CScriptDirectory::~CScriptDirectory()
{
	if( m_bCreated )
		DeleteDirectoryTree( m_sDirectory );
}

HRESULT CScriptDirectory::GetFile( LPCWSTR sFileName, const void *pData, DWORD nSize, CStringW &sPath )
{
	sPath = m_sDirectory + L"\\" + sFileName;

	// The whole write happens under the lock: a concurrent caller never gets
	// the path of a file that is still being written.
	std::lock_guard<std::mutex> guard( m_lock );
	if( m_writtenFiles.count( sFileName ) )
		return S_OK;

	if( !m_bCreated )
	{
		::CreateDirectoryW( m_sParentDirectory, nullptr );	// may already exist
		if( !::CreateDirectoryW( m_sDirectory, nullptr ) && ::GetLastError() != ERROR_ALREADY_EXISTS )
			return HRESULT_FROM_WIN32( ::GetLastError() );
		m_bCreated = true;
	}

	CHandle hFile( ::CreateFileW( sPath, GENERIC_WRITE, FILE_SHARE_READ, nullptr,
	                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr ) );
	if( hFile == INVALID_HANDLE_VALUE )
	{
		hFile.Detach();
		return HRESULT_FROM_WIN32( ::GetLastError() );
	}

	DWORD nWritten = 0;
	if( !::WriteFile( hFile, pData, nSize, &nWritten, nullptr ) || nWritten != nSize )
		return HRESULT_FROM_WIN32( ERROR_WRITE_FAULT );

	m_writtenFiles.insert( sFileName );
	return S_OK;
}

void CScriptDirectory::RemoveStaleDirectories( LPCWSTR sParentDirectory )
{
	CStringW sParent = sParentDirectory;
	WIN32_FIND_DATAW findData;
	HANDLE hFind = ::FindFirstFileW( sParent + L"\\*_*", &findData );
	if( hFind == INVALID_HANDLE_VALUE )
		return;

	do
	{
		if( !( findData.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY ) )
			continue;

		// Folder name: <pid>_<anything>. Skip anything else.
		wchar_t *pEnd = nullptr;
		unsigned long processId = ::wcstoul( findData.cFileName, &pEnd, 10 );
		if( pEnd == findData.cFileName || *pEnd != L'_' )
			continue;

		if( processId == ::GetCurrentProcessId() || IsProcessRunning( processId ) )
			continue;

		DeleteDirectoryTree( sParent + L"\\" + findData.cFileName );
	} while( ::FindNextFileW( hFind, &findData ) );
	::FindClose( hFind );
}
