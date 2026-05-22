// USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
// Licensed under the MIT License. See LICENSE.txt for details.

#include "stdafx.h"
#include "Module.h"

HMODULE g_hInstance;
CUSDPreviewLocalServerModule g_AtlModule;

extern "C" int WINAPI _tWinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPTSTR lpCmdLine, int nShowCmd)
{
	UNREFERENCED_PARAMETER( hPrevInstance );
	UNREFERENCED_PARAMETER( lpCmdLine );
	UNREFERENCED_PARAMETER( nShowCmd );

	g_hInstance = hInstance;

	int nResult = g_AtlModule.WinMain( nShowCmd );

	return nResult;
}


