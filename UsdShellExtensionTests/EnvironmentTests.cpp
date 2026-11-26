// USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
// Licensed under the MIT License. See LICENSE.txt for details.

// Characterization tests for shared/environment.cpp: INI lookup across the
// config file chain, path list splitting and environment variable appending.

#include "stdafx.h"

// environment.cpp is included (not linked) so its file-local helpers
// (TranslatePathsToList, AppendEnvironmentVariable) can be tested without
// changing their linkage in production code.
#include "shared/environment.cpp"

#include <fstream>

using namespace Microsoft::VisualStudio::CppUnitTestFramework;

namespace
{
	// Create a fresh, unique temp directory for one test.
	CStringW CreateTempTestDir()
	{
		wchar_t sTempPath[MAX_PATH];
		::GetTempPathW( ARRAYSIZE( sTempPath ), sTempPath );

		GUID guid;
		::CoCreateGuid( &guid );
		wchar_t sGuid[64];
		::StringFromGUID2( guid, sGuid, ARRAYSIZE( sGuid ) );

		CStringW sDir = sTempPath;
		sDir += L"UsdShellExtensionTests_";
		sDir += sGuid;
		::CreateDirectoryW( sDir, nullptr );
		return sDir;
	}

	// Delete a temp directory and the files created in it.
	void DeleteTempTestDir( const CStringW &sDir )
	{
		WIN32_FIND_DATAW findData;
		HANDLE hFind = ::FindFirstFileW( sDir + L"\\*", &findData );
		if( hFind != INVALID_HANDLE_VALUE )
		{
			do
			{
				if( !(findData.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) )
					::DeleteFileW( sDir + L"\\" + findData.cFileName );
			} while( ::FindNextFileW( hFind, &findData ) );
			::FindClose( hFind );
		}
		::RemoveDirectoryW( sDir );
	}

	// Write an INI file encoded like the shipped one (UTF-16 LE with BOM).
	CStringW WriteUtf16Ini( const CStringW &sDir, LPCWSTR sFileName, const std::wstring &content )
	{
		CStringW sPath = sDir + L"\\" + sFileName;
		std::ofstream file( sPath.GetString(), std::ios::binary );
		const unsigned char bom[] = { 0xFF, 0xFE };
		file.write( reinterpret_cast<const char *>(bom), sizeof( bom ) );
		file.write( reinterpret_cast<const char *>(content.data()), content.size() * sizeof( wchar_t ) );
		return sPath;
	}

	// Read a CRT environment variable (the one AppendEnvironmentVariable writes).
	std::wstring GetCrtEnv( LPCWSTR sName )
	{
		size_t nRequired = 0;
		if( _wgetenv_s( &nRequired, nullptr, 0, sName ) != 0 || nRequired == 0 )
			return L"";
		std::wstring value( nRequired, L'\0' );
		_wgetenv_s( &nRequired, value.data(), nRequired, sName );
		value.resize( wcslen( value.c_str() ) );
		return value;
	}
}

TEST_CLASS( TranslatePathsToListTests )
{
public:
	TEST_METHOD( SplitsSemicolonSeparatedPaths )
	{
		std::vector<CStringW> list = TranslatePathsToList( L"C:\\a;D:\\b;E:\\c" );

		Assert::AreEqual( size_t( 3 ), list.size() );
		Assert::AreEqual( L"C:\\a", list[0].GetString() );
		Assert::AreEqual( L"D:\\b", list[1].GetString() );
		Assert::AreEqual( L"E:\\c", list[2].GetString() );
	}

	TEST_METHOD( KeepsASinglePath )
	{
		std::vector<CStringW> list = TranslatePathsToList( L"C:\\only" );

		Assert::AreEqual( size_t( 1 ), list.size() );
		Assert::AreEqual( L"C:\\only", list[0].GetString() );
	}

	TEST_METHOD( SkipsEmptySegments )
	{
		std::vector<CStringW> list = TranslatePathsToList( L";C:\\a;;D:\\b;" );

		Assert::AreEqual( size_t( 2 ), list.size() );
		Assert::AreEqual( L"C:\\a", list[0].GetString() );
		Assert::AreEqual( L"D:\\b", list[1].GetString() );
	}

	TEST_METHOD( EmptyInputGivesOneEmptyEntry )
	{
		// Current behavior: an unset [USD] PATH yields one empty entry,
		// which callers then probe as a relative path.
		std::vector<CStringW> list = TranslatePathsToList( L"" );

		Assert::AreEqual( size_t( 1 ), list.size() );
		Assert::IsTrue( list[0].IsEmpty() );
	}
};

TEST_CLASS( AppendEnvironmentVariableTests )
{
	static constexpr LPCWSTR kVarName = L"USDSHELLEXT_TEST_APPEND";

public:
	TEST_METHOD_CLEANUP( ClearVariable )
	{
		_wputenv_s( kVarName, L"" );
	}

	TEST_METHOD( PrependsValueToExistingVariable )
	{
		_wputenv_s( kVarName, L"C:\\old" );

		AppendEnvironmentVariable( kVarName, L"C:\\new" );

		Assert::AreEqual( std::wstring( L"C:\\new;C:\\old" ), GetCrtEnv( kVarName ) );
	}

	TEST_METHOD( LeavesTrailingSeparatorWhenVariableIsUnset )
	{
		// Current behavior: "value;" when there was nothing to append to.
		AppendEnvironmentVariable( kVarName, L"C:\\new" );

		Assert::AreEqual( std::wstring( L"C:\\new;" ), GetCrtEnv( kVarName ) );
	}

	TEST_METHOD( ReturnedStringHasNoEmbeddedNull )
	{
		// The returned value feeds GetUsdPath / GetUsdPythonPath: its logical
		// length must match its C string length (no stray terminator).
		_wputenv_s( kVarName, L"C:\\old" );

		CStringW sResult = AppendEnvironmentVariable( kVarName, L"C:\\new" );

		Assert::AreEqual( static_cast<int>( wcslen( sResult.GetString() ) ), sResult.GetLength() );
		Assert::AreEqual( L"C:\\new;C:\\old", sResult.GetString() );
	}
};

TEST_CLASS( GetPrivateProfileStringAndExpandTests )
{
	CStringW m_tempDir;

public:
	TEST_METHOD_INITIALIZE( CreateDir )
	{
		m_tempDir = CreateTempTestDir();
	}

	TEST_METHOD_CLEANUP( DeleteDir )
	{
		DeleteTempTestDir( m_tempDir );
	}

	TEST_METHOD( FirstConfigFileWins )
	{
		CStringW sUser = WriteUtf16Ini( m_tempDir, L"user.ini", L"[USD]\r\nEDITOR=user-editor\r\n" );
		CStringW sModule = WriteUtf16Ini( m_tempDir, L"module.ini", L"[USD]\r\nEDITOR=module-editor\r\n" );

		CStringW sValue;
		GetPrivateProfileStringAndExpandEnvironmentStrings( L"USD", L"EDITOR", L"default", sValue, { sUser, sModule } );

		Assert::AreEqual( L"user-editor", sValue.GetString() );
	}

	TEST_METHOD( FallsThroughMissingFilesAndKeys )
	{
		CStringW sMissing = m_tempDir + L"\\missing.ini";
		CStringW sOtherKey = WriteUtf16Ini( m_tempDir, L"other.ini", L"[USD]\r\nPATH=C:\\usd\r\n" );
		CStringW sModule = WriteUtf16Ini( m_tempDir, L"module.ini", L"[USD]\r\nEDITOR=module-editor\r\n" );

		CStringW sValue;
		GetPrivateProfileStringAndExpandEnvironmentStrings( L"USD", L"EDITOR", L"default", sValue, { sMissing, sOtherKey, sModule } );

		Assert::AreEqual( L"module-editor", sValue.GetString() );
	}

	TEST_METHOD( EmptyValueDoesNotOverrideLaterFiles )
	{
		// Current behavior: "KEY=" in a higher priority file is treated as
		// "not set", so it cannot blank out a value from a later file.
		CStringW sUser = WriteUtf16Ini( m_tempDir, L"user.ini", L"[USD]\r\nEDITOR=\r\n" );
		CStringW sModule = WriteUtf16Ini( m_tempDir, L"module.ini", L"[USD]\r\nEDITOR=module-editor\r\n" );

		CStringW sValue;
		GetPrivateProfileStringAndExpandEnvironmentStrings( L"USD", L"EDITOR", L"default", sValue, { sUser, sModule } );

		Assert::AreEqual( L"module-editor", sValue.GetString() );
	}

	TEST_METHOD( ReturnsDefaultWhenKeyIsNowhere )
	{
		CStringW sModule = WriteUtf16Ini( m_tempDir, L"module.ini", L"[USD]\r\nPATH=C:\\usd\r\n" );

		CStringW sValue;
		GetPrivateProfileStringAndExpandEnvironmentStrings( L"USD", L"EDITOR", L"fallback", sValue, { sModule } );

		Assert::AreEqual( L"fallback", sValue.GetString() );
	}

	TEST_METHOD( ReturnsDefaultWithEmptyFileList )
	{
		// Regression: with no config file the lookup buffer used to be read
		// uninitialized (returned leftovers of a previous call).
		CStringW sValue;
		GetPrivateProfileStringAndExpandEnvironmentStrings( L"USD", L"EDITOR", L"fallback", sValue, {} );

		Assert::AreEqual( L"fallback", sValue.GetString() );
	}

	TEST_METHOD( ExpandsEnvironmentVariables )
	{
		::SetEnvironmentVariableW( L"USDSHELLEXT_TEST_ROOT", L"D:\\sdk" );
		CStringW sModule = WriteUtf16Ini( m_tempDir, L"module.ini", L"[USD]\r\nPATH=%USDSHELLEXT_TEST_ROOT%\\bin\r\n" );

		CStringW sValue;
		GetPrivateProfileStringAndExpandEnvironmentStrings( L"USD", L"PATH", L"", sValue, { sModule } );
		::SetEnvironmentVariableW( L"USDSHELLEXT_TEST_ROOT", nullptr );

		Assert::AreEqual( L"D:\\sdk\\bin", sValue.GetString() );
		Assert::AreEqual( static_cast<int>( wcslen( sValue.GetString() ) ), sValue.GetLength() );
	}
};

TEST_CLASS( BuildConfigFileListTests )
{
public:
	TEST_METHOD( ListsUserThenMachineThenModuleConfig )
	{
		std::vector<CStringW> list = BuildConfigFileList( nullptr );

		Assert::AreEqual( size_t( 3 ), list.size() );

		// 1. %LOCALAPPDATA%, 2. %PROGRAMDATA%, 3. next to the module.
		wchar_t sLocalAppData[MAX_PATH];
		::ExpandEnvironmentStringsW( L"%LOCALAPPDATA%\\UsdShellExtension\\UsdShellExtension.ini", sLocalAppData, ARRAYSIZE( sLocalAppData ) );
		wchar_t sProgramData[MAX_PATH];
		::ExpandEnvironmentStringsW( L"%PROGRAMDATA%\\UsdShellExtension\\UsdShellExtension.ini", sProgramData, ARRAYSIZE( sProgramData ) );

		Assert::AreEqual( 0, list[0].CompareNoCase( sLocalAppData ) );
		Assert::AreEqual( 0, list[1].CompareNoCase( sProgramData ) );
		Assert::IsTrue( list[2].Right( 22 ).CompareNoCase( L"\\UsdShellExtension.ini" ) == 0 );
	}
};
