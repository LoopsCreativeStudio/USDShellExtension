// USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
// Licensed under the MIT License. See LICENSE.txt for details.

// Characterization tests for UsdShellExtension/UsdMetadata.cpp: how USD layer
// metadata is mapped to Windows properties (Details tab, Windows Search) and
// written back from edited properties.

// Same precompiled environment as the shell extension DLL, so UsdMetadata.cpp
// compiles exactly as in production. Its own #include "stdafx.h" resolves to
// this same file (same folder) and is skipped by #pragma once.
#include "UsdShellExtension/stdafx.h"

// The DLL's stdafx.h defines min/max macros for GDI+; they break the test
// framework headers, which use std::numeric_limits<>::max().
#undef min
#undef max

#include <CppUnitTest.h>

// Included (not linked) to reach the file-local DictionaryToString.
#include "UsdShellExtension/UsdMetadata.cpp"

#include <pxr/base/plug/registry.h>
#include <pxr/usd/sdf/layer.h>

using namespace Microsoft::VisualStudio::CppUnitTestFramework;

namespace
{
	// Register the USD plugins copied next to the test DLL (usd\ folder),
	// as RegisterUsdPlugins() does for the shell extension.
	void RegisterUsdPluginsForTests()
	{
		static bool sRegistered = false;
		if( sRegistered )
			return;
		sRegistered = true;

		HMODULE hTestModule = nullptr;
		::GetModuleHandleExW( GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
		                      reinterpret_cast<LPCWSTR>( &RegisterUsdPluginsForTests ), &hTestModule );

		wchar_t sModuleDir[MAX_PATH];
		::GetModuleFileNameW( hTestModule, sModuleDir, ARRAYSIZE( sModuleDir ) );
		::PathCchRemoveFileSpec( sModuleDir, ARRAYSIZE( sModuleDir ) );

		wchar_t sUsdPluginDir[MAX_PATH];
		wcscpy_s( sUsdPluginDir, sModuleDir );
		::PathCchAppend( sUsdPluginDir, ARRAYSIZE( sUsdPluginDir ), L"usd" );

		std::vector<std::string> pathsToPlugInfo = {
			static_cast<LPCSTR>( ATL::CW2A( sModuleDir, CP_UTF8 ) ),
			static_cast<LPCSTR>( ATL::CW2A( sUsdPluginDir, CP_UTF8 ) ),
		};
		pxr::PlugRegistry::GetInstance().RegisterPlugins( pathsToPlugInfo );
	}

	// Create an empty in-memory property store, like the shell extension.
	CComPtr<IPropertyStoreCache> CreateStore()
	{
		CComPtr<IPropertyStoreCache> pStore;
		HRESULT hr = ::PSCreateMemoryPropertyStore( IID_PPV_ARGS( &pStore ) );
		Assert::IsTrue( SUCCEEDED( hr ), L"PSCreateMemoryPropertyStore failed" );
		return pStore;
	}

	// Read a property as text ("" when missing).
	std::wstring GetString( IPropertyStoreCache *pStore, REFPROPERTYKEY key )
	{
		PROPVARIANT value;
		::PropVariantInit( &value );
		pStore->GetValue( key, &value );
		std::wstring result = ::PropVariantToStringWithDefault( value, L"" );
		::PropVariantClear( &value );
		return result;
	}

	// Read a property's variant type (VT_EMPTY when missing).
	VARTYPE GetType( IPropertyStoreCache *pStore, REFPROPERTYKEY key )
	{
		PROPVARIANT value;
		::PropVariantInit( &value );
		pStore->GetValue( key, &value );
		VARTYPE vt = value.vt;
		::PropVariantClear( &value );
		return vt;
	}

	// Read a VT_R8 property.
	double GetDouble( IPropertyStoreCache *pStore, REFPROPERTYKEY key )
	{
		PROPVARIANT value;
		::PropVariantInit( &value );
		pStore->GetValue( key, &value );
		Assert::AreEqual( static_cast<int>( VT_R8 ), static_cast<int>( value.vt ) );
		double result = value.dblVal;
		::PropVariantClear( &value );
		return result;
	}

	// The PKEY_USD_* string properties only exist once the shell extension
	// schema (UsdPropertyKeys.propdesc) is registered in Windows: before that,
	// PSCoerceToCanonicalValue rejects them and the values are dropped.
	bool IsUsdPropertySchemaRegistered()
	{
		CComPtr<IPropertyDescription> pDescription;
		return SUCCEEDED( ::PSGetPropertyDescription( PKEY_USD_FORMAT, IID_PPV_ARGS( &pDescription ) ) );
	}
}

TEST_CLASS( DictionaryToStringTests )
{
public:
	TEST_CLASS_INITIALIZE( RegisterPlugins )
	{
		RegisterUsdPluginsForTests();
	}

	TEST_METHOD( EmptyDictionaryGivesEmptyText )
	{
		Assert::AreEqual( std::string( "" ), DictionaryToString( pxr::VtDictionary() ) );
	}

	TEST_METHOD( WritesOneSortedLinePerSupportedValue )
	{
		pxr::VtDictionary dict;
		dict["project"] = pxr::VtValue( std::string( "kitchen" ) );
		dict["fps"] = pxr::VtValue( 24.0 );
		dict["count"] = pxr::VtValue( size_t( 3 ) );

		// VtDictionary is ordered by key.
		Assert::AreEqual( std::string( "count=3\nfps=24\nproject=kitchen\n" ), DictionaryToString( dict ) );
	}

	TEST_METHOD( FlattensNestedDictionariesWithDottedKeys )
	{
		pxr::VtDictionary shot;
		shot["name"] = pxr::VtValue( std::string( "010" ) );
		pxr::VtDictionary pipeline;
		pipeline["shot"] = pxr::VtValue( shot );
		pxr::VtDictionary dict;
		dict["pipeline"] = pxr::VtValue( pipeline );

		Assert::AreEqual( std::string( "pipeline.shot.name=010\n" ), DictionaryToString( dict ) );
	}

	TEST_METHOD( FormatsIntegersBooleansAndFloats )
	{
		// Common customLayerData values used to show as [UNKNOWN TYPE].
		pxr::VtDictionary dict;
		dict["approved"] = pxr::VtValue( true );
		dict["draft"] = pxr::VtValue( false );
		dict["scale"] = pxr::VtValue( 0.5f );
		dict["version"] = pxr::VtValue( 2 );

		Assert::AreEqual( std::string( "approved=true\ndraft=false\nscale=0.5\nversion=2\n" ), DictionaryToString( dict ) );
	}

	TEST_METHOD( FormatsTokensAssetPathsAndArrays )
	{
		pxr::VtDictionary dict;
		dict["frames"] = pxr::VtValue( pxr::VtIntArray( { 1, 2, 3 } ) );
		dict["purpose"] = pxr::VtValue( pxr::TfToken( "render" ) );
		dict["texture"] = pxr::VtValue( pxr::SdfAssetPath( "./tex.png" ) );

		Assert::AreEqual( std::string( "frames=[1, 2, 3]\npurpose=render\ntexture=@./tex.png@\n" ), DictionaryToString( dict ) );
	}
};

TEST_CLASS( ReadUsdMetadataTests )
{
public:
	TEST_CLASS_INITIALIZE( RegisterPlugins )
	{
		RegisterUsdPluginsForTests();
	}

	TEST_METHOD( StoresComment )
	{
		pxr::SdfLayerRefPtr layer = pxr::SdfLayer::CreateAnonymous( ".usda" );
		layer->SetComment( "Kitchen set, lookdev pass" );
		CComPtr<IPropertyStoreCache> pStore = CreateStore();

		HRESULT hr = ReadUsdMetadata( layer, layer->GetCustomLayerData(), pStore, L"C:\\assets\\kitchen.usda" );

		Assert::AreEqual( S_OK, hr );
		Assert::AreEqual( std::wstring( L"Kitchen set, lookdev pass" ), GetString( pStore, PKEY_Comment ) );
	}

	TEST_METHOD( StoresFrameRangeAndFramesPerSecond )
	{
		pxr::SdfLayerRefPtr layer = pxr::SdfLayer::CreateAnonymous( ".usda" );
		layer->SetStartTimeCode( 1001.0 );
		layer->SetEndTimeCode( 1100.0 );
		layer->SetFramesPerSecond( 25.0 );
		layer->SetTimeCodesPerSecond( 50.0 );
		CComPtr<IPropertyStoreCache> pStore = CreateStore();

		ReadUsdMetadata( layer, layer->GetCustomLayerData(), pStore, L"C:\\assets\\shot.usda" );

		Assert::AreEqual( 1001.0, GetDouble( pStore, PKEY_USD_STARTFRAME ) );
		Assert::AreEqual( 1100.0, GetDouble( pStore, PKEY_USD_ENDFRAME ) );
		// framesPerSecond wins over timeCodesPerSecond.
		Assert::AreEqual( 25.0, GetDouble( pStore, PKEY_USD_FRAMERATE ) );
	}

	TEST_METHOD( FallsBackToTimeCodesPerSecond )
	{
		pxr::SdfLayerRefPtr layer = pxr::SdfLayer::CreateAnonymous( ".usda" );
		layer->SetTimeCodesPerSecond( 30.0 );
		CComPtr<IPropertyStoreCache> pStore = CreateStore();

		ReadUsdMetadata( layer, layer->GetCustomLayerData(), pStore, L"C:\\assets\\shot.usda" );

		Assert::AreEqual( 30.0, GetDouble( pStore, PKEY_USD_FRAMERATE ) );
	}

	TEST_METHOD( LeavesTimingEmptyWhenNotAuthored )
	{
		pxr::SdfLayerRefPtr layer = pxr::SdfLayer::CreateAnonymous( ".usda" );
		CComPtr<IPropertyStoreCache> pStore = CreateStore();

		ReadUsdMetadata( layer, layer->GetCustomLayerData(), pStore, L"C:\\assets\\static.usda" );

		Assert::AreEqual( static_cast<int>( VT_EMPTY ), static_cast<int>( GetType( pStore, PKEY_USD_STARTFRAME ) ) );
		Assert::AreEqual( static_cast<int>( VT_EMPTY ), static_cast<int>( GetType( pStore, PKEY_USD_ENDFRAME ) ) );
		Assert::AreEqual( static_cast<int>( VT_EMPTY ), static_cast<int>( GetType( pStore, PKEY_USD_FRAMERATE ) ) );
	}

	TEST_METHOD( StoresFormatDocumentationAndCustomDataWhenSchemaIsRegistered )
	{
		if( !IsUsdPropertySchemaRegistered() )
		{
			Logger::WriteMessage( L"USD property schema not registered: string PKEY_USD_* checks skipped." );
			return;
		}

		pxr::SdfLayerRefPtr layer = pxr::SdfLayer::CreateAnonymous( ".usda" );
		layer->SetDocumentation( "Main asset" );
		pxr::VtDictionary customData;
		customData["author"] = pxr::VtValue( std::string( "jb" ) );
		layer->SetCustomLayerData( customData );
		CComPtr<IPropertyStoreCache> pStore = CreateStore();

		ReadUsdMetadata( layer, layer->GetCustomLayerData(), pStore, L"C:\\assets\\kitchen.usdz" );

		Assert::AreEqual( std::wstring( L"USDZ" ), GetString( pStore, PKEY_USD_FORMAT ) );
		Assert::AreEqual( std::wstring( L"Main asset" ), GetString( pStore, PKEY_USD_DOCUMENTATION ) );
		Assert::IsTrue( GetString( pStore, PKEY_USD_CUSTOMLAYERDATA ).find( L"author=jb" ) != std::wstring::npos );
	}
};

TEST_CLASS( WriteUsdMetadataTests )
{
public:
	TEST_CLASS_INITIALIZE( RegisterPlugins )
	{
		RegisterUsdPluginsForTests();
	}

	TEST_METHOD( WritesDirtyCommentBackToLayer )
	{
		pxr::SdfLayerRefPtr layer = pxr::SdfLayer::CreateAnonymous( ".usda" );
		layer->SetComment( "old" );
		pxr::VtDictionary customData;
		CComPtr<IPropertyStoreCache> pStore = CreateStore();

		PROPVARIANT value;
		::InitPropVariantFromString( L"edited in Explorer", &value );
		pStore->SetValueAndState( PKEY_Comment, &value, PSC_DIRTY );
		::PropVariantClear( &value );

		bool bIsDirty = false;
		HRESULT hr = WriteUsdMetadata( layer, customData, pStore, bIsDirty );

		Assert::AreEqual( S_OK, hr );
		Assert::IsTrue( bIsDirty );
		Assert::AreEqual( std::string( "edited in Explorer" ), layer->GetComment() );
	}

	TEST_METHOD( IgnoresUnchangedComment )
	{
		pxr::SdfLayerRefPtr layer = pxr::SdfLayer::CreateAnonymous( ".usda" );
		layer->SetComment( "old" );
		pxr::VtDictionary customData;
		CComPtr<IPropertyStoreCache> pStore = CreateStore();

		PROPVARIANT value;
		::InitPropVariantFromString( L"same as read", &value );
		pStore->SetValueAndState( PKEY_Comment, &value, PSC_NORMAL );
		::PropVariantClear( &value );

		bool bIsDirty = false;
		WriteUsdMetadata( layer, customData, pStore, bIsDirty );

		Assert::IsFalse( bIsDirty );
		Assert::AreEqual( std::string( "old" ), layer->GetComment() );
	}

	TEST_METHOD( WritesDirtyDocumentationBackToLayer )
	{
		pxr::SdfLayerRefPtr layer = pxr::SdfLayer::CreateAnonymous( ".usda" );
		pxr::VtDictionary customData;
		CComPtr<IPropertyStoreCache> pStore = CreateStore();

		PROPVARIANT value;
		::InitPropVariantFromString( L"new doc", &value );
		pStore->SetValueAndState( PKEY_USD_DOCUMENTATION, &value, PSC_DIRTY );
		::PropVariantClear( &value );

		bool bIsDirty = false;
		WriteUsdMetadata( layer, customData, pStore, bIsDirty );

		Assert::IsTrue( bIsDirty );
		Assert::AreEqual( std::string( "new doc" ), layer->GetDocumentation() );
	}
};

TEST_CLASS( IsMetadataPropertyWritableTests )
{
public:
	TEST_METHOD( OnlyCommentIsWritable )
	{
		Assert::AreEqual( S_OK, IsMetadataPropertyWritable( PKEY_Comment ) );
		Assert::AreEqual( S_FALSE, IsMetadataPropertyWritable( PKEY_USD_DOCUMENTATION ) );
		Assert::AreEqual( S_FALSE, IsMetadataPropertyWritable( PKEY_USD_FORMAT ) );
		Assert::AreEqual( S_FALSE, IsMetadataPropertyWritable( PKEY_USD_STARTFRAME ) );
	}
};
