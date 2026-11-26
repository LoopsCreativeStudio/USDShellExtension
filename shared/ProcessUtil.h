// USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
// Licensed under the MIT License. See LICENSE.txt for details.

#pragma once

// Building blocks to run tool subprocesses safely from a multi-threaded COM
// server: every resource is released by RAII and every wait is bounded.

#include <atlbase.h>
#include <atlstr.h>

#include <mutex>
#include <set>
#include <string>

// One slot of a counting semaphore (e.g. the thumbnail render throttle).
// The slot is given back automatically when the object goes out of scope.
class CSemaphoreSlot
{
public:
	CSemaphoreSlot() = default;
	~CSemaphoreSlot();

	CSemaphoreSlot( const CSemaphoreSlot & ) = delete;
	CSemaphoreSlot &operator=( const CSemaphoreSlot & ) = delete;

	// Wait up to timeoutMs for a free slot. Returns true when acquired.
	bool Acquire( HANDLE hSemaphore, DWORD timeoutMs );

	bool IsAcquired() const { return m_hSemaphore != nullptr; }

private:
	HANDLE m_hSemaphore = nullptr;	// set only while a slot is held
};

// Temporary file with a unique (GUID based) name, deleted on destruction.
// Lets parallel jobs each own their script / log instead of sharing one.
class CUniqueTempFile
{
public:
	CUniqueTempFile() = default;
	~CUniqueTempFile();

	CUniqueTempFile( const CUniqueTempFile & ) = delete;
	CUniqueTempFile &operator=( const CUniqueTempFile & ) = delete;

	// Create an empty <directory>\<prefix><guid>.<extension> file.
	HRESULT Create( LPCWSTR sDirectory, LPCWSTR sPrefix, LPCWSTR sExtension );

	// Replace the file content.
	HRESULT Write( const void *pData, DWORD nSize );

	// Read the whole file as bytes (empty on error).
	CStringA ReadAll() const;

	// Empty until Create succeeds.
	const CStringW &GetPath() const { return m_sPath; }

	// Stop owning the file: it is no longer deleted on destruction and the
	// caller becomes responsible for it. Returns its path.
	CStringW Detach();

private:
	CStringW m_sPath;
};

// Open (truncate) a file for writing with an inheritable handle, to be used
// as a child's stdout / stderr. Returns nullptr on failure.
HANDLE OpenInheritableForWrite( LPCWSTR sPath );

// Run a hidden child process and wait at most timeoutMs for it to exit.
// hStdOutErr (optional, inheritable) receives stdout and stderr; it is the
// only handle the child inherits. Returns S_OK with exitCode set,
// HRESULT_FROM_WIN32( ERROR_TIMEOUT ) after killing a child that ran too
// long, or the CreateProcess error. timeoutMs may be INFINITE when the wait is
// on the user (editor). creationFlags: CREATE_NO_WINDOW hides console tools;
// pass 0 for a tool the user interacts with in its own console.
HRESULT RunProcessAndWait( LPCWSTR sCommandLine, HANDLE hStdOutErr, DWORD timeoutMs, DWORD &exitCode,
                           DWORD creationFlags = CREATE_NO_WINDOW );

// Standard handles of a child process; nullptr leaves one unset. Each one
// must be inheritable; they are the only handles the child inherits.
struct ChildStdHandles
{
	HANDLE input = nullptr;
	HANDLE output = nullptr;
	HANDLE error = nullptr;
};

// Create a child process with its own standard handles. On success the
// caller owns pi.hProcess and pi.hThread (e.g. CREATE_SUSPENDED to add it to
// a job object before it runs).
HRESULT CreateChildProcess( LPCWSTR sCommandLine, const ChildStdHandles &stdHandles, DWORD creationFlags, PROCESS_INFORMATION &pi );

// Start a child process without waiting for it, for tools that live in their
// own window (usdview, console tools). creationFlags is CREATE_NO_WINDOW or
// CREATE_NEW_CONSOLE; hStdOutErr (optional) follows the same rules as for
// RunProcessAndWait. The child may bring its window to the foreground.
HRESULT LaunchProcess( LPCWSTR sCommandLine, HANDLE hStdOutErr, DWORD creationFlags );

// Folder holding the tool scripts extracted by one server process:
// <parent>\<pid>_<guid>. A script is written once, then only read: it is
// never rewritten while another python.exe is reading it. The folder is
// deleted on destruction; folders of servers that crashed are removed by
// RemoveStaleDirectories.
class CScriptDirectory
{
public:
	explicit CScriptDirectory( LPCWSTR sParentDirectory );
	~CScriptDirectory();

	CScriptDirectory( const CScriptDirectory & ) = delete;
	CScriptDirectory &operator=( const CScriptDirectory & ) = delete;

	// Return the path of sFileName in the folder, writing pData the first
	// time only. Thread-safe: concurrent callers get the complete file.
	HRESULT GetFile( LPCWSTR sFileName, const void *pData, DWORD nSize, CStringW &sPath );

	const CStringW &GetDirectory() const { return m_sDirectory; }

	// Delete the folders of processes that no longer run.
	static void RemoveStaleDirectories( LPCWSTR sParentDirectory );

private:
	CStringW m_sParentDirectory;
	CStringW m_sDirectory;
	std::mutex m_lock;
	std::set<std::wstring> m_writtenFiles;
	bool m_bCreated = false;
};
