# USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
# Licensed under the MIT License. See LICENSE.txt for details.

from __future__ import print_function
import sys
import os
import argparse
from pxr import Usd, UsdAppUtils, Sdf
from pxr.Usdviewq.stageView import StageView
from pxr.UsdAppUtils.complexityArgs import RefinementComplexities
import UsdPreviewHandler

from PySide6.QtCore import Qt, QTimer
from PySide6.QtGui import QAction, QActionGroup
from PySide6.QtWidgets import QWidget, QVBoxLayout, QHBoxLayout, QApplication, QMenu, QLabel, QSlider, QPushButton, QStyle
from PySide6.QtOpenGLWidgets import QOpenGLWidget

# USD 25.08 stageView.py calls QGLWidget.glDraw() which is a Qt 5 API not
# present on QOpenGLWidget (Qt 6). Map it to update() so the repaint is
# scheduled correctly and _isFirstImage gets set to False.
if not hasattr(QOpenGLWidget, 'glDraw'):
    QOpenGLWidget.glDraw = QOpenGLWidget.update

class Widget(QWidget):
    def __init__(self, stage=None, app=None, previewApp=None):
        super(Widget, self).__init__()

        self.setStyleSheet(u"")

        self.model = StageView.DefaultDataModel()


        self.view = StageView(dataModel=self.model)

        self.model.viewSettings.showHUD = False
        self.model.viewSettings.displayProxy = True

        self.app = app
        self.previewApp = previewApp

        self._selectedPath = ""

        self._primLabel = QLabel("Select object to view prim path...")
        self._primLabel.setFixedHeight(20)
        self._primLabel.setStyleSheet(
            "QLabel { background-color: #1e1e1e; color: #555555; padding: 0px 6px; }")

        self._timelineBar = self._buildTimeline()

        self.layout = QVBoxLayout(self)
        self.layout.setSpacing(0)
        self.layout.addWidget(self.view)
        self.layout.addWidget(self._primLabel)
        self.layout.addWidget(self._timelineBar)
        self.layout.setContentsMargins(0, 0, 0, 0)

        self.view.signalPrimSelected.connect(self.OnPrimSelected)
        self.view.signalPrimRollover.connect(self.OnPrimRollover)

        self.isLoadComplete = False

        if stage:
            self.setStage(stage)

    def _buildTimeline(self):
        self._isPlaying = False
        self._startTimeCode = 0.0
        self._endTimeCode = 0.0
        self._fps = 24.0

        self._playTimer = QTimer()
        self._playTimer.timeout.connect(self._advanceFrame)

        bar = QWidget()
        bar.setFixedHeight(24)
        bar.setStyleSheet("QWidget { background-color: #1e1e1e; }")

        layout = QHBoxLayout(bar)
        layout.setContentsMargins(4, 0, 4, 0)
        layout.setSpacing(4)

        self._btnPlay = QPushButton()
        self._btnPlay.setFixedSize(20, 20)
        self._btnPlay.setStyleSheet(
            "QPushButton { background: #333333; border: none; }"
            "QPushButton:hover { background: #444444; }")
        self._iconPlay = bar.style().standardIcon(QStyle.StandardPixmap.SP_MediaPlay)
        self._iconPause = bar.style().standardIcon(QStyle.StandardPixmap.SP_MediaPause)
        self._btnPlay.setIcon(self._iconPlay)
        self._btnPlay.clicked.connect(self._togglePlayback)

        self._slider = QSlider(Qt.Orientation.Horizontal)
        self._slider.setStyleSheet(
            "QSlider::groove:horizontal { background: #333333; height: 4px; }"
            "QSlider::handle:horizontal { background: #888888; width: 10px; margin: -3px 0; border-radius: 5px; }"
            "QSlider::sub-page:horizontal { background: #666666; }")
        self._slider.valueChanged.connect(self._onSliderChanged)

        self._frameLabel = QLabel("0 / 0")
        self._frameLabel.setStyleSheet("QLabel { background: transparent; color: #666666; font-size: 8pt; }")
        self._frameLabel.setFixedWidth(64)

        layout.addWidget(self._btnPlay)
        layout.addWidget(self._slider)
        layout.addWidget(self._frameLabel)

        bar.hide()
        return bar

    def _togglePlayback(self):
        if self._isPlaying:
            self._playTimer.stop()
            self._btnPlay.setIcon(self._iconPlay)
            self._isPlaying = False
            self.model.playing = False
        else:
            self._playTimer.start(int(1000.0 / self._fps))
            self._btnPlay.setIcon(self._iconPause)
            self._isPlaying = True
            self.model.playing = True

    def _advanceFrame(self):
        nextFrame = self._slider.value() + 1
        if nextFrame > int(self._endTimeCode):
            nextFrame = int(self._startTimeCode)
        self._slider.setValue(nextFrame)

    def _onSliderChanged(self, value):
        self.model.currentFrame = Usd.TimeCode(value)
        self._frameLabel.setText(f"{value} / {int(self._endTimeCode)}")
        if self._isPlaying:
            self.view.updateForPlayback()
        else:
            self.view.updateView()

    def setStage(self, stage):
        self.model.stage = stage
        if stage:
            start = stage.GetStartTimeCode()
            end = stage.GetEndTimeCode()
            # DefaultDataModel keeps currentFrame at UsdTimeCode.Default(),
            # which returns no data for time-sampled attributes (e.g. a static
            # PointInstancer that stores positions at t=startTimeCode only).
            # Mirror what usdview's AppController does: set the render time to
            # the stage start time so all authored time samples are visible.
            self.model.currentFrame = Usd.TimeCode(start)
            if end > start:
                self._startTimeCode = start
                self._endTimeCode = end
                self._fps = stage.GetFramesPerSecond() or 24.0
                self._slider.setMinimum(int(start))
                self._slider.setMaximum(int(end))
                self._slider.setValue(int(start))
                self._frameLabel.setText(f"{int(start)} / {int(end)}")
                self._timelineBar.show()

    def OnPrimSelected(self, primPath, instanceIndex, topLevelPath, topLevelInstanceIndex, hitPoint, button, modifiers):
        if primPath != Sdf.Path.emptyPath:
            self._selectedPath = str(primPath)
            self.model.selection.setPrimPath(primPath, instanceIndex)
            self._primLabel.setText(self._selectedPath)
            self._primLabel.setStyleSheet(
                "QLabel { background-color: #1e1e1e; color: #ffffff; padding: 0px 6px; }")
            self._primLabel.show()
        else:
            self._selectedPath = ""
            self.model.selection.clearPrims()
            self._primLabel.setText("Select object to view prim path...")
            self._primLabel.setStyleSheet(
                "QLabel { background-color: #1e1e1e; color: #555555; padding: 0px 6px; }")

    def OnPrimRollover(self, primPath, instanceIndex, topLevelPath, topLevelInstanceIndex, *args):
        if primPath != Sdf.Path.emptyPath:
            self._primLabel.setText(str(primPath))
            self._primLabel.setStyleSheet(
                "QLabel { background-color: #1e1e1e; color: #aaaaaa; padding: 0px 6px; }")
            self._primLabel.show()
        elif self._selectedPath:
            self._primLabel.setText(self._selectedPath)
            self._primLabel.setStyleSheet(
                "QLabel { background-color: #1e1e1e; color: #ffffff; padding: 0px 6px; }")
        else:
            if not self._selectedPath:
                self._primLabel.setText("Select object to view prim path...")
                self._primLabel.setStyleSheet(
                    "QLabel { background-color: #1e1e1e; color: #555555; padding: 0px 6px; }")

    def OnComplexity(self, action):
        self.model.viewSettings.complexity = RefinementComplexities.fromName(action.text())

    def OnShadingMode(self, action):
        self.model.viewSettings.renderMode = str(action.text())

    def OnToggleDisplayGuide(self, action):
        self.model.viewSettings.displayGuide = (self.actionDisplay_Guide.isChecked())

    def OnToggleDisplayProxy(self, action):
        self.model.viewSettings.displayProxy = (self.actionDisplay_Proxy.isChecked())

    def OnToggleDisplayRender(self, action):
        self.model.viewSettings.displayRender = (self.actionDisplay_Render.isChecked())

    def OnRendererPlugin(self, plugin):
        if not self.view.SetRendererPlugin(plugin):
            # If SetRendererPlugin failed, we need to reset the check mark
            # to whatever the currently loaded renderer is.
            for action in self.rendererPluginActionGroup.actions():
                if action.text() == self.view.rendererDisplayName:
                    action.setChecked(True)
                    break
            # Then display an error message to let the user know something
            # went wrong, and disable the menu item so it can't be selected
            # again.
            for action in self.rendererPluginActionGroup.actions():
                if action.pluginType == plugin:
                    self.statusMessage(
                        'Renderer not supported: %s' % action.text())
                    action.setText(action.text() + " (unsupported)")
                    action.setDisabled(True)
                    break

    def buildContextMenu_Renderer(self, contextMenu):
        self.rendererPluginActionGroup = QActionGroup(self)
        self.rendererPluginActionGroup.setExclusive(True)

        rendererMenu = contextMenu.addMenu("Hydra Renderer")

        pluginTypes = self.view.GetRendererPlugins()
        for pluginType in pluginTypes:
            name = self.view.GetRendererDisplayName(pluginType)
            action = rendererMenu.addAction(name)
            action.setCheckable(True)
            action.pluginType = pluginType
            self.rendererPluginActionGroup.addAction(action)

            action.triggered[bool].connect(lambda _, pluginType=pluginType:
                    self.OnRendererPlugin(pluginType))

        # Now set the checked box on the current renderer (it should
        # have been set by now).
        currentRendererId = self.view.GetCurrentRendererId()
        foundPlugin = False

        for action in self.rendererPluginActionGroup.actions():
            if action.pluginType == currentRendererId:
                action.setChecked(True)
                foundPlugin = True
                break

        # Disable the menu if no plugins were found
        rendererMenu.setEnabled(foundPlugin)

    def buildContextMenu_Complexity(self, contextMenu):
        self.actionLow = QAction("Low", self)
        self.actionLow.setObjectName(u"actionLow")
        self.actionLow.setCheckable(True)
        self.actionMedium = QAction("Medium", self)
        self.actionMedium.setCheckable(True)
        self.actionMedium.setObjectName(u"actionMedium")
        self.actionHigh = QAction("High", self)
        self.actionHigh.setCheckable(True)
        self.actionHigh.setObjectName(u"actionHigh")
        self.actionVery_High = QAction("Very High", self)
        self.actionVery_High.setCheckable(True)
        self.actionVery_High.setObjectName(u"actionVery_High")

        self.complexityGroup = QActionGroup(self)
        self.complexityGroup.setExclusive(True)
        self.complexityGroup.addAction(self.actionLow)
        self.complexityGroup.addAction(self.actionMedium)
        self.complexityGroup.addAction(self.actionHigh)
        self.complexityGroup.addAction(self.actionVery_High)
        self.complexityGroup.triggered.connect(self.OnComplexity)

        self.actionLow.setChecked(True)

        complexityMenu = contextMenu.addMenu("Complexity")
        complexityMenu.addAction(self.actionLow)
        complexityMenu.addAction(self.actionMedium)
        complexityMenu.addAction(self.actionHigh)
        complexityMenu.addAction(self.actionVery_High)

    def buildContextMenu_ShadingMode(self, contextMenu):
        self.actionWireframe = QAction("Wireframe", self)
        self.actionWireframe.setCheckable(True)
        self.actionWireframeOnSurface = QAction("WireframeOnSurface", self)
        self.actionWireframeOnSurface.setCheckable(True)
        self.actionSmooth_Shaded = QAction("Smooth Shaded", self)
        self.actionSmooth_Shaded.setCheckable(True)
        self.actionFlat_Shaded = QAction("Flat Shaded", self)
        self.actionFlat_Shaded.setCheckable(True)
        self.actionPoints = QAction("Points", self)
        self.actionPoints.setCheckable(True)
        self.actionGeom_Only = QAction("Geom Only", self)
        self.actionGeom_Only.setCheckable(True)
        self.actionGeom_Smooth = QAction("Geom Smooth", self)
        self.actionGeom_Smooth.setCheckable(True)
        self.actionGeom_Flat = QAction("Geom Flat", self)
        self.actionGeom_Flat.setCheckable(True)
        self.actionHidden_Surface_Wireframe = QAction("Hidden Surface Wireframe", self)
        self.actionHidden_Surface_Wireframe.setCheckable(True)

        self.shadingGroup = QActionGroup(self)
        self.shadingGroup.setExclusive(True)
        self.shadingGroup.addAction(self.actionWireframe)
        self.shadingGroup.addAction(self.actionWireframeOnSurface)
        self.shadingGroup.addAction(self.actionSmooth_Shaded)
        self.shadingGroup.addAction(self.actionFlat_Shaded)
        self.shadingGroup.addAction(self.actionPoints)
        self.shadingGroup.addAction(self.actionGeom_Only)
        self.shadingGroup.addAction(self.actionGeom_Smooth)
        self.shadingGroup.addAction(self.actionGeom_Flat)
        self.shadingGroup.addAction(self.actionHidden_Surface_Wireframe)
        self.shadingGroup.triggered.connect(self.OnShadingMode)

        self.actionGeom_Smooth.setChecked(True)

        complexityMenu = contextMenu.addMenu("Shading Mode")
        complexityMenu.addAction(self.actionWireframe)
        complexityMenu.addAction(self.actionWireframeOnSurface)
        complexityMenu.addAction(self.actionSmooth_Shaded)
        complexityMenu.addAction(self.actionFlat_Shaded)
        complexityMenu.addAction(self.actionPoints)
        complexityMenu.addAction(self.actionGeom_Only)
        complexityMenu.addAction(self.actionGeom_Smooth)
        complexityMenu.addAction(self.actionGeom_Flat)
        complexityMenu.addAction(self.actionHidden_Surface_Wireframe)

    def buildContextMenu_DisplayPurposes(self, contextMenu):
        self.actionDisplay_Guide = QAction("Guide", self)
        self.actionDisplay_Guide.setCheckable(True)
        self.actionDisplay_Guide.triggered.connect(self.OnToggleDisplayGuide)
        self.actionDisplay_Guide.setChecked(self.model.viewSettings.displayGuide)
        self.actionDisplay_Proxy = QAction("Proxy", self)
        self.actionDisplay_Proxy.setCheckable(True)
        self.actionDisplay_Proxy.triggered.connect(self.OnToggleDisplayProxy)
        self.actionDisplay_Proxy.setChecked(self.model.viewSettings.displayProxy)
        self.actionDisplay_Render = QAction("Render", self)
        self.actionDisplay_Render.setCheckable(True)
        self.actionDisplay_Render.triggered.connect(self.OnToggleDisplayRender)
        self.actionDisplay_Render.setChecked(self.model.viewSettings.displayRender)

        displayPurposesMenu = contextMenu.addMenu("Display Purposes")
        displayPurposesMenu.addAction(self.actionDisplay_Guide)
        displayPurposesMenu.addAction(self.actionDisplay_Proxy)
        displayPurposesMenu.addAction(self.actionDisplay_Render)

    def buildContextMenu(self):
        self.contextMenu = QMenu(self)
        self.buildContextMenu_Renderer(self.contextMenu)
        self.buildContextMenu_Complexity(self.contextMenu)
        self.buildContextMenu_ShadingMode(self.contextMenu)
        self.buildContextMenu_DisplayPurposes(self.contextMenu)


    def keyPressEvent(self, event):
        if event.key() == Qt.Key.Key_F:
            self._frameView()
        else:
            super().keyPressEvent(event)

    def _frameView(self):
        """Frame camera on the selected prim; frame the whole stage if nothing is selected."""
        stage = self.model.stage
        if not stage:
            return
        if self._selectedPath:
            self.view.updateView(resetCam=True, forceComputeBBox=True)
        else:
            pseudo_root_path = stage.GetPseudoRoot().GetPath()
            self.model.selection.setPrimPath(pseudo_root_path)
            self.view.updateView(resetCam=True, forceComputeBBox=True)
            self.model.selection.clearPrims()

    def closeEvent(self, event):
        if self._isPlaying:
            self._playTimer.stop()
        self.view.closeRenderer()

    def contextMenuEvent(self, event):
        modifiers = self.app.keyboardModifiers()

        altModifer = ((modifiers & Qt.KeyboardModifier.AltModifier) == Qt.KeyboardModifier.AltModifier)
        shiftModifer = ((modifiers & Qt.KeyboardModifier.ShiftModifier) == Qt.KeyboardModifier.ShiftModifier)
        controlModifer = ((modifiers & Qt.KeyboardModifier.ControlModifier) == Qt.KeyboardModifier.ControlModifier)

        if not altModifer and not shiftModifer and not controlModifer:
            self.buildContextMenu()
            self.contextMenu.exec(self.mapToGlobal(event.pos()))

    def timerEvent(self, event):

        if (not self.isLoadComplete) and (not self.view._isFirstImage):
            self.isLoadComplete = True
            self.previewApp.LoadComplete()

        eventData = self.previewApp.PeekEvent()
        while eventData.event != UsdPreviewHandler.UsdPreviewEvent.NoMoreEvents:

            if eventData.event == UsdPreviewHandler.UsdPreviewEvent.Quit:
                if self._isPlaying:
                    self._playTimer.stop()
                self.view.closeRenderer()
                self.model.stage = None
                self.app.quit()

            eventData = self.previewApp.PeekEvent()

def setStyleSheetUsingState(app, resourceDir):
    # We use a style file that is actually a template, which we fill
    # in from state, and is how we change app font sizes, for example.

    # Qt style sheet accepts only forward slashes as path separators
    resourceDir = resourceDir.replace("\\", "/")

    fontSize = 10
    baseFontSizeStr = "%spt" % str(fontSize)

    # The choice of 8 for smallest smallSize is for performance reasons,
    # based on the "Gotham Rounded" font used by usdviewstyle.qss . If we
    # allow it to float, we get a 2-3 hundred millisecond hit in startup
    # time as Qt (apparently) manufactures a suitably sized font.
    # Mysteriously, we don't see this cost for larger font sizes.
    smallSize = 8 if fontSize < 12 else int(round(fontSize * 0.8))
    smallFontSizeStr = "%spt" % str(smallSize)

    # Apply the style sheet to it
    sheet = open(os.path.join(resourceDir, 'usdviewstyle.qss'), 'r')
    sheetString = sheet.read() % {
        'RESOURCE_DIR'  : resourceDir,
        'BASE_FONT_SZ'  : baseFontSizeStr,
        'SMALL_FONT_SZ' : smallFontSizeStr }

    app.setStyleSheet(sheetString)


def main():
    programName = os.path.basename(sys.argv[0])
    parser = argparse.ArgumentParser(prog=programName,
        description='Preview for Windows Explorer')

    parser.add_argument('usdFilePath', action='store', type=str,
        help='USD file to preview')

    parser.add_argument('--hwnd', action='store', type=int,
        default=0,
        help='The HWND of the parent window')

    parser.add_argument('--usdviewqDir', action='store', type=str,
        help='Full path to the usdviewq python folder')

    UsdAppUtils.rendererArgs.AddCmdlineArgs(parser)

    args = parser.parse_args()

    stage = Usd.Stage.Open(args.usdFilePath)

    previewApp = UsdPreviewHandler.UsdPreviewApp()

    app = QApplication([])

    setStyleSheetUsingState(app, args.usdviewqDir)

    window = Widget(None, app, previewApp)
    window.setWindowFlags(Qt.WindowType.Popup | Qt.WindowType.Tool)
    window.setAttribute(Qt.WidgetAttribute.WA_DontShowOnScreen)
    window.show()

    # poll for events every so often
    window.startTimer( 250 )

    try:
        import ctypes
        ctypes.pythonapi.PyCObject_AsVoidPtr.restype = ctypes.c_void_p
        ctypes.pythonapi.PyCObject_AsVoidPtr.argtypes = [ctypes.py_object]
        previewApp.SetParent( args.hwnd, ctypes.pythonapi.PyCObject_AsVoidPtr(window.effectiveWinId()), ctypes.pythonapi.PyCObject_AsVoidPtr(window.view.effectiveWinId()) )
    except Exception:
        previewApp.SetParent( args.hwnd, window.effectiveWinId(), window.view.effectiveWinId() )

    window.setAttribute(Qt.WidgetAttribute.WA_DontShowOnScreen, False)

    # Set stage after the GL context exists so UsdImagingGL.Engine
    # initialises with a valid context (required for PointInstancer adapter).
    window.setStage(stage)
    stage = None

    # Make camera fit the loaded geometry
    window.view.updateView(resetCam=True, forceComputeBBox=True)

    # force a draw when hidden
    window.view.glDraw()

    window.buildContextMenu()

    # Re-frame once the event loop has processed the first scene population.
    # Covers scenes where the initial BBox (e.g. PointInstancer extent) is not
    # yet fully resolved at startup time.
    QTimer.singleShot(250, lambda: window.view.updateView(resetCam=True, forceComputeBBox=True))

    app.exec()

if __name__ == "__main__":
    sys.exit(main())
