// USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
// Licensed under the MIT License. See LICENSE.txt for details.

#pragma once

enum eUsdPreviewEvent
{
	USDPREVIEWEVENT_INVALID,
	USDPREVIEWEVENT_QUIT,
	USDPREVIEWEVENT_RESIZE,
	USDPREVIEWEVENT_RESIZERECT,
	USDPREVIEWEVENT_SETWINDOW,
};

struct UsdPreviewEventData
{
	eUsdPreviewEvent event;
	intptr_t data1;
	intptr_t data2;
};

typedef void (*FNUSDPREVIEWPUSHEVENT)(eUsdPreviewEvent event, intptr_t data1, intptr_t data2);

typedef HWND (*FNUSDPREVIEWGETPREVIEWWINDOW)();