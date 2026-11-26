// USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
// Licensed under the MIT License. See LICENSE.txt for details.

#pragma once

// Same Windows / ATL setup as the production projects, so the shared sources
// included by the tests compile exactly as they do in the shipped binaries.

#ifndef STRICT
#define STRICT
#endif

#include <WinSDKVer.h>
#define _WIN32_WINNT 0x0A00
#include <SDKDDKVer.h>

#define _ATL_CSTRING_EXPLICIT_CONSTRUCTORS
#define NOMINMAX

#include <windows.h>
#include <PathCch.h>

#include <atlbase.h>
#include <atlstr.h>

#include <string>
#include <vector>

#include <CppUnitTest.h>
