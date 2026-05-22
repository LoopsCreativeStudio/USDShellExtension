// USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
// Licensed under the MIT License. See LICENSE.txt for details.

#pragma once

#include <vector>

void SetupPythonEnvironment( HMODULE hCurrentModule );
const std::vector<CStringW> &GetUsdPathList();
const std::vector<CStringW> &GetUsdPythonPathList();
const CStringW &GetUsdPath();
const CStringW &GetUsdPythonPath();
const CStringW &GetUsdEditor();

std::vector<CStringW> BuildConfigFileList( HMODULE hCurrentModule );
void GetPrivateProfileStringAndExpandEnvironmentStrings( LPCWSTR lpAppName, LPCWSTR lpKeyName, LPCWSTR lpDefault, CStringW &lpReturnedString, const std::vector<CStringW> &ConfigFileList );