// USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
// Licensed under the MIT License. See LICENSE.txt for details.

#include "stdafx.h"
#include "ExplorerCommands.h"
#include "Module.h"
#include "resource.h"
#include "shared/EventViewerLog.h"
#include "shared/EventViewerMessages.h"
#include "shared/environment.h"

#include <vector>
#include <unordered_map>
#include <wincodec.h>
#pragma comment(lib, "windowscodecs.lib")

#define USD_LOG_ERROR(fmt, ...) \
    do { CStringW _m; _m.Format(fmt, __VA_ARGS__); \
         LogEventMessage(0, _m, LogEventType::Error); } while(0)

#pragma warning(push)
#pragma warning(disable:4192 4278 4471)
#import "UsdPythonToolsLocalServer.tlb" raw_interfaces_only
#import "UsdSdkToolsLocalServer.tlb" raw_interfaces_only
#pragma warning(pop)

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

static HRESULT GetFilePath( IShellItemArray *psia, CStringW &outPath )
{
    if ( !psia ) return E_INVALIDARG;
    CComPtr<IShellItem> psi;
    HRESULT hr = psia->GetItemAt( 0, &psi );
    if ( FAILED( hr ) ) return hr;
    LPWSTR pszPath = nullptr;
    hr = psi->GetDisplayName( SIGDN_FILESYSPATH, &pszPath );
    if ( FAILED( hr ) ) return hr;
    outPath = pszPath;
    CoTaskMemFree( pszPath );
    return S_OK;
}

static bool GetRendererConfig( LPCWSTR key, CComBSTR &outRenderer )
{
    auto configFiles = BuildConfigFileList( g_hInstance );
    CStringW sRenderer;
    GetPrivateProfileStringAndExpandEnvironmentStrings( L"RENDERER", key, L"", sRenderer, configFiles );
    if ( sRenderer.IsEmpty() ) return false;
    outRenderer = sRenderer;
    return true;
}

static CStringW GetIconSpec()
{
    WCHAR szMod[MAX_PATH];
    ::GetModuleFileNameW( g_hInstance, szMod, ARRAYSIZE( szMod ) );
    CStringW s;
    s.Format( L"%ls,-%d", szMod, IDI_ICON_USD );
    return s;
}

// Decode a PNG embedded as RT_RCDATA via WIC, scale to SM_CXSMICON, return 32bpp
// premultiplied-alpha HBITMAP suitable for MENUITEMINFO.hbmpItem.
static HBITMAP CreateMenuIconFromResource( UINT resId )
{
    HRSRC hRes = ::FindResourceW( g_hInstance, MAKEINTRESOURCEW( resId ), RT_RCDATA );
    if ( !hRes )
    {
        USD_LOG_ERROR( L"CreateMenuIconFromResource: FindResourceW failed for ID %u", resId );
        return nullptr;
    }
    HGLOBAL hGlobal   = ::LoadResource( g_hInstance, hRes );
    const BYTE* pData = static_cast<const BYTE*>( ::LockResource( hGlobal ) );
    DWORD cbData      = ::SizeofResource( g_hInstance, hRes );
    if ( !pData || !cbData )
    {
        USD_LOG_ERROR( L"CreateMenuIconFromResource: empty resource for ID %u", resId );
        return nullptr;
    }

    CComPtr<IWICImagingFactory> pFac;
    HRESULT hr = ::CoCreateInstance( CLSID_WICImagingFactory, nullptr,
                                     CLSCTX_INPROC_SERVER, IID_PPV_ARGS( &pFac ) );
    if ( FAILED( hr ) )
    {
        USD_LOG_ERROR( L"CreateMenuIconFromResource: WICImagingFactory hr=0x%08X", hr );
        return nullptr;
    }

    CComPtr<IWICStream> pStream;
    if ( FAILED( hr = pFac->CreateStream( &pStream ) ) ||
         FAILED( hr = pStream->InitializeFromMemory(
                          const_cast<BYTE*>( pData ), cbData ) ) )
    {
        USD_LOG_ERROR( L"CreateMenuIconFromResource: WIC stream init hr=0x%08X", hr );
        return nullptr;
    }

    CComPtr<IWICBitmapDecoder> pDec;
    if ( FAILED( hr = pFac->CreateDecoderFromStream(
                          pStream, nullptr, WICDecodeMetadataCacheOnLoad, &pDec ) ) )
    {
        USD_LOG_ERROR( L"CreateMenuIconFromResource: WIC decode hr=0x%08X resId=%u", hr, resId );
        return nullptr;
    }

    CComPtr<IWICBitmapFrameDecode> pFrame;
    if ( FAILED( hr = pDec->GetFrame( 0, &pFrame ) ) )
    {
        USD_LOG_ERROR( L"CreateMenuIconFromResource: GetFrame hr=0x%08X", hr );
        return nullptr;
    }

    const int cx = ::GetSystemMetrics( SM_CXSMICON );
    const int cy = ::GetSystemMetrics( SM_CYSMICON );

    CComPtr<IWICBitmapScaler> pScaler;
    if ( FAILED( hr = pFac->CreateBitmapScaler( &pScaler ) ) ||
         FAILED( hr = pScaler->Initialize(
                          pFrame, cx, cy, WICBitmapInterpolationModeFant ) ) )
    {
        USD_LOG_ERROR( L"CreateMenuIconFromResource: WIC scaler hr=0x%08X", hr );
        return nullptr;
    }

    CComPtr<IWICFormatConverter> pConv;
    if ( FAILED( hr = pFac->CreateFormatConverter( &pConv ) ) ||
         FAILED( hr = pConv->Initialize(
                          pScaler, GUID_WICPixelFormat32bppPBGRA,
                          WICBitmapDitherTypeNone, nullptr, 0.0,
                          WICBitmapPaletteTypeCustom ) ) )
    {
        USD_LOG_ERROR( L"CreateMenuIconFromResource: WIC format convert hr=0x%08X", hr );
        return nullptr;
    }

    BITMAPINFO bmi              = {};
    bmi.bmiHeader.biSize        = sizeof( BITMAPINFOHEADER );
    bmi.bmiHeader.biWidth       = cx;
    bmi.bmiHeader.biHeight      = -cy;
    bmi.bmiHeader.biPlanes      = 1;
    bmi.bmiHeader.biBitCount    = 32;
    bmi.bmiHeader.biCompression = BI_RGB;

    void* pBits = nullptr;
    HDC hdc     = ::GetDC( nullptr );
    HBITMAP hbm = ::CreateDIBSection( hdc, &bmi, DIB_RGB_COLORS, &pBits, nullptr, 0 );
    ::ReleaseDC( nullptr, hdc );

    if ( !hbm || !pBits )
    {
        USD_LOG_ERROR( L"CreateMenuIconFromResource: CreateDIBSection failed for ID %u", resId );
        return nullptr;
    }

    WICRect rc = { 0, 0, cx, cy };
    if ( FAILED( hr = pConv->CopyPixels(
                          &rc, cx * 4, cx * cy * 4, static_cast<BYTE*>( pBits ) ) ) )
    {
        USD_LOG_ERROR( L"CreateMenuIconFromResource: CopyPixels hr=0x%08X", hr );
        ::DeleteObject( hbm );
        return nullptr;
    }

    return hbm;
}

// Returns a cached HBITMAP for resId, created on first call.
// Bitmaps are owned by the DLL for its lifetime — no explicit cleanup needed.
static HBITMAP GetMenuIcon( UINT resId )
{
    static std::unordered_map<UINT, HBITMAP> s_cache;
    auto it = s_cache.find( resId );
    if ( it != s_cache.end() ) return it->second;
    HBITMAP hbm   = CreateMenuIconFromResource( resId );
    s_cache[resId] = hbm;
    return hbm;
}

// ---------------------------------------------------------------------------
// CRTP base — provides all IExplorerCommand boilerplate.
// TCmd must define:
//   static UINT   TitleId()         — string resource ID for the menu label
//   HRESULT       DoInvoke(LPCWSTR) — the actual operation
// TCmd may optionally define:
//   static EXPCMDFLAGS CommandFlags()            — default: ECF_DEFAULT
//   HRESULT DoEnumSubCommands(IEnumExplorerCommand**) — default: E_NOTIMPL
// ---------------------------------------------------------------------------

template<typename TCmd>
class CUsdExplorerCommandImpl : public IExplorerCommand
{
    TCmd *T() { return static_cast<TCmd *>( this ); }

public:
    STDMETHODIMP GetTitle( IShellItemArray *, LPWSTR *ppszName )
    {
        CStringW s;
        s.LoadString( g_hInstance, TCmd::TitleId() );
        return SHStrDupW( s, ppszName );
    }

    STDMETHODIMP GetIcon( IShellItemArray *, LPWSTR *ppszIcon )
    {
        return SHStrDupW( GetIconSpec(), ppszIcon );
    }

    STDMETHODIMP GetToolTip( IShellItemArray *, LPWSTR *ppszInfotip )
    {
        return SHStrDupW( L"", ppszInfotip );
    }

    STDMETHODIMP GetCanonicalName( GUID *pguid )
    {
        *pguid = __uuidof( TCmd );
        return S_OK;
    }

    STDMETHODIMP GetState( IShellItemArray *, BOOL, EXPCMDSTATE *pState )
    {
        *pState = ECS_ENABLED;
        return S_OK;
    }

    STDMETHODIMP GetFlags( EXPCMDFLAGS *pFlags )
    {
        *pFlags = TCmd::CommandFlags();
        return S_OK;
    }

    STDMETHODIMP Invoke( IShellItemArray *psia, IBindCtx * )
    {
        CStringW sPath;
        HRESULT hr = GetFilePath( psia, sPath );
        if ( FAILED( hr ) ) return hr;
        return T()->DoInvoke( sPath );
    }

    STDMETHODIMP EnumSubCommands( IEnumExplorerCommand **ppEnum )
    {
        return T()->DoEnumSubCommands( ppEnum );
    }

protected:
    static EXPCMDFLAGS CommandFlags() { return ECF_DEFAULT; }
    HRESULT DoEnumSubCommands( IEnumExplorerCommand **ppEnum )
    {
        *ppEnum = nullptr;
        return E_NOTIMPL;
    }
};

// ---------------------------------------------------------------------------
// Macro — reduces per-class boilerplate
// ---------------------------------------------------------------------------

#define USD_CMD_BOILERPLATE( cls ) \
    DECLARE_NO_REGISTRY() \
    DECLARE_NOT_AGGREGATABLE( cls ) \
    BEGIN_COM_MAP( cls ) \
        COM_INTERFACE_ENTRY( IExplorerCommand ) \
    END_COM_MAP()

// ---------------------------------------------------------------------------
// CUsdCommandEnum — dynamic IEnumExplorerCommand backed by a vector
// ---------------------------------------------------------------------------

class CUsdCommandEnum : public IEnumExplorerCommand
{
    std::vector<CComPtr<IExplorerCommand>> m_cmds;
    size_t m_idx  = 0;
    LONG   m_refs = 0;

public:
    void Add( IExplorerCommand *p ) { m_cmds.push_back( p ); }

    STDMETHODIMP_( ULONG ) AddRef()  { return ::InterlockedIncrement( &m_refs ); }
    STDMETHODIMP_( ULONG ) Release()
    {
        LONG r = ::InterlockedDecrement( &m_refs );
        if ( r == 0 ) delete this;
        return r;
    }
    STDMETHODIMP QueryInterface( REFIID riid, void **ppv )
    {
        if ( riid == IID_IUnknown || riid == __uuidof( IEnumExplorerCommand ) )
        {
            *ppv = static_cast<IEnumExplorerCommand *>( this );
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }

    STDMETHODIMP Next( ULONG celt, IExplorerCommand **pCmd, ULONG *pFetched )
    {
        ULONG n = 0;
        while ( n < celt && m_idx < m_cmds.size() )
            m_cmds[m_idx++].CopyTo( &pCmd[n++] );
        if ( pFetched ) *pFetched = n;
        return n == celt ? S_OK : S_FALSE;
    }
    STDMETHODIMP Skip( ULONG celt )
    {
        m_idx = min( m_idx + (size_t)celt, m_cmds.size() );
        return S_OK;
    }
    STDMETHODIMP Reset()                        { m_idx = 0; return S_OK; }
    STDMETHODIMP Clone( IEnumExplorerCommand ** ) { return E_NOTIMPL; }
};

// ---------------------------------------------------------------------------
// CUsdSeparatorCmd — renders a visual separator line in a flyout submenu
// ---------------------------------------------------------------------------

class CUsdSeparatorCmd : public IExplorerCommand
{
    LONG m_refs = 0;
public:
    STDMETHODIMP_( ULONG ) AddRef()  { return ::InterlockedIncrement( &m_refs ); }
    STDMETHODIMP_( ULONG ) Release()
    {
        LONG r = ::InterlockedDecrement( &m_refs );
        if ( r == 0 ) delete this;
        return r;
    }
    STDMETHODIMP QueryInterface( REFIID riid, void **ppv )
    {
        if ( riid == IID_IUnknown || riid == __uuidof( IExplorerCommand ) )
        {
            *ppv = static_cast<IExplorerCommand *>( this );
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    STDMETHODIMP GetTitle( IShellItemArray *, LPWSTR *p )      { return SHStrDupW( L"", p ); }
    STDMETHODIMP GetIcon( IShellItemArray *, LPWSTR *p )       { return SHStrDupW( L"", p ); }
    STDMETHODIMP GetToolTip( IShellItemArray *, LPWSTR *p )    { return SHStrDupW( L"", p ); }
    STDMETHODIMP GetCanonicalName( GUID *p )                   { *p = GUID_NULL; return S_OK; }
    STDMETHODIMP GetState( IShellItemArray *, BOOL, EXPCMDSTATE *p ) { *p = ECS_ENABLED; return S_OK; }
    STDMETHODIMP GetFlags( EXPCMDFLAGS *p )                    { *p = ECF_ISSEPARATOR; return S_OK; }
    STDMETHODIMP Invoke( IShellItemArray *, IBindCtx * )       { return S_OK; }
    STDMETHODIMP EnumSubCommands( IEnumExplorerCommand **p )   { *p = nullptr; return E_NOTIMPL; }
};

// ---------------------------------------------------------------------------
// Helpers for building sub-command enumerators
// ---------------------------------------------------------------------------

template<typename T>
static void AddCmdToEnum( CUsdCommandEnum *pEnum )
{
    CComObject<T> *p = nullptr;
    if ( SUCCEEDED( CComObject<T>::CreateInstance( &p ) ) )
    {
        p->AddRef();
        pEnum->Add( p );
        p->Release();
    }
}

static void AddSepToEnum( CUsdCommandEnum *pEnum )
{
    CUsdSeparatorCmd *p = new ( std::nothrow ) CUsdSeparatorCmd();
    if ( p ) { p->AddRef(); pEnum->Add( p ); p->Release(); }
}

// ---------------------------------------------------------------------------
// Sub-commands — created programmatically, not CoCreated by the shell
// ---------------------------------------------------------------------------

// --- Convert to USDC --------------------------------------------------------

class __declspec(uuid( CLSID_STR_UsdCmdCompress ))
ATL_NO_VTABLE CUsdCmdCompress
    : public CComObjectRootEx<CComSingleThreadModel>
    , public CComCoClass<CUsdCmdCompress, &__uuidof( CUsdCmdCompress )>
    , public CUsdExplorerCommandImpl<CUsdCmdCompress>
{
public:
    USD_CMD_BOILERPLATE( CUsdCmdCompress )
    static UINT TitleId() { return IDS_SHELL_CRATE; }

    STDMETHODIMP GetTitle( IShellItemArray *, LPWSTR *ppszName )
    {
        return SHStrDupW( L"USDC  (Binary)", ppszName );
    }

    HRESULT DoInvoke( LPCWSTR pszPath )
    {
        CComPtr<UsdSdkToolsLib::IUsdSdkTools> pTools;
        HRESULT hr = pTools.CoCreateInstance( __uuidof( UsdSdkToolsLib::UsdSdkTools ) );
        if ( FAILED( hr ) ) return hr;

        wchar_t sOut[MAX_PATH];
        wcscpy_s( sOut, pszPath );
        PathCchRenameExtension( sOut, ARRAYSIZE( sOut ), L"usdc" );
        return pTools->Cat( CComBSTR( pszPath ), CComBSTR( sOut ), UsdSdkToolsLib::USD_FORMAT_USDC, VARIANT_FALSE );
    }
};

// --- Convert to USDA --------------------------------------------------------

class __declspec(uuid( CLSID_STR_UsdCmdUncompress ))
ATL_NO_VTABLE CUsdCmdUncompress
    : public CComObjectRootEx<CComSingleThreadModel>
    , public CComCoClass<CUsdCmdUncompress, &__uuidof( CUsdCmdUncompress )>
    , public CUsdExplorerCommandImpl<CUsdCmdUncompress>
{
public:
    USD_CMD_BOILERPLATE( CUsdCmdUncompress )
    static UINT TitleId() { return IDS_SHELL_UNCRATE; }

    STDMETHODIMP GetTitle( IShellItemArray *, LPWSTR *ppszName )
    {
        return SHStrDupW( L"USDA  (ASCII)", ppszName );
    }

    HRESULT DoInvoke( LPCWSTR pszPath )
    {
        CComPtr<UsdSdkToolsLib::IUsdSdkTools> pTools;
        HRESULT hr = pTools.CoCreateInstance( __uuidof( UsdSdkToolsLib::UsdSdkTools ) );
        if ( FAILED( hr ) ) return hr;

        wchar_t sOut[MAX_PATH];
        wcscpy_s( sOut, pszPath );
        PathCchRenameExtension( sOut, ARRAYSIZE( sOut ), L"usda" );
        return pTools->Cat( CComBSTR( pszPath ), CComBSTR( sOut ), UsdSdkToolsLib::USD_FORMAT_USDA, VARIANT_FALSE );
    }
};

// --- Flatten ----------------------------------------------------------------

class __declspec(uuid( CLSID_STR_UsdCmdFlatten ))
ATL_NO_VTABLE CUsdCmdFlatten
    : public CComObjectRootEx<CComSingleThreadModel>
    , public CComCoClass<CUsdCmdFlatten, &__uuidof( CUsdCmdFlatten )>
    , public CUsdExplorerCommandImpl<CUsdCmdFlatten>
{
public:
    USD_CMD_BOILERPLATE( CUsdCmdFlatten )
    static UINT TitleId() { return IDS_SHELL_FLATTEN; }

    HRESULT DoInvoke( LPCWSTR pszPath )
    {
        CComPtr<UsdSdkToolsLib::IUsdSdkTools> pTools;
        HRESULT hr = pTools.CoCreateInstance( __uuidof( UsdSdkToolsLib::UsdSdkTools ) );
        if ( FAILED( hr ) ) return hr;
        return pTools->Cat( CComBSTR( pszPath ), CComBSTR( pszPath ), UsdSdkToolsLib::USD_FORMAT_INPUT, VARIANT_TRUE );
    }
};

// --- Convert to... (parent flyout: USDC + USDA + Flatten) ------------------

class __declspec(uuid( CLSID_STR_UsdCmdConvertTo ))
ATL_NO_VTABLE CUsdCmdConvertTo
    : public CComObjectRootEx<CComSingleThreadModel>
    , public CComCoClass<CUsdCmdConvertTo, &__uuidof( CUsdCmdConvertTo )>
    , public CUsdExplorerCommandImpl<CUsdCmdConvertTo>
{
public:
    USD_CMD_BOILERPLATE( CUsdCmdConvertTo )
    static UINT         TitleId()      { return IDS_SHELL_CONVERTTO; }
    static EXPCMDFLAGS  CommandFlags() { return ECF_HASSUBCOMMANDS; }

    STDMETHODIMP GetIcon( IShellItemArray *, LPWSTR *ppszIcon )
    {
        return SHStrDupW( GetIconSpec(), ppszIcon );
    }

    HRESULT DoInvoke( LPCWSTR ) { return S_OK; }

    HRESULT DoEnumSubCommands( IEnumExplorerCommand **ppEnum )
    {
        CUsdCommandEnum *pEnum = new ( std::nothrow ) CUsdCommandEnum();
        if ( !pEnum ) return E_OUTOFMEMORY;

        AddCmdToEnum<CUsdCmdCompress>( pEnum );
        AddCmdToEnum<CUsdCmdUncompress>( pEnum );
        AddSepToEnum( pEnum );
        AddCmdToEnum<CUsdCmdFlatten>( pEnum );

        pEnum->AddRef();
        *ppEnum = pEnum;
        return S_OK;
    }
};

// --- Package sub-commands ---------------------------------------------------

class __declspec(uuid( CLSID_STR_UsdCmdPackageDefault ))
ATL_NO_VTABLE CUsdCmdPackageDefault
    : public CComObjectRootEx<CComSingleThreadModel>
    , public CComCoClass<CUsdCmdPackageDefault, &__uuidof( CUsdCmdPackageDefault )>
    , public CUsdExplorerCommandImpl<CUsdCmdPackageDefault>
{
public:
    USD_CMD_BOILERPLATE( CUsdCmdPackageDefault )
    static UINT TitleId() { return IDS_SHELL_VIEW; }

    STDMETHODIMP GetTitle( IShellItemArray *, LPWSTR *ppszName )
    {
        return SHStrDupW( L"Package as USDZ", ppszName );
    }

    HRESULT DoInvoke( LPCWSTR pszPath )
    {
        CComPtr<UsdSdkToolsLib::IUsdSdkTools> pTools;
        HRESULT hr = pTools.CoCreateInstance( __uuidof( UsdSdkToolsLib::UsdSdkTools ) );
        if ( FAILED( hr ) ) return hr;

        wchar_t sOut[MAX_PATH];
        wcscpy_s( sOut, pszPath );
        PathCchRenameExtension( sOut, ARRAYSIZE( sOut ), L"usdz" );
        return pTools->Package( CComBSTR( pszPath ), CComBSTR( sOut ), UsdSdkToolsLib::USD_PACKAGE_DEFAULT, VARIANT_TRUE );
    }
};

class __declspec(uuid( CLSID_STR_UsdCmdPackageARKit ))
ATL_NO_VTABLE CUsdCmdPackageARKit
    : public CComObjectRootEx<CComSingleThreadModel>
    , public CComCoClass<CUsdCmdPackageARKit, &__uuidof( CUsdCmdPackageARKit )>
    , public CUsdExplorerCommandImpl<CUsdCmdPackageARKit>
{
public:
    USD_CMD_BOILERPLATE( CUsdCmdPackageARKit )
    static UINT TitleId() { return IDS_SHELL_VIEW; }

    STDMETHODIMP GetTitle( IShellItemArray *, LPWSTR *ppszName )
    {
        return SHStrDupW( L"Package as ARKit USDZ", ppszName );
    }

    HRESULT DoInvoke( LPCWSTR pszPath )
    {
        CComPtr<UsdSdkToolsLib::IUsdSdkTools> pTools;
        HRESULT hr = pTools.CoCreateInstance( __uuidof( UsdSdkToolsLib::UsdSdkTools ) );
        if ( FAILED( hr ) ) return hr;

        wchar_t sOut[MAX_PATH];
        wcscpy_s( sOut, pszPath );
        PathCchRenameExtension( sOut, ARRAYSIZE( sOut ), L"usdz" );
        return pTools->Package( CComBSTR( pszPath ), CComBSTR( sOut ), UsdSdkToolsLib::USD_FORMAT_APPLE_ARKIT, VARIANT_TRUE );
    }
};

// --- Package (parent flyout: Default + ARKit) -------------------------------

class __declspec(uuid( CLSID_STR_UsdCmdPackage ))
ATL_NO_VTABLE CUsdCmdPackage
    : public CComObjectRootEx<CComSingleThreadModel>
    , public CComCoClass<CUsdCmdPackage, &__uuidof( CUsdCmdPackage )>
    , public CUsdExplorerCommandImpl<CUsdCmdPackage>
{
public:
    USD_CMD_BOILERPLATE( CUsdCmdPackage )
    static UINT         TitleId()      { return IDS_SHELL_VIEW; }
    static EXPCMDFLAGS  CommandFlags() { return ECF_HASSUBCOMMANDS; }

    STDMETHODIMP GetTitle( IShellItemArray *, LPWSTR *ppszName )
    {
        return SHStrDupW( L"Package", ppszName );
    }

    HRESULT DoInvoke( LPCWSTR ) { return S_OK; }

    HRESULT DoEnumSubCommands( IEnumExplorerCommand **ppEnum )
    {
        CUsdCommandEnum *pEnum = new ( std::nothrow ) CUsdCommandEnum();
        if ( !pEnum ) return E_OUTOFMEMORY;

        AddCmdToEnum<CUsdCmdPackageDefault>( pEnum );
        AddCmdToEnum<CUsdCmdPackageARKit>( pEnum );

        pEnum->AddRef();
        *ppEnum = pEnum;
        return S_OK;
    }
};

// --- Refresh Thumbnail -------------------------------------------------------

class __declspec(uuid( CLSID_STR_UsdCmdRefreshThumb ))
ATL_NO_VTABLE CUsdCmdRefreshThumbnail
    : public CComObjectRootEx<CComSingleThreadModel>
    , public CComCoClass<CUsdCmdRefreshThumbnail, &__uuidof( CUsdCmdRefreshThumbnail )>
    , public CUsdExplorerCommandImpl<CUsdCmdRefreshThumbnail>
{
public:
    USD_CMD_BOILERPLATE( CUsdCmdRefreshThumbnail )
    static UINT TitleId() { return IDS_SHELL_REFRESHTHUMBNAIL; }

    HRESULT DoInvoke( LPCWSTR pszPath )
    {
        CComPtr<IShellItem> psi;
        HRESULT hr = ::SHCreateItemFromParsingName( pszPath, nullptr, IID_PPV_ARGS( &psi.p ) );
        if ( FAILED( hr ) ) return hr;

        CComPtr<IThumbnailCache> pCache;
        hr = pCache.CoCreateInstance( CLSID_LocalThumbnailCache );
        if ( FAILED( hr ) ) return hr;

        CComPtr<ISharedBitmap> pBitmap;
        pCache->GetThumbnail( psi, 256, WTS_FORCEEXTRACTION, &pBitmap.p, nullptr, nullptr );
        ::SHChangeNotify( SHCNE_UPDATEITEM, SHCNF_PATHW | SHCNF_FLUSHNOWAIT, pszPath, nullptr );
        return S_OK;
    }
};

// --- Stage Statistics -------------------------------------------------------

class __declspec(uuid( CLSID_STR_UsdCmdStageStats ))
ATL_NO_VTABLE CUsdCmdStageStats
    : public CComObjectRootEx<CComSingleThreadModel>
    , public CComCoClass<CUsdCmdStageStats, &__uuidof( CUsdCmdStageStats )>
    , public CUsdExplorerCommandImpl<CUsdCmdStageStats>
{
public:
    USD_CMD_BOILERPLATE( CUsdCmdStageStats )
    static UINT TitleId() { return IDS_SHELL_STATS; }

    HRESULT DoInvoke( LPCWSTR pszPath )
    {
        CComPtr<UsdPythonToolsLib::IUsdPythonTools> pTools;
        HRESULT hr = pTools.CoCreateInstance( __uuidof( UsdPythonToolsLib::UsdPythonTools ) );
        if ( FAILED( hr ) ) return hr;
        return pTools->ShowStageStats( CComBSTR( pszPath ) );
    }
};

// --- Validate (usdchecker, 1+ files) ----------------------------------------

class __declspec(uuid( CLSID_STR_UsdCmdValidate ))
ATL_NO_VTABLE CUsdCmdValidate
    : public CComObjectRootEx<CComSingleThreadModel>
    , public CComCoClass<CUsdCmdValidate, &__uuidof( CUsdCmdValidate )>
    , public CUsdExplorerCommandImpl<CUsdCmdValidate>
{
public:
    USD_CMD_BOILERPLATE( CUsdCmdValidate )
    static UINT TitleId() { return IDS_SHELL_VALIDATE; }

    // Override Invoke to support multi-selection (1+ files).
    STDMETHODIMP Invoke( IShellItemArray *psia, IBindCtx * )
    {
        if ( !psia ) return E_INVALIDARG;
        DWORD count = 0;
        psia->GetCount( &count );
        if ( count < 1 ) return E_INVALIDARG;

        CStringW sPaths;
        for ( DWORD i = 0; i < count; ++i )
        {
            CComPtr<IShellItem> psi;
            if ( FAILED( psia->GetItemAt( i, &psi ) ) ) continue;
            LPWSTR pszPath = nullptr;
            if ( FAILED( psi->GetDisplayName( SIGDN_FILESYSPATH, &pszPath ) ) ) continue;
            if ( !sPaths.IsEmpty() ) sPaths += L"|";
            sPaths += pszPath;
            CoTaskMemFree( pszPath );
        }

        if ( sPaths.IsEmpty() ) return E_FAIL;

        CComPtr<UsdPythonToolsLib::IUsdPythonTools> pTools;
        HRESULT hr = pTools.CoCreateInstance( __uuidof( UsdPythonToolsLib::UsdPythonTools ) );
        if ( FAILED( hr ) ) return hr;
        return pTools->Validate( CComBSTR( sPaths ) );
    }

    HRESULT DoInvoke( LPCWSTR ) { return S_OK; }
};

// --- Fix (usdfixbrokenpixarschemas) -----------------------------------------

class __declspec(uuid( CLSID_STR_UsdCmdFix ))
ATL_NO_VTABLE CUsdCmdFix
    : public CComObjectRootEx<CComSingleThreadModel>
    , public CComCoClass<CUsdCmdFix, &__uuidof( CUsdCmdFix )>
    , public CUsdExplorerCommandImpl<CUsdCmdFix>
{
public:
    USD_CMD_BOILERPLATE( CUsdCmdFix )
    static UINT TitleId() { return IDS_SHELL_FIX; }

    HRESULT DoInvoke( LPCWSTR pszPath )
    {
        CComPtr<UsdPythonToolsLib::IUsdPythonTools> pTools;
        HRESULT hr = pTools.CoCreateInstance( __uuidof( UsdPythonToolsLib::UsdPythonTools ) );
        if ( FAILED( hr ) ) return hr;
        return pTools->Fix( CComBSTR( pszPath ) );
    }
};

// --- Layer Stack ------------------------------------------------------------

class __declspec(uuid( CLSID_STR_UsdCmdLayerStack ))
ATL_NO_VTABLE CUsdCmdLayerStack
    : public CComObjectRootEx<CComSingleThreadModel>
    , public CComCoClass<CUsdCmdLayerStack, &__uuidof( CUsdCmdLayerStack )>
    , public CUsdExplorerCommandImpl<CUsdCmdLayerStack>
{
public:
    USD_CMD_BOILERPLATE( CUsdCmdLayerStack )
    static UINT TitleId() { return IDS_SHELL_LAYERSTACK; }

    HRESULT DoInvoke( LPCWSTR pszPath )
    {
        CComPtr<UsdPythonToolsLib::IUsdPythonTools> pTools;
        HRESULT hr = pTools.CoCreateInstance( __uuidof( UsdPythonToolsLib::UsdPythonTools ) );
        if ( FAILED( hr ) ) return hr;
        return pTools->ShowLayerStack( CComBSTR( pszPath ) );
    }
};

// --- Unpackage USDZ ---------------------------------------------------------

class __declspec(uuid( CLSID_STR_UsdCmdUnpackage ))
ATL_NO_VTABLE CUsdCmdUnpackage
    : public CComObjectRootEx<CComSingleThreadModel>
    , public CComCoClass<CUsdCmdUnpackage, &__uuidof( CUsdCmdUnpackage )>
    , public CUsdExplorerCommandImpl<CUsdCmdUnpackage>
{
public:
    USD_CMD_BOILERPLATE( CUsdCmdUnpackage )
    static UINT TitleId() { return IDS_SHELL_UNPACKAGE; }

    HRESULT DoInvoke( LPCWSTR pszPath )
    {
        CComPtr<UsdSdkToolsLib::IUsdSdkTools> pTools;
        HRESULT hr = pTools.CoCreateInstance( __uuidof( UsdSdkToolsLib::UsdSdkTools ) );
        if ( FAILED( hr ) ) return hr;
        return pTools->Unpackage( CComBSTR( pszPath ) );
    }
};

// --- Stitch (multi-selection) -----------------------------------------------

class __declspec(uuid( CLSID_STR_UsdCmdStitch ))
ATL_NO_VTABLE CUsdCmdStitch
    : public CComObjectRootEx<CComSingleThreadModel>
    , public CComCoClass<CUsdCmdStitch, &__uuidof( CUsdCmdStitch )>
    , public CUsdExplorerCommandImpl<CUsdCmdStitch>
{
public:
    USD_CMD_BOILERPLATE( CUsdCmdStitch )
    static UINT TitleId() { return IDS_SHELL_STITCH; }

    // Visible only when 2+ items are selected.
    STDMETHODIMP GetState( IShellItemArray *psia, BOOL, EXPCMDSTATE *pState )
    {
        DWORD count = 0;
        if ( psia ) psia->GetCount( &count );
        *pState = ( count >= 2 ) ? ECS_ENABLED : ECS_HIDDEN;
        return S_OK;
    }

    // Override Invoke to enumerate all selected items.
    STDMETHODIMP Invoke( IShellItemArray *psia, IBindCtx * )
    {
        if ( !psia ) return E_INVALIDARG;
        DWORD count = 0;
        psia->GetCount( &count );
        if ( count < 2 ) return E_INVALIDARG;

        CStringW sInputs;
        CStringW sFirstPath;

        for ( DWORD i = 0; i < count; ++i )
        {
            CComPtr<IShellItem> psi;
            if ( FAILED( psia->GetItemAt( i, &psi ) ) ) continue;
            LPWSTR pszPath = nullptr;
            if ( FAILED( psi->GetDisplayName( SIGDN_FILESYSPATH, &pszPath ) ) ) continue;
            if ( i == 0 ) sFirstPath = pszPath;
            if ( !sInputs.IsEmpty() ) sInputs += L"|";
            sInputs += pszPath;
            CoTaskMemFree( pszPath );
        }

        if ( sInputs.IsEmpty() ) return E_FAIL;

        CStringW sOut = sFirstPath;
        int dotPos = sOut.ReverseFind( L'.' );
        if ( dotPos >= 0 ) sOut = sOut.Left( dotPos );
        sOut += L"_stitched.usd";

        CComPtr<UsdPythonToolsLib::IUsdPythonTools> pTools;
        HRESULT hr = pTools.CoCreateInstance( __uuidof( UsdPythonToolsLib::UsdPythonTools ) );
        if ( FAILED( hr ) ) return hr;
        return pTools->Stitch( CComBSTR( sInputs ), CComBSTR( sOut ) );
    }

    HRESULT DoInvoke( LPCWSTR ) { return S_OK; }
};

// --- Diff (usddiff, exactly 2 files) ----------------------------------------

class __declspec(uuid( CLSID_STR_UsdCmdDiff ))
ATL_NO_VTABLE CUsdCmdDiff
    : public CComObjectRootEx<CComSingleThreadModel>
    , public CComCoClass<CUsdCmdDiff, &__uuidof( CUsdCmdDiff )>
    , public CUsdExplorerCommandImpl<CUsdCmdDiff>
{
public:
    USD_CMD_BOILERPLATE( CUsdCmdDiff )
    static UINT TitleId() { return IDS_SHELL_DIFF; }

    // Visible only when exactly 2 items are selected.
    STDMETHODIMP GetState( IShellItemArray *psia, BOOL, EXPCMDSTATE *pState )
    {
        DWORD count = 0;
        if ( psia ) psia->GetCount( &count );
        *pState = ( count == 2 ) ? ECS_ENABLED : ECS_HIDDEN;
        return S_OK;
    }

    // Override GetIcon to use the diff-specific icon.
    STDMETHODIMP GetIcon( IShellItemArray *, LPWSTR *ppszIcon )
    {
        return SHStrDupW( GetIconSpec(), ppszIcon );
    }

    // Override Invoke to pass both selected paths to Diff().
    STDMETHODIMP Invoke( IShellItemArray *psia, IBindCtx * )
    {
        if ( !psia ) return E_INVALIDARG;
        DWORD count = 0;
        psia->GetCount( &count );
        if ( count != 2 ) return E_INVALIDARG;

        CStringW sPaths[2];
        for ( DWORD i = 0; i < 2; ++i )
        {
            CComPtr<IShellItem> psi;
            if ( FAILED( psia->GetItemAt( i, &psi ) ) ) return E_FAIL;
            LPWSTR pszPath = nullptr;
            if ( FAILED( psi->GetDisplayName( SIGDN_FILESYSPATH, &pszPath ) ) ) return E_FAIL;
            sPaths[i] = pszPath;
            CoTaskMemFree( pszPath );
        }

        CComPtr<UsdPythonToolsLib::IUsdPythonTools> pTools;
        HRESULT hr = pTools.CoCreateInstance( __uuidof( UsdPythonToolsLib::UsdPythonTools ) );
        if ( FAILED( hr ) ) return hr;
        return pTools->Diff( CComBSTR( sPaths[0] ), CComBSTR( sPaths[1] ) );
    }

    HRESULT DoInvoke( LPCWSTR ) { return S_OK; }
};

// --- OpenUSD Documentation --------------------------------------------------

class __declspec(uuid( CLSID_STR_UsdCmdHelp ))
ATL_NO_VTABLE CUsdCmdHelp
    : public CComObjectRootEx<CComSingleThreadModel>
    , public CComCoClass<CUsdCmdHelp, &__uuidof( CUsdCmdHelp )>
    , public CUsdExplorerCommandImpl<CUsdCmdHelp>
{
public:
    USD_CMD_BOILERPLATE( CUsdCmdHelp )
    static UINT TitleId() { return IDS_SHELL_HELP; }

    STDMETHODIMP Invoke( IShellItemArray *, IBindCtx * )
    {
        SHELLEXECUTEINFOW sei = {};
        sei.cbSize = sizeof( sei );
        sei.fMask  = SEE_MASK_DEFAULT;
        sei.lpVerb = L"open";
        sei.lpFile = L"https://openusd.org/release/index.html";
        sei.nShow  = SW_SHOWNORMAL;
        return ::ShellExecuteExW( &sei ) ? S_OK : HRESULT_FROM_WIN32( ::GetLastError() );
    }

    HRESULT DoInvoke( LPCWSTR ) { return S_OK; }
};

// --- View USD Logs ----------------------------------------------------------
// Opens Windows Event Viewer; does not use the file path argument.

class __declspec(uuid( CLSID_STR_UsdCmdViewLogs ))
ATL_NO_VTABLE CUsdCmdViewLogs
    : public CComObjectRootEx<CComSingleThreadModel>
    , public CComCoClass<CUsdCmdViewLogs, &__uuidof( CUsdCmdViewLogs )>
    , public CUsdExplorerCommandImpl<CUsdCmdViewLogs>
{
public:
    USD_CMD_BOILERPLATE( CUsdCmdViewLogs )
    static UINT TitleId() { return IDS_SHELL_VIEWLOGS; }

    // Override Invoke directly — no file path needed.
    STDMETHODIMP Invoke( IShellItemArray *, IBindCtx * )
    {
        SHELLEXECUTEINFOW sei = {};
        sei.cbSize = sizeof( sei );
        sei.fMask  = SEE_MASK_DEFAULT;
        sei.lpVerb = L"open";
        sei.lpFile = L"eventvwr.msc";
        sei.nShow  = SW_SHOWNORMAL;
        return ::ShellExecuteExW( &sei ) ? S_OK : HRESULT_FROM_WIN32( ::GetLastError() );
    }

    HRESULT DoInvoke( LPCWSTR ) { return S_OK; }
};

// ---------------------------------------------------------------------------
// Top-level commands — CoCreated by the shell via ExplorerCommandHandler
// ---------------------------------------------------------------------------

// --- Edit -------------------------------------------------------------------

class __declspec(uuid( CLSID_STR_UsdCmdEdit ))
ATL_NO_VTABLE CUsdCmdEdit
    : public CComObjectRootEx<CComSingleThreadModel>
    , public CComCoClass<CUsdCmdEdit, &__uuidof( CUsdCmdEdit )>
    , public CUsdExplorerCommandImpl<CUsdCmdEdit>
{
public:
    USD_CMD_BOILERPLATE( CUsdCmdEdit )
    static UINT TitleId() { return IDS_SHELL_EDIT; }

    HRESULT DoInvoke( LPCWSTR pszPath )
    {
        CComPtr<UsdSdkToolsLib::IUsdSdkTools> pTools;
        HRESULT hr = pTools.CoCreateInstance( __uuidof( UsdSdkToolsLib::UsdSdkTools ) );
        if ( FAILED( hr ) ) return hr;
        return pTools->Edit( CComBSTR( pszPath ), VARIANT_FALSE );
    }
};

// --- USD Tools (parent submenu containing all tool sub-commands) ------------

class __declspec(uuid( CLSID_STR_UsdCmdUsdTools ))
ATL_NO_VTABLE CUsdCmdUsdTools
    : public CComObjectRootEx<CComSingleThreadModel>
    , public CComCoClass<CUsdCmdUsdTools, &__uuidof( CUsdCmdUsdTools )>
    , public CUsdExplorerCommandImpl<CUsdCmdUsdTools>
{
public:
    USD_CMD_BOILERPLATE( CUsdCmdUsdTools )
    static UINT         TitleId()      { return IDS_SHELL_USDTOOLS; }
    static EXPCMDFLAGS  CommandFlags() { return ECF_HASSUBCOMMANDS; }

    // Shell calls EnumSubCommands on parent submenu items, not Invoke.
    STDMETHODIMP Invoke( IShellItemArray *, IBindCtx * ) { return S_OK; }
    HRESULT DoInvoke( LPCWSTR ) { return S_OK; }

    HRESULT DoEnumSubCommands( IEnumExplorerCommand **ppEnum )
    {
        CUsdCommandEnum *pEnum = new ( std::nothrow ) CUsdCommandEnum();
        if ( !pEnum ) return E_OUTOFMEMORY;

        // Group 1 — edit
        AddCmdToEnum<CUsdCmdEdit>( pEnum );
        AddSepToEnum( pEnum );

        // Group 2 — format conversions
        AddCmdToEnum<CUsdCmdConvertTo>( pEnum );
        AddSepToEnum( pEnum );

        // Group 3 — packaging / stitching
        AddCmdToEnum<CUsdCmdPackage>( pEnum );
        AddCmdToEnum<CUsdCmdUnpackage>( pEnum );
        AddCmdToEnum<CUsdCmdStitch>( pEnum );
        AddSepToEnum( pEnum );

        // Group 4 — validation and diagnostics
        AddCmdToEnum<CUsdCmdValidate>( pEnum );
        AddCmdToEnum<CUsdCmdFix>( pEnum );
        AddCmdToEnum<CUsdCmdLayerStack>( pEnum );
        AddCmdToEnum<CUsdCmdDiff>( pEnum );
        AddSepToEnum( pEnum );

        // Group 5 — utilities
        AddCmdToEnum<CUsdCmdRefreshThumbnail>( pEnum );
        AddCmdToEnum<CUsdCmdStageStats>( pEnum );
        AddSepToEnum( pEnum );

        // Group 6 — logs and help
        AddCmdToEnum<CUsdCmdViewLogs>( pEnum );
        AddSepToEnum( pEnum );
        AddCmdToEnum<CUsdCmdHelp>( pEnum );

        pEnum->AddRef();
        *ppEnum = pEnum;
        return S_OK;
    }
};
OBJECT_ENTRY_AUTO( __uuidof( CUsdCmdUsdTools ), CUsdCmdUsdTools )

// ---------------------------------------------------------------------------
// CUsdContextMenu — IContextMenu + IShellExtInit for the Windows 11 modern menu.
// Registered under HKCR\.<ext>\shellex\ContextMenuHandlers\UsdShellExtension so
// that the "USD Tools >" submenu appears in the compact Win11 right-click menu
// without requiring "Show more options".
// ---------------------------------------------------------------------------

class __declspec(uuid( CLSID_STR_UsdContextMenu ))
ATL_NO_VTABLE CUsdContextMenu
    : public CComObjectRootEx<CComSingleThreadModel>
    , public CComCoClass<CUsdContextMenu, &__uuidof( CUsdContextMenu )>
    , public IShellExtInit
    , public IContextMenu
{
    CStringW m_filePath;
    std::vector<CStringW> m_filePaths;

    enum Action
    {
        ACT_EDIT,
        ACT_COMPRESS, ACT_UNCOMPRESS, ACT_FLATTEN,
        ACT_PACKAGE_DEFAULT, ACT_PACKAGE_ARKIT,
        ACT_UNPACKAGE, ACT_STITCH,
        ACT_VALIDATE, ACT_FIX, ACT_LAYER_STACK, ACT_DIFF,
        ACT_REFRESH_THUMB, ACT_STAGE_STATS, ACT_VIEW_LOGS, ACT_HELP
    };

    struct CmdEntry { Action action; UINT offset; };
    std::vector<CmdEntry> m_cmds;

public:
    DECLARE_NO_REGISTRY()
    DECLARE_NOT_AGGREGATABLE( CUsdContextMenu )
    BEGIN_COM_MAP( CUsdContextMenu )
        COM_INTERFACE_ENTRY( IShellExtInit )
        COM_INTERFACE_ENTRY( IContextMenu )
    END_COM_MAP()

    // IShellExtInit — extract all selected file paths from the data object.
    STDMETHODIMP Initialize( PCIDLIST_ABSOLUTE, IDataObject *pdo, HKEY )
    {
        if ( !pdo ) return E_INVALIDARG;
        FORMATETC fe = { CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL };
        STGMEDIUM stg = {};
        HRESULT hr = pdo->GetData( &fe, &stg );
        if ( FAILED( hr ) ) return hr;

        HDROP hDrop = reinterpret_cast<HDROP>( stg.hGlobal );
        UINT count = ::DragQueryFileW( hDrop, 0xFFFFFFFF, nullptr, 0 );

        m_filePaths.clear();
        wchar_t szPath[MAX_PATH] = {};
        for ( UINT i = 0; i < count; ++i )
        {
            szPath[0] = L'\0';
            ::DragQueryFileW( hDrop, i, szPath, ARRAYSIZE( szPath ) );
            if ( szPath[0] != L'\0' )
                m_filePaths.push_back( szPath );
        }
        if ( !m_filePaths.empty() )
            m_filePath = m_filePaths[0];

        ::ReleaseStgMedium( &stg );
        return S_OK;
    }

    // IContextMenu — build the "USD Tools >" popup and insert it into hMenu.
    STDMETHODIMP QueryContextMenu( HMENU hMenu, UINT indexMenu,
                                   UINT idCmdFirst, UINT /*idCmdLast*/, UINT uFlags )
    {
        if ( (uFlags & CMF_DEFAULTONLY) || m_filePath.IsEmpty() )
            return MAKE_HRESULT( SEVERITY_SUCCESS, 0, 0 );

        const wchar_t *pDot = wcsrchr( m_filePath, L'.' );
        wchar_t szExt[16] = {};
        if ( pDot ) wcscpy_s( szExt, pDot );
        ::CharLowerW( szExt );
        bool isUsda = wcscmp( szExt, L".usda" ) == 0;
        bool isUsdc = wcscmp( szExt, L".usdc" ) == 0;
        bool isUsdz = wcscmp( szExt, L".usdz" ) == 0;

        m_cmds.clear();
        HMENU hSub = ::CreatePopupMenu();
        if ( !hSub ) return E_OUTOFMEMORY;

        UINT nextOff = 0;

        auto AddCmd = [&]( Action act, UINT strResId, UINT iconResId )
        {
            CStringW s;
            s.LoadString( g_hInstance, strResId );
            MENUITEMINFOW mii = {};
            mii.cbSize        = sizeof( mii );
            mii.fMask         = MIIM_ID | MIIM_STRING | MIIM_STATE | MIIM_BITMAP;
            mii.fState        = MFS_ENABLED;
            mii.wID           = idCmdFirst + nextOff;
            mii.dwTypeData    = const_cast<LPWSTR>( static_cast<LPCWSTR>( s ) );
            mii.hbmpItem      = GetMenuIcon( iconResId );
            ::InsertMenuItemW( hSub, nextOff, TRUE, &mii );
            m_cmds.push_back( { act, nextOff } );
            ++nextOff;
        };

        auto AddStr = [&]( Action act, LPCWSTR title, UINT iconResId )
        {
            MENUITEMINFOW mii = {};
            mii.cbSize        = sizeof( mii );
            mii.fMask         = MIIM_ID | MIIM_STRING | MIIM_STATE | MIIM_BITMAP;
            mii.fState        = MFS_ENABLED;
            mii.wID           = idCmdFirst + nextOff;
            mii.dwTypeData    = const_cast<LPWSTR>( title );
            mii.hbmpItem      = GetMenuIcon( iconResId );
            ::InsertMenuItemW( hSub, nextOff, TRUE, &mii );
            m_cmds.push_back( { act, nextOff } );
            ++nextOff;
        };

        auto AddSep = [&]()
        {
            MENUITEMINFOW mii = {};
            mii.cbSize = sizeof( mii );
            mii.fMask  = MIIM_FTYPE;
            mii.fType  = MFT_SEPARATOR;
            ::InsertMenuItemW( hSub, nextOff, TRUE, &mii );
            ++nextOff;
        };

        if ( !isUsdz )            AddCmd( ACT_EDIT,       IDS_SHELL_EDIT,    IDR_ICON_EDIT         );
        AddSep();

        if ( !isUsdz )
        {
            HMENU hConvert = ::CreatePopupMenu();
            if ( hConvert )
            {
                UINT convOff = 0;
                auto AddConv = [&]( Action act, LPCWSTR title, UINT iconResId, bool enabled )
                {
                    MENUITEMINFOW mii = {};
                    mii.cbSize     = sizeof( mii );
                    mii.fMask      = MIIM_ID | MIIM_STRING | MIIM_STATE | MIIM_BITMAP;
                    mii.fState     = enabled ? MFS_ENABLED : MFS_GRAYED;
                    mii.wID        = idCmdFirst + nextOff;
                    mii.dwTypeData = const_cast<LPWSTR>( title );
                    mii.hbmpItem   = GetMenuIcon( iconResId );
                    ::InsertMenuItemW( hConvert, convOff, TRUE, &mii );
                    m_cmds.push_back( { act, nextOff } );
                    ++nextOff; ++convOff;
                };
                auto AddConvSep = [&]()
                {
                    MENUITEMINFOW mii = {};
                    mii.cbSize = sizeof( mii );
                    mii.fMask  = MIIM_FTYPE;
                    mii.fType  = MFT_SEPARATOR;
                    ::InsertMenuItemW( hConvert, convOff++, TRUE, &mii );
                };

                AddConv( ACT_COMPRESS,   L"USDC  (Binary)", IDR_ICON_COMPRESS,   !isUsdc );
                AddConv( ACT_UNCOMPRESS, L"USDA  (ASCII)",  IDR_ICON_UNCOMPRESS, !isUsda );
                AddConvSep();
                AddConv( ACT_FLATTEN,    L"Flatten",        IDR_ICON_FLATTEN,    true    );

                CStringW sConvert;
                sConvert.LoadString( g_hInstance, IDS_SHELL_CONVERTTO );
                MENUITEMINFOW mii = {};
                mii.cbSize     = sizeof( mii );
                mii.fMask      = MIIM_SUBMENU | MIIM_STRING | MIIM_STATE | MIIM_BITMAP;
                mii.fState     = MFS_ENABLED;
                mii.hSubMenu   = hConvert;
                mii.dwTypeData = const_cast<LPWSTR>( static_cast<LPCWSTR>( sConvert ) );
                mii.hbmpItem   = GetMenuIcon( IDR_ICON_CONVERTTO );
                ::InsertMenuItemW( hSub, nextOff, TRUE, &mii );
                ++nextOff;
            }
        }

        if ( !isUsdz )
        {
            AddSep();
            AddStr( ACT_PACKAGE_DEFAULT, L"Package as USDZ",       IDR_ICON_PACKAGE );
            AddStr( ACT_PACKAGE_ARKIT,  L"Package as ARKit USDZ", IDR_ICON_PACKAGE );
        }

        if ( isUsdz )
        {
            AddCmd( ACT_UNPACKAGE, IDS_SHELL_UNPACKAGE, IDR_ICON_UNPACK );
        }

        if ( m_filePaths.size() >= 2 )
        {
            AddCmd( ACT_STITCH, IDS_SHELL_STITCH, IDR_ICON_STITCH );
        }

        if ( m_filePaths.size() == 2 )
        {
            AddCmd( ACT_DIFF, IDS_SHELL_DIFF, IDR_ICON_DIFF );
        }

        AddSep();
        AddCmd( ACT_VALIDATE,    IDS_SHELL_VALIDATE,    IDR_ICON_CHECK );
        AddCmd( ACT_FIX,         IDS_SHELL_FIX,         IDR_ICON_FIX   );
        AddCmd( ACT_LAYER_STACK, IDS_SHELL_LAYERSTACK,  IDR_ICON_STACK );

        AddSep();
        AddCmd( ACT_REFRESH_THUMB, IDS_SHELL_REFRESHTHUMBNAIL, IDR_ICON_REFRESH_THUMB );
        AddCmd( ACT_STAGE_STATS,   IDS_SHELL_STATS,             IDR_ICON_STAGE_STATS   );
        AddSep();
        AddCmd( ACT_VIEW_LOGS, IDS_SHELL_VIEWLOGS, IDR_ICON_VIEW_LOGS );
        AddSep();
        AddCmd( ACT_HELP, IDS_SHELL_HELP, IDR_ICON_HELP );

        CStringW sTitle;
        sTitle.LoadString( g_hInstance, IDS_SHELL_USDTOOLS );

        MENUITEMINFOW mii = {};
        mii.cbSize     = sizeof( mii );
        mii.fMask      = MIIM_SUBMENU | MIIM_STRING | MIIM_STATE | MIIM_BITMAP;
        mii.fState     = MFS_ENABLED;
        mii.hSubMenu   = hSub;
        mii.dwTypeData = const_cast<LPWSTR>( static_cast<LPCWSTR>( sTitle ) );
        mii.hbmpItem   = GetMenuIcon( IDR_ICON_USD );
        if ( !::InsertMenuItemW( hMenu, indexMenu, TRUE, &mii ) )
        {
            ::DestroyMenu( hSub );
            return HRESULT_FROM_WIN32( ::GetLastError() );
        }

        return MAKE_HRESULT( SEVERITY_SUCCESS, 0, nextOff );
    }

    STDMETHODIMP InvokeCommand( LPCMINVOKECOMMANDINFO pici )
    {
        if ( !IS_INTRESOURCE( pici->lpVerb ) ) return E_INVALIDARG;
        UINT offset = LOWORD( reinterpret_cast<UINT_PTR>( pici->lpVerb ) );

        Action act = ACT_VIEW_LOGS;
        bool found = false;
        for ( const auto &e : m_cmds )
        {
            if ( e.offset == offset ) { act = e.action; found = true; break; }
        }
        if ( !found ) return S_OK;

        return Dispatch( act );
    }

    STDMETHODIMP GetCommandString( UINT_PTR, UINT, UINT *, CHAR *, UINT )
    {
        return E_NOTIMPL;
    }

private:
    HRESULT Dispatch( Action act )
    {
        LPCWSTR pszPath = m_filePath;

        if ( act == ACT_EDIT )
        {
            CComPtr<UsdSdkToolsLib::IUsdSdkTools> pTools;
            HRESULT hr = pTools.CoCreateInstance( __uuidof( UsdSdkToolsLib::UsdSdkTools ) );
            if ( FAILED( hr ) ) return hr;
            return pTools->Edit( CComBSTR( pszPath ), VARIANT_FALSE );
        }

        if ( act == ACT_REFRESH_THUMB )
        {
            CComPtr<IShellItem> psi;
            HRESULT hr = ::SHCreateItemFromParsingName( pszPath, nullptr, IID_PPV_ARGS( &psi.p ) );
            if ( FAILED( hr ) ) return hr;
            CComPtr<IThumbnailCache> pCache;
            hr = pCache.CoCreateInstance( CLSID_LocalThumbnailCache );
            if ( FAILED( hr ) ) return hr;
            CComPtr<ISharedBitmap> pBitmap;
            pCache->GetThumbnail( psi, 256, WTS_FORCEEXTRACTION, &pBitmap.p, nullptr, nullptr );
            ::SHChangeNotify( SHCNE_UPDATEITEM, SHCNF_PATHW | SHCNF_FLUSHNOWAIT, pszPath, nullptr );
            return S_OK;
        }

        if ( act == ACT_VIEW_LOGS )
        {
            SHELLEXECUTEINFOW sei = {};
            sei.cbSize = sizeof( sei );
            sei.fMask  = SEE_MASK_DEFAULT;
            sei.lpVerb = L"open";
            sei.lpFile = L"eventvwr.msc";
            sei.nShow  = SW_SHOWNORMAL;
            return ::ShellExecuteExW( &sei ) ? S_OK : HRESULT_FROM_WIN32( ::GetLastError() );
        }

        if ( act == ACT_HELP )
        {
            SHELLEXECUTEINFOW sei = {};
            sei.cbSize = sizeof( sei );
            sei.fMask  = SEE_MASK_DEFAULT;
            sei.lpVerb = L"open";
            sei.lpFile = L"https://openusd.org/release/index.html";
            sei.nShow  = SW_SHOWNORMAL;
            return ::ShellExecuteExW( &sei ) ? S_OK : HRESULT_FROM_WIN32( ::GetLastError() );
        }

        if ( act == ACT_STITCH )
        {
            CComPtr<UsdPythonToolsLib::IUsdPythonTools> pPyTools;
            HRESULT hr = pPyTools.CoCreateInstance( __uuidof( UsdPythonToolsLib::UsdPythonTools ) );
            if ( FAILED( hr ) ) return hr;

            CStringW sInputs;
            for ( const auto& path : m_filePaths )
            {
                if ( !sInputs.IsEmpty() ) sInputs += L"|";
                sInputs += path;
            }

            CStringW sOut = m_filePaths[0];
            int dotPos = sOut.ReverseFind( L'.' );
            if ( dotPos >= 0 ) sOut = sOut.Left( dotPos );
            sOut += L"_stitched.usd";

            return pPyTools->Stitch( CComBSTR( sInputs ), CComBSTR( sOut ) );
        }

        if ( act == ACT_DIFF )
        {
            if ( m_filePaths.size() != 2 ) return E_INVALIDARG;
            CComPtr<UsdPythonToolsLib::IUsdPythonTools> pPyTools;
            HRESULT hr = pPyTools.CoCreateInstance( __uuidof( UsdPythonToolsLib::UsdPythonTools ) );
            if ( FAILED( hr ) ) return hr;
            return pPyTools->Diff( CComBSTR( m_filePaths[0] ), CComBSTR( m_filePaths[1] ) );
        }

        if ( act == ACT_VALIDATE || act == ACT_FIX ||
             act == ACT_LAYER_STACK || act == ACT_STAGE_STATS )
        {
            CComPtr<UsdPythonToolsLib::IUsdPythonTools> pPyTools;
            HRESULT hr = pPyTools.CoCreateInstance( __uuidof( UsdPythonToolsLib::UsdPythonTools ) );
            if ( FAILED( hr ) ) return hr;
            if ( act == ACT_VALIDATE )
            {
                CStringW sPaths;
                for ( const auto& path : m_filePaths )
                {
                    if ( !sPaths.IsEmpty() ) sPaths += L"|";
                    sPaths += path;
                }
                return pPyTools->Validate( CComBSTR( sPaths ) );
            }
            if ( act == ACT_FIX )         return pPyTools->Fix( CComBSTR( pszPath ) );
            if ( act == ACT_LAYER_STACK ) return pPyTools->ShowLayerStack( CComBSTR( pszPath ) );
            if ( act == ACT_STAGE_STATS ) return pPyTools->ShowStageStats( CComBSTR( pszPath ) );
        }

        CComPtr<UsdSdkToolsLib::IUsdSdkTools> pTools;
        HRESULT hr = pTools.CoCreateInstance( __uuidof( UsdSdkToolsLib::UsdSdkTools ) );
        if ( FAILED( hr ) ) return hr;

        wchar_t sOut[MAX_PATH];
        wcscpy_s( sOut, pszPath );

        switch ( act )
        {
        case ACT_COMPRESS:
            PathCchRenameExtension( sOut, ARRAYSIZE( sOut ), L"usdc" );
            return pTools->Cat( CComBSTR( pszPath ), CComBSTR( sOut ),
                                UsdSdkToolsLib::USD_FORMAT_USDC, VARIANT_FALSE );
        case ACT_UNCOMPRESS:
            PathCchRenameExtension( sOut, ARRAYSIZE( sOut ), L"usda" );
            return pTools->Cat( CComBSTR( pszPath ), CComBSTR( sOut ),
                                UsdSdkToolsLib::USD_FORMAT_USDA, VARIANT_FALSE );
        case ACT_FLATTEN:
            return pTools->Cat( CComBSTR( pszPath ), CComBSTR( pszPath ),
                                UsdSdkToolsLib::USD_FORMAT_INPUT, VARIANT_TRUE );
        case ACT_PACKAGE_DEFAULT:
            PathCchRenameExtension( sOut, ARRAYSIZE( sOut ), L"usdz" );
            return pTools->Package( CComBSTR( pszPath ), CComBSTR( sOut ),
                                    UsdSdkToolsLib::USD_PACKAGE_DEFAULT, VARIANT_TRUE );
        case ACT_PACKAGE_ARKIT:
            PathCchRenameExtension( sOut, ARRAYSIZE( sOut ), L"usdz" );
            return pTools->Package( CComBSTR( pszPath ), CComBSTR( sOut ),
                                    UsdSdkToolsLib::USD_FORMAT_APPLE_ARKIT, VARIANT_TRUE );
        case ACT_UNPACKAGE:
            return pTools->Unpackage( CComBSTR( pszPath ) );
        default:
            return E_NOTIMPL;
        }
    }
};
OBJECT_ENTRY_AUTO( __uuidof( CUsdContextMenu ), CUsdContextMenu )
