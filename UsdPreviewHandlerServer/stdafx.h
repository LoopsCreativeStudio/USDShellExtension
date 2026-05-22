// USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
// Licensed under the MIT License. See LICENSE.txt for details.

#pragma once

#ifndef STRICT
#define STRICT
#endif

#pragma warning(push)
#pragma warning(disable: 4244 4459)

#include <pxr/external/boost/python/module.hpp>
#include <pxr/external/boost/python/def.hpp>
#include <pxr/external/boost/python/list.hpp>
#include <pxr/external/boost/python.hpp>

#pragma warning(pop)

// In USD 25.08+, pxr_boost lives inside the versioned namespace
// (PXR_INTERNAL_NS::pxr_boost). Create a global alias so existing code
// using `pxr_boost::python` still compiles without modification.
namespace pxr_boost = ::PXR_INTERNAL_NS::pxr_boost;

#include <WinSDKVer.h>
#define _WIN32_WINNT 0x0A00
#include <SDKDDKVer.h>

#define _ATL_APARTMENT_THREADED
#define _ATL_CSTRING_EXPLICIT_CONSTRUCTORS	// some CString constructors will be explicit
#define ATL_NO_ASSERT_ON_DESTROY_NONEXISTENT_WINDOW
// Use the C++ standard templated min/max
#define NOMINMAX
#define NOBITMAP
// Include <mcx.h> if you need this
#define NOMCX
// Include <winsvc.h> if you need this
#define NOSERVICE

#include <windows.h>
#include <PathCch.h>

#include <atlbase.h>
#include <atlcom.h>
#include <atlconv.h>
#include <atlctl.h>
#include <atlstr.h>
#include <atlsafe.h>
#include <comutil.h>

#include <stdint.h>

