# USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
# Licensed under the MIT License. See LICENSE.txt for details.
#
# usdview wrapper:
#   Layer 0: clear PXR_PLUGINPATH_NAME before any pxr import.
#   Layer 1: Tf.Error.commentary patch (CP1252/UTF-8 safety).
#   Layer 2: AppController._openStage patch (sys.exit interception).
#   Layer 3: loading splash + foreground activation.

import sys
import os

# ── Layer 3a: loading splash ───────────────────────────────────────────────────
# Shown in a background thread while pxr libraries initialise (can take 10-30s).
# Closed automatically when AppController is created.
try:
    import ctypes as _ct
    import threading as _th

    _u32 = _ct.windll.user32
    _k32 = _ct.windll.kernel32

    # Set argtypes/restype for every Win32 call used in this section so that
    # 64-bit pointer/LPARAM values are not truncated to 32-bit c_int (overflow).
    _u32.CreateWindowExW.restype  = _ct.c_void_p
    _u32.BeginPaint.restype       = _ct.c_void_p
    _u32.PostMessageW.argtypes    = [_ct.c_void_p, _ct.c_uint, _ct.c_size_t, _ct.c_ssize_t]
    _u32.PostMessageW.restype     = _ct.c_int
    _u32.DefWindowProcW.restype   = _ct.c_longlong
    _u32.DefWindowProcW.argtypes  = [_ct.c_void_p, _ct.c_uint, _ct.c_size_t, _ct.c_ssize_t]

    _WM_CLOSE     = 0x0010
    _WM_PAINT     = 0x000F
    _WM_DESTROY   = 0x0002
    _SPLASH_CLASS = "UsdViewSplash"
    _SPLASH_TITLE = "USD Shell Extension"
    _SPLASH_TEXT  = (
        "Opening usdview, please wait…\n\n"
        "First launch can take several seconds while\n"
        "USD libraries are initialised."
    )
    _splash_hwnd = [None]

    _WNDPROC = _ct.WINFUNCTYPE(
        _ct.c_longlong,
        _ct.c_void_p, _ct.c_uint, _ct.c_size_t, _ct.c_ssize_t
    )

    class _WNDCLASSW(_ct.Structure):
        _fields_ = [
            ("style",         _ct.c_uint),
            ("lpfnWndProc",   _WNDPROC),
            ("cbClsExtra",    _ct.c_int),
            ("cbWndExtra",    _ct.c_int),
            ("hInstance",     _ct.c_void_p),
            ("hIcon",         _ct.c_void_p),
            ("hCursor",       _ct.c_void_p),
            ("hbrBackground", _ct.c_void_p),
            ("lpszMenuName",  _ct.c_wchar_p),
            ("lpszClassName", _ct.c_wchar_p),
        ]

    class _RECT(_ct.Structure):
        _fields_ = [("left", _ct.c_long), ("top",    _ct.c_long),
                    ("right",_ct.c_long), ("bottom", _ct.c_long)]

    class _PAINTSTRUCT(_ct.Structure):
        _fields_ = [("hdc",         _ct.c_void_p),
                    ("fErase",      _ct.c_int),
                    ("rcPaint",     _RECT),
                    ("fRestore",    _ct.c_int),
                    ("fIncUpdate",  _ct.c_int),
                    ("rgbReserved", _ct.c_byte * 32)]

    class _MSG(_ct.Structure):
        _fields_ = [("hwnd",    _ct.c_void_p),
                    ("message", _ct.c_uint),
                    ("wParam",  _ct.c_size_t),
                    ("lParam",  _ct.c_ssize_t),
                    ("time",    _ct.c_ulong),
                    ("pt_x",    _ct.c_long),
                    ("pt_y",    _ct.c_long)]

    def _splash_proc(hwnd, msg, wp, lp):
        if msg == _WM_DESTROY:
            _u32.PostQuitMessage(0)
            return 0
        if msg == _WM_PAINT:
            ps  = _PAINTSTRUCT()
            hdc = _u32.BeginPaint(hwnd, _ct.byref(ps))
            rc  = _RECT()
            _u32.GetClientRect(hwnd, _ct.byref(rc))
            rc.left += 16
            rc.right -= 16
            rc.top += 20
            rc.bottom -= 16
            # DT_CENTER = 0x0001, DT_WORDBREAK = 0x0010
            _u32.DrawTextW(hdc, _SPLASH_TEXT, -1, _ct.byref(rc), 0x0011)
            _u32.EndPaint(hwnd, _ct.byref(ps))
            return 0
        return _u32.DefWindowProcW(hwnd, msg, wp, lp)

    _splash_proc_ref = _WNDPROC(_splash_proc)

    def _run_splash():
        try:
            hInst = _k32.GetModuleHandleW(None)
            wc = _WNDCLASSW()
            wc.style         = 0x0003           # CS_HREDRAW | CS_VREDRAW
            wc.lpfnWndProc   = _splash_proc_ref
            wc.hInstance     = hInst
            wc.hbrBackground = _ct.c_void_p(16) # COLOR_BTNFACE + 1
            wc.lpszClassName = _SPLASH_CLASS
            _u32.RegisterClassW(_ct.byref(wc))

            sw = _u32.GetSystemMetrics(0)        # SM_CXSCREEN
            sh = _u32.GetSystemMetrics(1)        # SM_CYSCREEN
            w, h = 420, 150
            hwnd = _u32.CreateWindowExW(
                0x00000009,                      # WS_EX_TOPMOST | WS_EX_DLGMODALFRAME
                _SPLASH_CLASS, _SPLASH_TITLE,
                0x90000000,                      # WS_POPUP | WS_VISIBLE
                (sw - w) // 2, (sh - h) // 2, w, h,
                None, None, hInst, None
            )
            _splash_hwnd[0] = hwnd
            _u32.UpdateWindow(hwnd)

            msg = _MSG()
            while _u32.GetMessageW(_ct.byref(msg), None, 0, 0) != 0:
                _u32.TranslateMessage(_ct.byref(msg))
                _u32.DispatchMessageW(_ct.byref(msg))
        except Exception:
            pass

    _th.Thread(target=_run_splash, daemon=True).start()

    def _close_splash():
        hwnd, _splash_hwnd[0] = _splash_hwnd[0], None
        if hwnd:
            _u32.PostMessageW(hwnd, _WM_CLOSE, 0, 0)

except Exception:
    def _close_splash():
        pass

# ── Layer 0: remove duplicate plugin path before pxr initialises ──────────────
os.environ.pop('PXR_PLUGINPATH_NAME', None)

import importlib.util

# ── Layer 1: Tf.Error.commentary — CP1252 safety ──────────────────────────────
try:
    from pxr import Tf as _Tf
    _orig_commentary_fget = _Tf.Error.commentary.fget

    def _safe_commentary(self):
        try:
            return _orig_commentary_fget(self)
        except (UnicodeDecodeError, UnicodeEncodeError):
            return ''

    _Tf.Error.commentary = property(_safe_commentary)
except Exception:
    pass

# ── Layer 2: _openStage — trap sys.exit and recover ───────────────────────────
try:
    from pxr import Usdviewq, Usd, Sdf, Tf as _Tf

    _orig_openStage = Usdviewq.AppController._openStage

    def _safe_openStage(self, usdFilePath, *args, **kwargs):
        # Intercept sys.exit(1) that _openStage calls on Tf.ErrorException.
        _orig_exit = sys.exit
        _exit_intercepted = [False]

        def _trap(code=0):
            _exit_intercepted[0] = True
            raise SystemExit(code)

        sys.exit = _trap
        try:
            return _orig_openStage(self, usdFilePath, *args, **kwargs)
        except SystemExit:
            pass
        finally:
            sys.exit = _orig_exit

        if not _exit_intercepted[0]:
            return None

        # _openStage called sys.exit after Tf.ErrorException.
        # The Sdf layer may already be in the registry — recover it.
        try:
            layer = Sdf.Layer.Find(usdFilePath)
            if layer is None:
                try:
                    layer = Sdf.Layer.FindOrOpen(usdFilePath)
                except Exception:
                    layer = None

            sessionLayer = Sdf.Layer.CreateAnonymous()

            for open_fn in [
                (lambda lyr=layer, sl=sessionLayer: Usd.Stage.Open(lyr, sl)) if layer else None,
                lambda: Usd.Stage.Open(usdFilePath, Usd.Stage.LoadNone),
                lambda: Usd.Stage.Open(usdFilePath),
            ]:
                if open_fn is None:
                    continue
                try:
                    stage = open_fn()
                    if stage:
                        stage.SetEditTarget(stage.GetSessionLayer())
                        return stage
                except Exception:
                    continue
        except Exception:
            pass

        return None

    Usdviewq.AppController._openStage = _safe_openStage

    # ── Layer 3b: close splash + icon + bring window to foreground ───────────
    _orig_init = Usdviewq.AppController.__init__

    def _patched_init(self, *args, **kwargs):
        _orig_init(self, *args, **kwargs)
        _close_splash()
        try:
            # Import PySide6 directly — pxr.Usdviewq does not always re-export
            # QtCore/QtWidgets/QtGui and would raise ImportError silently.
            try:
                from PySide6 import QtCore, QtWidgets, QtGui
            except ImportError:
                from PySide2 import QtCore, QtWidgets, QtGui

            import ctypes
            _u32 = ctypes.windll.user32
            _k32 = ctypes.windll.kernel32
            _u32.LoadImageW.restype              = ctypes.c_void_p
            _u32.GetForegroundWindow.restype      = ctypes.c_void_p
            _u32.GetWindowThreadProcessId.restype = ctypes.c_ulong
            _u32.SendMessageW.restype             = ctypes.c_longlong
            _u32.SendMessageW.argtypes            = [ctypes.c_void_p, ctypes.c_uint,
                                                     ctypes.c_size_t, ctypes.c_ssize_t]
            _k32.GetCurrentThreadId.restype       = ctypes.c_ulong

            _self = self

            def _activate():
                # Prefer _mainWindow attribute; fall back to largest visible widget.
                w = getattr(_self, '_mainWindow', None)
                if w is None or not w.isVisible():
                    candidates = [x for x in QtWidgets.QApplication.topLevelWidgets()
                                  if x.isVisible()]
                    if not candidates:
                        return
                    w = max(candidates, key=lambda x: x.width() * x.height())

                hwnd = int(w.winId())

                # ── Icon ──────────────────────────────────────────────────
                _ico = os.path.join(
                    os.path.dirname(os.path.dirname(sys.executable)), 'usd.ico')
                if os.path.exists(_ico):
                    # Win32: LoadImageW + WM_SETICON (reliable, bypasses Qt cache)
                    LR_LOADFROMFILE = 0x00000010
                    LR_DEFAULTSIZE  = 0x00000040
                    hicon = _u32.LoadImageW(
                        None, _ico, 1, 0, 0, LR_LOADFROMFILE | LR_DEFAULTSIZE)
                    if hicon:
                        _u32.SendMessageW(hwnd, 0x0080, 1, hicon)  # WM_SETICON ICON_BIG
                        _u32.SendMessageW(hwnd, 0x0080, 0, hicon)  # WM_SETICON ICON_SMALL
                    # Qt: also covers taskbar button grouping
                    _qicon = QtGui.QIcon(_ico)
                    if not _qicon.isNull():
                        w.setWindowIcon(_qicon)
                        QtWidgets.QApplication.setWindowIcon(_qicon)

                # ── Foreground ────────────────────────────────────────────
                # Step 1: Z-order — briefly topmost then back (no permission needed)
                _SWP = 0x0003  # SWP_NOMOVE | SWP_NOSIZE
                _u32.SetWindowPos(hwnd, -1, 0, 0, 0, 0, _SWP)  # HWND_TOPMOST
                _u32.SetWindowPos(hwnd, -2, 0, 0, 0, 0, _SWP)  # HWND_NOTOPMOST
                # Step 2: attach to the foreground thread's input queue
                fg_hwnd  = _u32.GetForegroundWindow()
                fg_tid   = _u32.GetWindowThreadProcessId(fg_hwnd, None)
                my_tid   = _k32.GetCurrentThreadId()
                attached = bool(fg_tid and fg_tid != my_tid)
                if attached:
                    _u32.AttachThreadInput(my_tid, fg_tid, True)
                _u32.BringWindowToTop(hwnd)
                _u32.SetForegroundWindow(hwnd)
                if attached:
                    _u32.AttachThreadInput(my_tid, fg_tid, False)
                w.raise_()

            QtCore.QTimer.singleShot(500, _activate)
        except Exception:
            pass

    Usdviewq.AppController.__init__ = _patched_init

except Exception:
    _close_splash()

# ── launch usdview ─────────────────────────────────────────────────────────────
# argv layout: [wrapper.py, usdview_path, usdview_args...]
sys.argv = sys.argv[1:]
_script = sys.argv[0]

# SourceFileLoader is explicit: usdview has no .py extension.
from importlib.machinery import SourceFileLoader  # noqa: E402
from importlib.util import spec_from_loader  # noqa: E402
spec = spec_from_loader('__main__', SourceFileLoader('__main__', _script))
mod = importlib.util.module_from_spec(spec)
sys.modules['__main__'] = mod
spec.loader.exec_module(mod)
