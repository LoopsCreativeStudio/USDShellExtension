# USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
# Licensed under the MIT License. See LICENSE.txt for details.

from __future__ import print_function
import sys
import os


def _setup_gl_context():
    """Create an offscreen OpenGL context and make it current.

    Returns (app, surface). Both must stay alive until recording is done.
    Uses QOffscreenSurface + QOpenGLContext so no window-system involvement
    occurs and the context is never released by paint events.
    """
    from PySide6.QtOpenGL import (
        QOpenGLFramebufferObject,
        QOpenGLFramebufferObjectFormat,
    )
    from PySide6.QtCore import QSize
    from PySide6.QtGui import (
        QOpenGLContext,
        QOffscreenSurface,
        QSurfaceFormat,
    )
    from PySide6.QtWidgets import QApplication

    app = QApplication.instance() or QApplication(sys.argv)

    fmt = QSurfaceFormat()
    fmt.setSamples(4)

    surface = QOffscreenSurface()
    surface.setFormat(fmt)
    surface.create()

    context = QOpenGLContext()
    context.setFormat(fmt)
    context.create()
    context.makeCurrent(surface)

    fbo_fmt = QOpenGLFramebufferObjectFormat()
    fbo = QOpenGLFramebufferObject(QSize(1, 1), fbo_fmt)
    fbo.bind()

    # Keep all objects alive on the surface so they are not garbage-collected.
    surface._context = context
    surface._fbo = fbo

    return app, surface


def _make_framing_camera(stage, time_code):
    """Create a square (1:1) perspective camera on the session layer.

    Frames the full world bounding box with a 10% margin. Writes to the
    session layer so the authored stage is not modified. Returns an invalid
    UsdGeom.Camera if the scene has no visible geometry.
    """
    import math
    from pxr import Gf, Usd, UsdGeom, Sdf

    bbox_cache = UsdGeom.BBoxCache(
        time_code,
        [UsdGeom.Tokens.default_, UsdGeom.Tokens.proxy],
        useExtentsHint=True,
    )
    world_box = bbox_cache.ComputeWorldBound(stage.GetPseudoRoot())
    rng = world_box.GetRange()
    if rng.IsEmpty():
        return UsdGeom.Camera()

    mn, mx = rng.GetMin(), rng.GetMax()
    centroid = (mn + mx) * 0.5

    z_up = (UsdGeom.GetStageUpAxis(stage) == 'Z')
    if z_up:
        # Height along Z, width along X, depth along Y; place camera on -Y.
        half_h = max(abs(mx[0] - centroid[0]), abs(mn[0] - centroid[0]))
        half_v = max(abs(mx[2] - centroid[2]), abs(mn[2] - centroid[2]))
        half_d = max(abs(mx[1] - centroid[1]), abs(mn[1] - centroid[1]))
        up_vec  = Gf.Vec3d(0, 0, 1)
        eye_dir = Gf.Vec3d(0, -1, 0)
    else:
        # Height along Y, width along X, depth along Z; place camera on -Z.
        half_h = max(abs(mx[0] - centroid[0]), abs(mn[0] - centroid[0]))
        half_v = max(abs(mx[1] - centroid[1]), abs(mn[1] - centroid[1]))
        half_d = max(abs(mx[2] - centroid[2]), abs(mn[2] - centroid[2]))
        up_vec  = Gf.Vec3d(0, 1, 0)
        eye_dir = Gf.Vec3d(0, 0, 1)

    MARGIN    = 1.1
    fit_half  = max(half_h, half_v) * MARGIN
    half_fov  = math.radians(22.5)   # 45-degree full FOV
    aperture  = 36.0                  # mm, standard 35mm frame
    focal_len = (aperture * 0.5) / math.tan(half_fov)
    dist      = fit_half / math.tan(half_fov)

    eye = Gf.Vec3d(centroid) + eye_dir * (dist + half_d)

    # Camera-to-world matrix, Gf row-vector convention:
    #   row 0 = camera +X (right) in world
    #   row 1 = camera +Y (up)    in world
    #   row 2 = camera +Z (back)  in world   (+Z is away from scene in USD/GL)
    #   row 3 = camera position
    z_cam = (eye - Gf.Vec3d(centroid)).GetNormalized()
    fwd   = -z_cam
    x_cam = Gf.Cross(fwd, up_vec).GetNormalized()
    y_cam = Gf.Cross(x_cam, fwd)

    cam_xform = Gf.Matrix4d(
        x_cam[0], x_cam[1], x_cam[2], 0.0,
        y_cam[0], y_cam[1], y_cam[2], 0.0,
        z_cam[0], z_cam[1], z_cam[2], 0.0,
        eye[0],   eye[1],   eye[2],   1.0,
    )

    near = max(1.0, dist - half_d)
    far  = dist + half_d + fit_half * 2.0 + 1.0

    with Usd.EditContext(stage, stage.GetSessionLayer()):
        cam_prim = stage.DefinePrim(Sdf.Path('/ThumbnailCamera'), 'Camera')
        usd_cam  = UsdGeom.Camera(cam_prim)
        usd_cam.GetHorizontalApertureAttr().Set(aperture)
        usd_cam.GetVerticalApertureAttr().Set(aperture)   # 1:1 square output
        usd_cam.GetFocalLengthAttr().Set(focal_len)
        usd_cam.GetClippingRangeAttr().Set(Gf.Vec2f(near, far))
        UsdGeom.Xformable(cam_prim).MakeMatrixXform().Set(cam_xform)

    return usd_cam


def _stage_has_lights(stage):
    """Return True if the stage contains any authored UsdLux lights.

    Used to decide whether to enable the camera headlight: if the scene
    already provides lighting, the headlight causes overexposure.
    """
    from pxr import UsdLux
    for prim in stage.Traverse():
        if prim.HasAPI(UsdLux.LightAPI):
            return True
    return False


def _find_stage_camera(stage):
    """Return the best authored camera prim in the stage, or None.

    Preference order: pipeline primary camera name, then any UsdGeom.Camera.
    """
    from pxr import UsdGeom, UsdUtils, UsdAppUtils

    cam = UsdAppUtils.GetCameraAtPath(stage, UsdUtils.GetPrimaryCameraName())
    if cam and cam.GetPrim().IsValid():
        return cam

    for prim in stage.Traverse():
        if prim.IsA(UsdGeom.Camera):
            return UsdGeom.Camera(prim)

    return None


def main():
    # --- Step 1: narrow PXR_PLUGINPATH_NAME before any pxr import. ---
    # The COM parent sets it to the install dir, which contains a plugInfo.json
    # that loads UsdShellExtension.dll (our ArResolver) into the subprocess.
    # That DLL is not designed for this context and corrupts UsdImagingGL.
    # We redirect to the SDK's plugin/usd/ (derived from PYTHONPATH), which
    # has HdStorm and MaterialX without UsdShellExtension.dll.
    _sdk_plugin_usd = next(
        (c for c in (
            os.path.normpath(
                os.path.join(e.strip(), '..', '..', 'plugin', 'usd')
            )
            for e in os.environ.get('PYTHONPATH', '').split(';')
            if e.strip()
        ) if os.path.isdir(c)),
        '',
    )
    if _sdk_plugin_usd:
        os.environ['PXR_PLUGINPATH_NAME'] = _sdk_plugin_usd
    else:
        os.environ.pop('PXR_PLUGINPATH_NAME', None)

    # --- Step 2: parse args. ---
    # argv: <script> --imageWidth <W> [--renderer <R>] <usdFile> <outFile>
    image_width = 960
    renderer_arg = ''
    positional = []

    i = 1  # argv[0] is the script path; named args start at argv[1]
    while i < len(sys.argv):
        a = sys.argv[i]
        if a == '--imageWidth' and i + 1 < len(sys.argv):
            image_width = max(1, int(sys.argv[i + 1]))
            i += 2
        elif a == '--renderer' and i + 1 < len(sys.argv):
            renderer_arg = sys.argv[i + 1]
            i += 2
        elif not a.startswith('--'):
            positional.append(a)
            i += 1
        else:
            i += 1

    if len(positional) < 2:
        print('Usage: UsdThumbnail <usdFilePath> <outputImagePath>',
              file=sys.stderr)
        return 1

    usd_file, output_path = positional[0], positional[1]
    image_width = min(image_width, 256)

    # --- Step 3: create the offscreen GL context before importing UsdImagingGL. ---
    _qt_app, _gl_surface = _setup_gl_context()

    # --- Step 4: import pxr modules and patch CP1252 safety. ---
    from pxr import Usd, UsdGeom, UsdAppUtils, Tf
    try:
        _orig_fget = Tf.Error.commentary.fget

        def _safe_commentary(self):
            try:
                return _orig_fget(self)
            except (UnicodeDecodeError, UnicodeEncodeError):
                return ''

        Tf.Error.commentary = property(_safe_commentary)
    except Exception:
        pass
    from pxr.UsdAppUtils import rendererArgs

    renderer_plugin = rendererArgs.GetPluginIdFromArgument(renderer_arg) or ''

    # --- Step 5: open stage and find camera. ---
    stage = Usd.Stage.Open(usd_file)
    if not stage:
        print('Could not open USD stage: %s' % usd_file, file=sys.stderr)
        return 1

    # Render at startTimeCode so time-sampled attributes resolve to authored values.
    time_code = Usd.TimeCode(stage.GetStartTimeCode())

    # Prefer an authored camera; if none exists build a square framing camera
    # from the world bbox so the output is always image_width x image_width.
    usd_camera = _find_stage_camera(stage) or _make_framing_camera(stage, time_code)

    # --- Step 6: record. ---
    has_lights = _stage_has_lights(stage)

    recorder = UsdAppUtils.FrameRecorder(renderer_plugin, True, True)
    recorder.SetImageWidth(image_width)
    recorder.SetComplexity(1.0)
    recorder.SetCameraLightEnabled(not has_lights)
    recorder.SetColorCorrectionMode('sRGB')
    recorder.SetIncludedPurposes([UsdGeom.Tokens.proxy])

    ok = False
    try:
        ok = recorder.Record(stage, usd_camera, time_code, output_path)
    except Tf.ErrorException as e:
        print('Recording failed: %s' % str(e), file=sys.stderr)
        return 1
    finally:
        recorder = None

    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
