// USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
// Licensed under the MIT License. See LICENSE.txt for details.

#pragma once

// Building blocks to run tool subprocesses safely from a multi-threaded COM
// server: every resource is released by RAII and every wait is bounded.

#include <atlbase.h>
#include <atlstr.h>

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
// long, or the CreateProcess error.
HRESULT RunProcessAndWait( LPCWSTR sCommandLine, HANDLE hStdOutErr, DWORD timeoutMs, DWORD &exitCode );
