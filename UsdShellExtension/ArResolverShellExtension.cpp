// USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
// Licensed under the MIT License. See LICENSE.txt for details.

#include "stdafx.h"
#include "ArResolverShellExtension.h"
#include <io.h>      // _open_osfhandle
#include <fcntl.h>   // _O_RDONLY, _O_BINARY

// NOTE
// /Zc:inline- is set for this file in the vcxproj
// Enabling /Zc:inline strips out USD plug-in registration
// https://developercommunity.visualstudio.com/t/zcinline-removes-extern-symbols-inside-anonymous-n/914943

PXR_NAMESPACE_OPEN_SCOPE

AR_DEFINE_RESOLVER(ArResolverShellExtension, ArResolver)

std::shared_ptr<ArAsset> ArResolverShellExtension::_OpenAsset(const ArResolvedPath& resolvedPath) const
{
	// Open with FILE_SHARE_READ | FILE_SHARE_DELETE so other processes can
	// delete the file while it is open -- e.g. the user deletes a USD file
	// that is currently being previewed in the Explorer preview pane.
	// _wfsopen/_SH_SECURE allows shared reads but blocks delete sharing.
	// If the file is deleted while we hold the handle, reads continue to
	// work; NTFS releases the content only when the last handle is closed.
	ATL::CStringW wsPath = ATL::CA2W( resolvedPath.GetPathString().c_str(), CP_UTF8 );

	HANDLE hFile = ::CreateFileW(
		wsPath.GetString(),
		GENERIC_READ,
		FILE_SHARE_READ | FILE_SHARE_DELETE,
		nullptr,
		OPEN_EXISTING,
		FILE_ATTRIBUTE_NORMAL,
		nullptr );

	if ( hFile == INVALID_HANDLE_VALUE )
		return nullptr;

	int fd = ::_open_osfhandle( reinterpret_cast<intptr_t>( hFile ), _O_RDONLY | _O_BINARY );
	if ( fd == -1 )
	{
		::CloseHandle( hFile );
		return nullptr;
	}

	FILE* f = ::_fdopen( fd, "rb" );
	if ( !f )
	{
		::_close( fd );  // also closes hFile
		return nullptr;
	}

	return std::make_shared<ArFilesystemAsset>( f );
}

PXR_NAMESPACE_CLOSE_SCOPE

