// USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
// Licensed under the MIT License. See LICENSE.txt for details.

#include "stdafx.h"
#include "UsdPreviewHandlerEvent.h"
#include "UsdPreviewHandlerMgr.h"

using namespace pxr_boost::python;

struct UsdPreviewApp
{
	void SetParent( uint64_t nWndParent, uint64_t nWndChild, uint64_t nWndStageView );
	UsdPreviewEventData PeekEvent();
	void LoadComplete();
};

PXR_BOOST_PYTHON_MODULE( UsdPreviewHandler )
{
	using namespace pxr_boost::python;

	enum_<eUsdPreviewEvent>( "UsdPreviewEvent" )
		.value( "NoMoreEvents", USDPREVIEWEVENT_INVALID)
		.value( "Quit", USDPREVIEWEVENT_QUIT)
		;

	class_<UsdPreviewEventData>( "UsdPreviewEventData", "help", no_init )
		.def_readonly("event", &UsdPreviewEventData::event)
		.def_readonly("data1", &UsdPreviewEventData::data1)
		.def_readonly("data2", &UsdPreviewEventData::data2)
		;

	class_<UsdPreviewApp>( "UsdPreviewApp", "help", init<>() )
		.def( "SetParent", &UsdPreviewApp::SetParent )
		.def( "PeekEvent", &UsdPreviewApp::PeekEvent )
		.def( "LoadComplete", &UsdPreviewApp::LoadComplete )
		;
}

void UsdPreviewApp::SetParent( uint64_t nWndParent, uint64_t nWndChild, uint64_t nWndStageView )
{
	HWND hWndParent = reinterpret_cast<HWND>(nWndParent);
	HWND hWndChild = reinterpret_cast<HWND>(nWndChild);
	HWND hWndStageView = reinterpret_cast<HWND>(nWndStageView);

	CUsdPreviewHandlerMgr::GetSingleton().SetParent(hWndParent, hWndChild, hWndStageView);
}

UsdPreviewEventData UsdPreviewApp::PeekEvent()
{
	return CUsdPreviewHandlerMgr::GetSingleton().PeekEvent();
}

void UsdPreviewApp::LoadComplete()
{
	CUsdPreviewHandlerMgr::GetSingleton().LoadComplete();
}

