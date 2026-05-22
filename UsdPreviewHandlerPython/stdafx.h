// USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
// Licensed under the MIT License. See LICENSE.txt for details.

#pragma once

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

#include <iostream>

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tchar.h>
#include <Uxtheme.h>

#include <atlbase.h>
#include <atlcom.h>
#include <atlconv.h>
#include <atlstr.h>
#include <atlwin.h>