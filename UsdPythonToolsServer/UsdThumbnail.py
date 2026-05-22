# USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
# Licensed under the MIT License. See LICENSE.txt for details.

# This is a fix for USD issue #1521
# https://github.com/PixarAnimationStudios/USD/issues/1521

import sys
from importlib.util import spec_from_loader, module_from_spec
from importlib.machinery import SourceFileLoader

def _SetupOpenGLContextFix(width=100, height=100):
    from PySide6.QtOpenGLWidgets import QOpenGLWidget
    from PySide6.QtGui import QSurfaceFormat
    from PySide6.QtWidgets import QApplication
    from PySide6 import QtCore

    _application = QApplication(sys.argv)

    glFormat = QSurfaceFormat()
    glFormat.setSamples(4)

    glWidget = QOpenGLWidget()
    glWidget.setFormat(glFormat)
    glWidget.setFixedSize(width, height)
    glWidget.setAttribute(QtCore.Qt.WidgetAttribute.WA_DontShowOnScreen)
    glWidget.show()
    glWidget.setHidden(True)

    return glWidget

def main():
    import os
    from pxr import Plug
    # PlugRegistry C++ singleton may have initialised at DLL-load time, before
    # SetupPythonEnvironment() set PXR_PLUGINPATH_NAME.  Explicitly register
    # each path now so renderer plugins (hdStorm, etc.) are always discoverable.
    for path in filter(None, os.environ.get('PXR_PLUGINPATH_NAME', '').split(';')):
        Plug.Registry().RegisterPlugins(path)

    spec = spec_from_loader("usdrecord", SourceFileLoader("usdrecord", sys.argv[0]))
    usdrecord = module_from_spec(spec)
    spec.loader.exec_module(usdrecord)

    usdrecord._SetupOpenGLContext = _SetupOpenGLContextFix
    return usdrecord.main()

if __name__ == '__main__':
    sys.exit(main())
