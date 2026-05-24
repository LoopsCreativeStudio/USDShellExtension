// USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
// Licensed under the MIT License. See LICENSE.txt for details.

#include "stdafx.h"
#include "UsdSdkToolsImpl.h"
#include "Module.h"
#include "shared\environment.h"
#include "shared\EventViewerLog.h"

#include <string>
#include <vector>
#include <shlobj.h>

HRESULT CUsdSdkToolsImpl::FinalConstruct()
{
	SetupPythonEnvironment( g_hInstance );

	return __super::FinalConstruct();
}

void CUsdSdkToolsImpl::FinalRelease()
{
	__super::FinalRelease();
}

static void RegisterUsdPlugins()
{
	static bool sUsdPluginsRegistered = false;
	static std::mutex sUsdPluginsRegisteredLock;

	std::lock_guard<std::mutex> guard( sUsdPluginsRegisteredLock );

	// Plugins should be registered only once per session.
	if( sUsdPluginsRegistered )
		return;

	sUsdPluginsRegistered = true;

	TCHAR sModulePath[MAX_PATH];
	GetModuleFileName( g_hInstance, sModulePath, ARRAYSIZE( sModulePath ) );

	std::vector<std::string> pathsToPlugInfo;

	// add the folder that contains the shell extension
	PathCchRemoveFileSpec( sModulePath, ARRAYSIZE( sModulePath ) );
	pathsToPlugInfo.push_back( static_cast<LPCSTR>(ATL::CW2A(sModulePath, CP_UTF8)) );

	// add the bare-bones usd plugins
	PathCchAppend( sModulePath, ARRAYSIZE( sModulePath ), L"usd" );
	pathsToPlugInfo.push_back( static_cast<LPCSTR>(ATL::CW2A(sModulePath, CP_UTF8)) );

	pxr::PlugRegistry::GetInstance().RegisterPlugins( pathsToPlugInfo );

	pxr::ArSetPreferredResolver( "ArResolverShellExtension" );
}

STDMETHODIMP CUsdSdkToolsImpl::Cat( IN BSTR usdStagePathInput, IN BSTR usdStagePathOuput, IN eUsdFormat formatOutput, IN VARIANT_BOOL flatten )
{
	DEBUG_RECORD_ENTRY();

	RegisterUsdPlugins();

	pxr::SdfLayer::FileFormatArguments fileFormat;
	if ( formatOutput == USD_FORMAT_USDA )
		fileFormat["target"] = "usda";
	else if ( formatOutput == USD_FORMAT_USDC )
		fileFormat["target"] = "usdc";

	if ( flatten == VARIANT_FALSE )
	{
		std::string usdStagePathInputA = static_cast<LPCSTR>(ATL::CW2A( usdStagePathInput, CP_UTF8 ));
		pxr::SdfLayerRefPtr rootLayer = pxr::SdfLayer::OpenAsAnonymous( usdStagePathInputA, false );
		if ( rootLayer == nullptr )
			return E_FAIL;

		std::string usdStagePathOuputA = static_cast<LPCSTR>(ATL::CW2A( usdStagePathOuput, CP_UTF8 ));
		if ( !rootLayer->Export( usdStagePathOuputA, std::string(), fileFormat ) )
			return E_FAIL;
	}
	else
	{
		std::string usdStagePathInputA = static_cast<LPCSTR>(ATL::CW2A( usdStagePathInput, CP_UTF8 ));
		pxr::UsdStageRefPtr stage = pxr::UsdStage::Open( usdStagePathInputA );
		if ( stage == nullptr )
			return E_FAIL;

		stage->Flatten();

		std::string usdStagePathOuputA = static_cast<LPCSTR>(ATL::CW2A( usdStagePathOuput, CP_UTF8 ));
		if ( !stage->Export( usdStagePathOuputA, true, fileFormat ) )
			return E_FAIL;
	}

	return S_OK;
}

STDMETHODIMP CUsdSdkToolsImpl::Edit( IN BSTR usdStagePath, IN VARIANT_BOOL force )
{
	DEBUG_RECORD_ENTRY();

	RegisterUsdPlugins();

	DWORD inputFileAttribs = GetFileAttributes( usdStagePath );
	if ( inputFileAttribs == INVALID_FILE_ATTRIBUTES )
		return E_INVALIDARG;

	std::string usdStagePathA = static_cast<LPCSTR>(ATL::CW2A( usdStagePath, CP_UTF8 ));
	pxr::SdfLayerRefPtr rootLayer = pxr::SdfLayer::OpenAsAnonymous( usdStagePathA, false );
	if ( rootLayer == nullptr )
		return E_FAIL;

	CStringW usdStagePathOuputW;
	usdStagePathOuputW = usdStagePath;
	usdStagePathOuputW += L"-edit.usda";

	std::string exportString;
	if ( !rootLayer->ExportToString( &exportString ) )
		return E_FAIL;

	std::ofstream fileOut(usdStagePathOuputW.GetString(), std::ofstream::out|std::ofstream::trunc);
	if (!fileOut.is_open())
		return E_FAIL;

	fileOut << exportString;

	fileOut.close();


	WIN32_FILE_ATTRIBUTE_DATA wfadBefore = {};
	::GetFileAttributesEx( usdStagePathOuputW, GetFileExInfoStandard, &wfadBefore );

	// hide the file we're editing
	::SetFileAttributes( usdStagePathOuputW, wfadBefore.dwFileAttributes | FILE_ATTRIBUTE_HIDDEN );

	CStringW sEditor = GetUsdEditor();
	if ( sEditor.IsEmpty() )
		sEditor = L"notepad.exe";

	CStringW sCommandLine;
	sCommandLine.Format( L"%s \"%s\"", sEditor.GetString(), usdStagePathOuputW.GetString() );

	STARTUPINFO si = {};
	si.cb = sizeof( si );
	PROCESS_INFORMATION pi = {};
	if ( !::CreateProcess( nullptr, sCommandLine.GetBuffer(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &pi ) )
	{
		return E_FAIL;
	}

	::WaitForSingleObject( pi.hProcess, INFINITE );

	::CloseHandle( pi.hProcess );
	::CloseHandle( pi.hThread );

	WIN32_FILE_ATTRIBUTE_DATA wfadAfter = {};
	::GetFileAttributesEx( usdStagePathOuputW, GetFileExInfoStandard, &wfadAfter );

	if ( ::CompareFileTime( &wfadAfter.ftLastWriteTime, &wfadBefore.ftLastWriteTime ) != 0 )
	{
		if ( (inputFileAttribs & FILE_ATTRIBUTE_READONLY) )
		{
			if ( force == VARIANT_FALSE )
			{
				::DeleteFileW( usdStagePathOuputW );
				return S_OK;
			}

			::SetFileAttributes( usdStagePath, inputFileAttribs & ~FILE_ATTRIBUTE_READONLY );
		}

		std::ifstream fileIn(usdStagePathOuputW.GetString(), std::ifstream::in);
		if (!fileIn.is_open())
			return E_FAIL;

		std::ostringstream importString;
		importString << fileIn.rdbuf();
		fileIn.close();

		if ( rootLayer->ImportFromString( importString.str() ) == false )
			return E_FAIL;

		if ( rootLayer->Export( usdStagePathA ) == false )
			return E_FAIL;
	}

	::DeleteFileW( usdStagePathOuputW );

	return S_OK;
}

static void pause()
{
	std::cout << std::endl;
	std::cout << "Press Enter to close..." << std::endl;
	HANDLE hIn = ::CreateFileW( L"CONIN$", GENERIC_READ, FILE_SHARE_READ,
	                            nullptr, OPEN_EXISTING, 0, nullptr );
	if ( hIn != INVALID_HANDLE_VALUE )
	{
		WCHAR buf[2] = {};
		DWORD nRead  = 0;
		::ReadConsoleW( hIn, buf, 1, &nRead, nullptr );
		::CloseHandle( hIn );
	}
}

STDMETHODIMP CUsdSdkToolsImpl::Package( IN BSTR usdStagePathInput, IN BSTR usdStagePathOuput, IN eUsdPackageType packageType, IN VARIANT_BOOL verbose )
{
	DEBUG_RECORD_ENTRY();

	// create and display a console
	if (AllocConsole())
	{
		FILE *fout = nullptr;
		freopen_s(&fout, "CONOUT$", "w", stdout);
		FILE *ferr = nullptr;
		freopen_s(&ferr, "CONOUT$", "w", stderr);
	}

	SetConsoleTitleW( L"USD Package" );

	RegisterUsdPlugins();

	if ( verbose != VARIANT_FALSE )
		pxr::TfDebug::SetDebugSymbolsByName( "USDUTILS_CREATE_USDZ_PACKAGE", 1 );

	DWORD inputFileAttribs = GetFileAttributes( usdStagePathInput );
	if ( inputFileAttribs == INVALID_FILE_ATTRIBUTES )
		return E_INVALIDARG;

	std::string usdStagePathInputA = static_cast<LPCSTR>(ATL::CW2A( usdStagePathInput, CP_UTF8 ));
	std::string usdStagePathOuputA = static_cast<LPCSTR>(ATL::CW2A( usdStagePathOuput, CP_UTF8 ));

	if ( packageType == USD_PACKAGE_DEFAULT )
	{
		if ( !pxr::UsdUtilsCreateNewUsdzPackage( pxr::SdfAssetPath( usdStagePathInputA ), usdStagePathOuputA ) )
		{
			pause();
			return E_FAIL;
		}
	}
	else if( packageType == USD_FORMAT_APPLE_ARKIT )
	{
		if ( !pxr::UsdUtilsCreateNewARKitUsdzPackage( pxr::SdfAssetPath( usdStagePathInputA ), usdStagePathOuputA ) )
		{
			pause();
			return E_FAIL;
		}
	}
	else
	{
		pause();
		return E_INVALIDARG;
	}

	pause();
	return S_OK;
}

static void PrintDictionary( const pxr::VtDictionary &dict, int indent )
{
	for ( const std::pair<std::string, pxr::VtValue>& stat : dict )
	{
		for ( int i = 0; i < indent; ++i )
			std::cout << "  ";

		if ( stat.second.GetTypeid() == typeid(pxr::VtDictionary) )
		{
			std::cout << stat.first << std::endl;
			pxr::VtDictionary nestedDict = stat.second.Get<pxr::VtDictionary>();
			PrintDictionary( nestedDict, indent + 1 );
		}
		else
		{
			if ( stat.second.GetTypeid() == typeid(size_t) )
				std::cout << stat.first << " = " << stat.second.Get<size_t>() << std::endl;
			else if ( stat.second.GetTypeid() == typeid(double) )
				std::cout << stat.first << " = " << stat.second.Get<double>() << std::endl;
			else
				std::cout << stat.first << " = " << "[UNKNOWN TYPE]" << std::endl;
		}
	}
}

STDMETHODIMP CUsdSdkToolsImpl::DisplayStageStats( IN BSTR usdStagePath )
{
	DEBUG_RECORD_ENTRY();

	// create and display a console
	if (AllocConsole())
	{
		FILE *fout = nullptr;
		freopen_s(&fout, "CONOUT$", "w", stdout);
		FILE *ferr = nullptr;
		freopen_s(&ferr, "CONOUT$", "w", stderr);
	}

	SetConsoleTitleW( L"USD Stage Stats" );

	RegisterUsdPlugins();

	std::string sError;
	pxr::TfMallocTag::Initialize( &sError );

	std::string usdStagePathA = static_cast<LPCSTR>(ATL::CW2A( usdStagePath, CP_UTF8 ));

	std::cout << "USD Stage Stats" << std::endl;
	std::cout << std::string( 72, '=' ) << std::endl;
	std::cout << "File: " << usdStagePathA << std::endl;
	std::cout << std::endl;

	pxr::VtDictionary dictStats;
	pxr::UsdStageRefPtr stage = pxr::UsdUtilsComputeUsdStageStats( usdStagePathA, &dictStats );
	if ( stage == nullptr )
	{
		pause();
		return E_FAIL;
	}

	PrintDictionary( dictStats, 0 );

	pause();
	return S_OK;
}

STDMETHODIMP CUsdSdkToolsImpl::Unpackage( IN BSTR usdStagePathInput )
{
	DEBUG_RECORD_ENTRY();

	if ( AllocConsole() )
	{
		FILE *fout = nullptr;
		freopen_s( &fout, "CONOUT$", "w", stdout );
		FILE *ferr = nullptr;
		freopen_s( &ferr, "CONOUT$", "w", stderr );
	}
	SetConsoleTitleW( L"USD Unpackage" );

	RegisterUsdPlugins();

	std::string pathA = static_cast<LPCSTR>( ATL::CW2A( usdStagePathInput, CP_UTF8 ) );

	std::cout << "USD Unpackage" << std::endl;
	std::cout << std::string( 72, '=' ) << std::endl;
	std::cout << "File: " << pathA << std::endl;
	std::cout << std::endl;

	pxr::SdfZipFile zipFile = pxr::SdfZipFile::Open( pathA );
	if ( !zipFile )
	{
		std::cerr << "Error: failed to open USDZ package" << std::endl;
		pause();
		return E_FAIL;
	}

	// Output directory: same path without the .usdz extension.
	CStringW outDirW = usdStagePathInput;
	int dotPos = outDirW.ReverseFind( L'.' );
	if ( dotPos >= 0 )
		outDirW = outDirW.Left( dotPos );

	if ( !::CreateDirectoryW( outDirW, nullptr ) )
	{
		DWORD err = ::GetLastError();
		if ( err != ERROR_ALREADY_EXISTS )
		{
			std::cerr << "Error: could not create output directory" << std::endl;
			pause();
			return HRESULT_FROM_WIN32( err );
		}
	}

	std::string outDirA = static_cast<LPCSTR>( ATL::CW2A( outDirW, CP_UTF8 ) );
	int fileCount = 0;

	for ( auto it = zipFile.begin(); it != zipFile.end(); ++it )
	{
		const std::string fileName = *it;

		pxr::SdfZipFile::FileInfo info = it.GetFileInfo();
		if ( info.compressionMethod != 0 )
		{
			std::cerr << "  Warning: skipping compressed entry: " << fileName << std::endl;
			continue;
		}

		const char* data = it.GetFile();
		if ( !data )
			continue;

		// Build the output path, normalising forward slashes to backslashes.
		std::string outPath = outDirA + "\\" + fileName;
		for ( char& c : outPath )
		{
			if ( c == '/' ) c = '\\';
		}

		// Ensure all parent directories exist.
		size_t lastSlash = outPath.rfind( '\\' );
		if ( lastSlash != std::string::npos )
		{
			std::string parentA = outPath.substr( 0, lastSlash );
			CStringW parentW = ATL::CA2W( parentA.c_str(), CP_UTF8 );
			::SHCreateDirectoryExW( nullptr, parentW, nullptr );
		}

		CStringW outPathW = ATL::CA2W( outPath.c_str(), CP_UTF8 );
		HANDLE hFile = ::CreateFileW( outPathW, GENERIC_WRITE, 0, nullptr,
		                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr );
		if ( hFile == INVALID_HANDLE_VALUE )
		{
			std::cerr << "  Warning: failed to create: " << outPath << std::endl;
			continue;
		}

		DWORD written = 0;
		::WriteFile( hFile, data, static_cast<DWORD>( info.size ), &written, nullptr );
		::CloseHandle( hFile );

		std::cout << "  " << fileName << std::endl;
		++fileCount;
	}

	std::cout << std::endl;
	std::cout << fileCount << " file(s) extracted to: " << outDirA << std::endl;

	pause();
	return S_OK;
}

HRESULT WINAPI CUsdSdkToolsImpl::UpdateRegistry(_In_ BOOL bRegister) throw()
{
	ATL::_ATL_REGMAP_ENTRY regMapEntries[] =
	{
		{ L"APPID", L"{123A65E6-B4B4-4B46-BEF5-D0FCE7173261}" },
		{ L"CLSID_USDSDKTOOLS", L"{5F016739-AF12-4899-B710-3FB5C242A11D}" },
		{ nullptr, nullptr }
	};

	return g_AtlModule.UpdateRegistryFromResource(IDR_REGISTRY_USDTOOLSIMPL, bRegister, regMapEntries);
}