// USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
// Licensed under the MIT License. See LICENSE.txt for details.

#include "stdafx.h"
#include "UsdMetadata.h"
#include "UsdPropertyKeys.h"
#include "shared/EventViewerLog.h"

#include <mutex>
#include <vector>

// ---------------------------------------------------------------------------
// Reporting of properties Windows refused to store
// ---------------------------------------------------------------------------

// Default sink: a warning in the Windows event log.
static void LogMetadataWarning( LPCWSTR sMessage )
{
	LogEventMessage( SHELLEXTENSION_CATEGORY, sMessage, LogEventType::Warning );
}

// Where warnings go; the unit tests swap it to capture the messages.
static void ( *s_pfnMetadataWarningSink )( LPCWSTR sMessage ) = &LogMetadataWarning;

// Properties already reported in this process, and its lock: Explorer reads
// properties of many files from several threads.
static std::vector<PROPERTYKEY> s_reportedStoreFailures;
static std::mutex s_reportedStoreFailuresLock;

// Report a property that could not be stored, once per property and per
// process: the usual cause (USD property schema not registered) fails every
// file the same way and must not flood the event log.
static void ReportStoreFailure( HRESULT hr, REFPROPERTYKEY key, LPCWSTR sPropertyName, LPCWSTR pszFilePath )
{
	if ( SUCCEEDED( hr ) )
		return;

	{
		std::lock_guard<std::mutex> guard( s_reportedStoreFailuresLock );
		for ( const PROPERTYKEY &reported : s_reportedStoreFailures )
		{
			if ( IsEqualPropertyKey( reported, key ) )
				return;
		}
		s_reportedStoreFailures.push_back( key );
	}

	CStringW sMessage;
	sMessage.Format( L"PropertyStore: the %ls property could not be stored (0x%08X) for %ls. "
	                 L"It will be missing from the Explorer Details tab and Windows Search. "
	                 L"If this is a USD property, check that UsdPropertyKeys.propdesc is registered (reinstall). "
	                 L"Reported once per process.",
	                 sPropertyName, static_cast<unsigned int>( hr ), pszFilePath );
	s_pfnMetadataWarningSink( sMessage );
}

static std::string DictionaryToString(const pxr::VtDictionary &dict, std::string prefix = "")
{
	// Exports all values on separate lines
	// Format: dict.key=value

	std::string result;

	for ( const std::pair<std::string, pxr::VtValue>& stat : dict )
	{
		if ( stat.second.GetTypeid() == typeid(pxr::VtDictionary) )
		{
			pxr::VtDictionary nestedDict = stat.second.Get<pxr::VtDictionary>();
			std::string nestedPrefix = prefix;
			if ( !nestedPrefix.empty() )
				nestedPrefix += ".";
			nestedPrefix += stat.first;
			result += DictionaryToString( nestedDict, nestedPrefix );
		}
		else
		{
			std::string name = prefix;
			if ( !name.empty() )
				name += ".";
			name += stat.first;

			std::stringstream ss;
			if ( stat.second.GetTypeid() == typeid(size_t) )
				ss << name << "=" << stat.second.Get<size_t>() << std::endl;
			else if ( stat.second.GetTypeid() == typeid(double) )
				ss << name << "=" << stat.second.Get<double>() << std::endl;
			else if ( stat.second.GetTypeid() == typeid(bool) )
				// Readable in Explorer rather than the stream default "1" / "0".
				ss << name << "=" << ( stat.second.Get<bool>() ? "true" : "false" ) << std::endl;
			else
				// Any other value (string, int, float, token, asset path,
				// arrays...) uses USD's own text form.
				ss << name << "=" << stat.second << std::endl;

			result += ss.str();
		}
	}

	return result;
}

HRESULT ReadUsdMetadata( const pxr::SdfLayerRefPtr &rootLayer, const pxr::VtDictionary &customLayerData, IPropertyStoreCache* pPropertyStoreCache, LPCWSTR pszFilePath )
{
	// Each property is stored independently: a refused one is reported and
	// the others are still filled, so the Details tab stays as complete as
	// possible.
	std::string sComment = rootLayer->GetComment();
	ReportStoreFailure( StoreStringValue( pPropertyStoreCache, PKEY_Comment, sComment.c_str() ),
	                    PKEY_Comment, L"Comment", pszFilePath );

	std::string sDocumentation = rootLayer->GetDocumentation();
	ReportStoreFailure( StoreStringValue( pPropertyStoreCache, PKEY_USD_DOCUMENTATION, sDocumentation.c_str() ),
	                    PKEY_USD_DOCUMENTATION, L"Documentation", pszFilePath );

	std::string sCustomLayerData = DictionaryToString( customLayerData );
	ReportStoreFailure( StoreStringValue( pPropertyStoreCache, PKEY_USD_CUSTOMLAYERDATA, sCustomLayerData.c_str() ),
	                    PKEY_USD_CUSTOMLAYERDATA, L"CustomLayerData", pszFilePath );

	if ( rootLayer->HasStartTimeCode() )
		ReportStoreFailure( StoreDoubleValue( pPropertyStoreCache, PKEY_USD_STARTFRAME, rootLayer->GetStartTimeCode() ),
		                    PKEY_USD_STARTFRAME, L"StartFrame", pszFilePath );

	if ( rootLayer->HasEndTimeCode() )
		ReportStoreFailure( StoreDoubleValue( pPropertyStoreCache, PKEY_USD_ENDFRAME, rootLayer->GetEndTimeCode() ),
		                    PKEY_USD_ENDFRAME, L"EndFrame", pszFilePath );

	if ( rootLayer->HasFramesPerSecond() )
		ReportStoreFailure( StoreDoubleValue( pPropertyStoreCache, PKEY_USD_FRAMERATE, rootLayer->GetFramesPerSecond() ),
		                    PKEY_USD_FRAMERATE, L"FrameRate", pszFilePath );
	else if ( rootLayer->HasTimeCodesPerSecond() )
		ReportStoreFailure( StoreDoubleValue( pPropertyStoreCache, PKEY_USD_FRAMERATE, rootLayer->GetTimeCodesPerSecond() ),
		                    PKEY_USD_FRAMERATE, L"FrameRate", pszFilePath );

	{
		// Derive the format from the original file path.
		// GetRealPath() returns empty for anonymous layers opened via OpenAsAnonymous.
		const wchar_t *pszExt = ::wcsrchr( pszFilePath, L'.' );
		if ( pszExt && pszExt[1] != L'\0' )
		{
			CStringW sExtW( pszExt + 1 );
			sExtW.MakeUpper();
			ReportStoreFailure( StoreStringValue( pPropertyStoreCache, PKEY_USD_FORMAT, static_cast<LPCWSTR>( sExtW ) ),
			                    PKEY_USD_FORMAT, L"Format", pszFilePath );
		}
	}

	return S_OK;
}

HRESULT WriteUsdMetadata( pxr::SdfLayerRefPtr &rootLayer, pxr::VtDictionary &customLayerData, IPropertyStoreCache *pPropertyStoreCache, bool &bIsDirty )
{
	UNREFERENCED_PARAMETER( customLayerData );

	HRESULT hr;
	PSC_STATE state;

	hr = pPropertyStoreCache->GetState( PKEY_Comment, &state);
	if ( SUCCEEDED( hr ) && state == PSC_DIRTY )
	{
		std::string sValue;
		hr = GetValueAsUTF8( pPropertyStoreCache, PKEY_Comment, sValue );
		if ( SUCCEEDED( hr ) )
		{
			rootLayer->SetComment( sValue );
			bIsDirty = true;
		}
	}

	hr = pPropertyStoreCache->GetState( PKEY_USD_DOCUMENTATION, &state);
	if ( SUCCEEDED( hr ) && state == PSC_DIRTY )
	{
		std::string sValue;
		hr = GetValueAsUTF8( pPropertyStoreCache, PKEY_USD_DOCUMENTATION, sValue );
		if ( SUCCEEDED( hr ) )
		{
			rootLayer->SetDocumentation( sValue );
			bIsDirty = true;
		}
	}

	return S_OK;
}

HRESULT IsMetadataPropertyWritable( REFPROPERTYKEY key )
{
	if ( IsEqualPropertyKey( key, PKEY_Comment ) /*||
		 IsEqualPropertyKey( key, PKEY_USD_DOCUMENTATION )*/ )
		return S_OK;

	return S_FALSE;
}