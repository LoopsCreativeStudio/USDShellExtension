// USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
// Licensed under the MIT License. See LICENSE.txt for details.

#include "stdafx.h"
#include "StageViewWnd.h"
#include "Module.h"
#include "resource.h"


void CStageViewWnd::Init( HWND hWndToSubclass )
{
	if ( m_hWnd )
		Term();

	SubclassWindow( hWndToSubclass );
}

void CStageViewWnd::Term()
{
	UnsubclassWindow();
}

