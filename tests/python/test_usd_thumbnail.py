# USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
# Licensed under the MIT License. See LICENSE.txt for details.
"""Characterization tests for the pure helpers of UsdThumbnail.py.

They pin the current behavior (lights detection, camera search, framing
camera) so the thumbnail pipeline can be refactored safely.
"""

import math

import pytest
from pxr import Gf, Sdf, Usd, UsdGeom, UsdLux

import UsdThumbnail

# Constants mirrored from _make_framing_camera, used to compute expectations.
APERTURE_MM = 36.0
HALF_FOV_RAD = math.radians(22.5)
MARGIN = 1.1


def _add_cube(stage, path="/World/Cube", size=2.0):
    """Define a cube centered at the origin and return it."""
    cube = UsdGeom.Cube.Define(stage, path)
    cube.GetSizeAttr().Set(size)
    return cube


# ---------------------------------------------------------------------------
# _stage_has_lights
# ---------------------------------------------------------------------------
def test_stage_has_lights_is_false_on_empty_stage(make_stage):
    assert UsdThumbnail._stage_has_lights(make_stage()) is False


def test_stage_has_lights_is_false_with_geometry_only(make_stage):
    stage = make_stage()
    _add_cube(stage)
    assert UsdThumbnail._stage_has_lights(stage) is False


def test_stage_has_lights_detects_nested_light(make_stage):
    stage = make_stage()
    UsdGeom.Xform.Define(stage, "/World/Rig")
    UsdLux.SphereLight.Define(stage, "/World/Rig/Key")
    assert UsdThumbnail._stage_has_lights(stage) is True


# ---------------------------------------------------------------------------
# _find_stage_camera (needs UsdAppUtils, missing from usd-core)
# ---------------------------------------------------------------------------
@pytest.fixture
def usd_app_utils():
    """Skip the test when UsdAppUtils is not available."""
    return pytest.importorskip("pxr.UsdAppUtils")


def test_find_stage_camera_returns_none_without_camera(make_stage, usd_app_utils):
    stage = make_stage()
    _add_cube(stage)
    assert UsdThumbnail._find_stage_camera(stage) is None


def test_find_stage_camera_prefers_primary_camera(make_stage, usd_app_utils):
    from pxr import UsdUtils

    stage = make_stage()
    UsdGeom.Camera.Define(stage, "/AnyCam")
    primary_path = "/" + UsdUtils.GetPrimaryCameraName()
    UsdGeom.Camera.Define(stage, primary_path)

    camera = UsdThumbnail._find_stage_camera(stage)
    assert camera.GetPath() == Sdf.Path(primary_path)


def test_find_stage_camera_falls_back_to_first_camera(make_stage, usd_app_utils):
    stage = make_stage()
    UsdGeom.Camera.Define(stage, "/World/ShotCam")

    camera = UsdThumbnail._find_stage_camera(stage)
    assert camera.GetPath() == Sdf.Path("/World/ShotCam")


# ---------------------------------------------------------------------------
# _make_framing_camera
# ---------------------------------------------------------------------------
def test_framing_camera_is_invalid_on_empty_stage(make_stage):
    camera = UsdThumbnail._make_framing_camera(make_stage(), Usd.TimeCode.Default())
    assert not camera


def test_framing_camera_is_authored_on_session_layer_only(make_stage):
    stage = make_stage()
    _add_cube(stage)

    camera = UsdThumbnail._make_framing_camera(stage, Usd.TimeCode.Default())

    # The camera must exist on the composed stage...
    assert camera.GetPath() == Sdf.Path("/ThumbnailCamera")
    # ...but never be written into the user's file.
    assert stage.GetRootLayer().GetPrimAtPath("/ThumbnailCamera") is None
    assert stage.GetSessionLayer().GetPrimAtPath("/ThumbnailCamera") is not None


def test_framing_camera_has_square_aperture_and_45_degree_fov(make_stage):
    stage = make_stage()
    _add_cube(stage)

    camera = UsdThumbnail._make_framing_camera(stage, Usd.TimeCode.Default())

    assert camera.GetHorizontalApertureAttr().Get() == pytest.approx(APERTURE_MM)
    assert camera.GetVerticalApertureAttr().Get() == pytest.approx(APERTURE_MM)
    expected_focal = (APERTURE_MM * 0.5) / math.tan(HALF_FOV_RAD)
    assert camera.GetFocalLengthAttr().Get() == pytest.approx(expected_focal, rel=1e-5)


@pytest.mark.parametrize(
    "up_axis, eye_axis, eye_sign",
    [
        # Y-up: camera placed along +Z, looking toward -Z.
        ("Y", 2, 1.0),
        # Z-up: camera placed along -Y, looking toward +Y.
        ("Z", 1, -1.0),
    ],
)
def test_framing_camera_frames_cube_from_expected_side(make_stage, up_axis, eye_axis, eye_sign):
    stage = make_stage(up_axis)
    _add_cube(stage, size=2.0)

    camera = UsdThumbnail._make_framing_camera(stage, Usd.TimeCode.Default())
    cam_to_world = camera.ComputeLocalToWorldTransform(Usd.TimeCode.Default())
    eye = cam_to_world.ExtractTranslation()

    # Expected distance: fit the half extent (1.0) with the margin into the
    # 45 degree FOV, then step back by the half depth (1.0) of the cube.
    fit_half = 1.0 * MARGIN
    distance = fit_half / math.tan(HALF_FOV_RAD)
    expected_eye = Gf.Vec3d(0.0, 0.0, 0.0)
    expected_eye[eye_axis] = eye_sign * (distance + 1.0)
    assert Gf.IsClose(eye, expected_eye, 1e-6)

    # The camera looks down its local -Z axis: it must point at the centroid.
    forward = cam_to_world.TransformDir(Gf.Vec3d(0.0, 0.0, -1.0)).GetNormalized()
    to_center = (Gf.Vec3d(0.0, 0.0, 0.0) - eye).GetNormalized()
    assert Gf.IsClose(forward, to_center, 1e-6)

    # Clipping keeps the whole cube between near and far planes.
    near, far = camera.GetClippingRangeAttr().Get()
    distance_to_center = (distance + 1.0)
    # near = framing distance minus half depth, clamped to 1 (float32 attr).
    assert near == pytest.approx(max(1.0, distance - 1.0), rel=1e-5)
    assert near < distance_to_center - 1.0 + 1e-6
    assert far > distance_to_center + 1.0
