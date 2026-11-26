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


# ---------------------------------------------------------------------------
# _make_framing_camera: what the framing box contains
# ---------------------------------------------------------------------------
def _framing_eye(stage):
    """Return the framing camera position for the stage (Y-up: on +Z)."""
    camera = UsdThumbnail._make_framing_camera(stage, Usd.TimeCode.Default())
    assert camera, "expected a valid framing camera"
    return camera.ComputeLocalToWorldTransform(Usd.TimeCode.Default()).ExtractTranslation()


def _new_bbox_cache():
    """BBoxCache configured like the thumbnail framing."""
    return UsdGeom.BBoxCache(Usd.TimeCode.Default(), [UsdGeom.Tokens.default_, UsdGeom.Tokens.proxy], True)


def _expected_cube_eye():
    """Eye position framing only the 2-unit cube centered at the origin."""
    distance = 1.0 * MARGIN / math.tan(HALF_FOV_RAD)
    return Gf.Vec3d(0.0, 0.0, distance + 1.0)


@pytest.mark.parametrize(
    "light_type",
    [UsdLux.SphereLight, UsdLux.RectLight, UsdLux.DiskLight, UsdLux.CylinderLight],
)
def test_framing_ignores_boundable_lights(make_stage, light_type):
    # Regression: a light away from the asset used to enlarge the framing
    # box, leaving the asset small and off-center in the thumbnail.
    stage = make_stage()
    _add_cube(stage)
    light = light_type.Define(stage, "/World/KeyLight")
    UsdGeom.XformCommonAPI(light).SetTranslate(Gf.Vec3d(30.0, 40.0, 30.0))

    assert Gf.IsClose(_framing_eye(stage), _expected_cube_eye(), 1e-6)


def test_framing_ignores_lights_nested_in_the_asset(make_stage):
    stage = make_stage()
    UsdGeom.Xform.Define(stage, "/World/Lamp")
    UsdGeom.Cube.Define(stage, "/World/Lamp/Shade").GetSizeAttr().Set(2.0)
    bulb = UsdLux.SphereLight.Define(stage, "/World/Lamp/Bulb")
    UsdGeom.XformCommonAPI(bulb).SetTranslate(Gf.Vec3d(0.0, 25.0, 0.0))

    assert Gf.IsClose(_framing_eye(stage), _expected_cube_eye(), 1e-6)


def test_framing_camera_is_invalid_with_lights_only(make_stage):
    # Nothing to look at: no camera, the recorder falls back to its default.
    stage = make_stage()
    UsdLux.SphereLight.Define(stage, "/World/Key")
    UsdLux.DomeLight.Define(stage, "/World/Dome")

    camera = UsdThumbnail._make_framing_camera(stage, Usd.TimeCode.Default())
    assert not camera


def test_framing_includes_instanced_geometry(make_stage):
    # Instance proxies are skipped by a default traversal: they must still
    # count, or instanced assets would be framed as empty.
    stage = make_stage()
    prototype = UsdGeom.Xform.Define(stage, "/Prototypes/Box")
    UsdGeom.Cube.Define(stage, "/Prototypes/Box/Geo").GetSizeAttr().Set(2.0)
    stage.GetPrimAtPath("/Prototypes").SetSpecifier(Sdf.SpecifierClass)
    for index, x_position in enumerate((-10.0, 10.0)):
        instance = UsdGeom.Xform.Define(stage, "/World/Box_%d" % index)
        instance.GetPrim().GetReferences().AddInternalReference(prototype.GetPath())
        instance.GetPrim().SetInstanceable(True)
        UsdGeom.XformCommonAPI(instance).SetTranslate(Gf.Vec3d(x_position, 0.0, 0.0))

    # Both instances inside the framing box (checked on the box itself: this
    # flat layout gets the elevated view).
    geometry_range = UsdThumbnail._compute_geometry_range(stage, _new_bbox_cache())
    assert Gf.IsClose(geometry_range.GetMin(), Gf.Vec3d(-11.0, -1.0, -1.0), 1e-6)
    assert Gf.IsClose(geometry_range.GetMax(), Gf.Vec3d(11.0, 1.0, 1.0), 1e-6)


# ---------------------------------------------------------------------------
# _make_framing_camera: flat scenes get an elevated view
# ---------------------------------------------------------------------------
def _add_flat_grid(stage, up_axis="Y", count=10, spacing=3.0):
    """Lay count x count 2-unit cubes on the ground plane of the stage."""
    for row in range(count):
        for col in range(count):
            cube = UsdGeom.Cube.Define(stage, "/World/Cube_%d_%d" % (row, col))
            if up_axis == "Y":
                position = Gf.Vec3d(col * spacing, 0.0, row * spacing)
            else:
                position = Gf.Vec3d(col * spacing, row * spacing, 0.0)
            UsdGeom.XformCommonAPI(cube).SetTranslate(position)


def _world_corners(stage):
    """Return the 8 corners of the world bounding box of the stage."""
    cache = UsdGeom.BBoxCache(Usd.TimeCode.Default(), [UsdGeom.Tokens.default_])
    box = cache.ComputeWorldBound(stage.GetPseudoRoot()).ComputeAlignedRange()
    return [box.GetCorner(index) for index in range(8)], box


def _assert_all_corners_visible(camera, corners):
    """Every corner lies in the square 45 degree view and between the clip planes."""
    cam_to_world = camera.ComputeLocalToWorldTransform(Usd.TimeCode.Default())
    world_to_cam = cam_to_world.GetInverse()
    near, far = camera.GetClippingRangeAttr().Get()
    tan_half_fov = math.tan(HALF_FOV_RAD)
    for corner in corners:
        local = world_to_cam.Transform(corner)
        depth = -local[2]  # the camera looks down -Z
        assert near <= depth <= far, "corner %s outside clip range" % (corner,)
        assert abs(local[0]) <= depth * tan_half_fov + 1e-6, "corner %s outside view (x)" % (corner,)
        assert abs(local[1]) <= depth * tan_half_fov + 1e-6, "corner %s outside view (y)" % (corner,)


@pytest.mark.parametrize("up_axis, up_index", [("Y", 1), ("Z", 2)])
def test_flat_scene_is_seen_from_above(make_stage, up_axis, up_index):
    # Regression: a ground layout seen strictly from the front rendered as a
    # thin line. Flat scenes switch to an elevated three-quarter view.
    stage = make_stage(up_axis)
    _add_flat_grid(stage, up_axis)
    corners, box = _world_corners(stage)
    centroid = box.GetMidpoint()

    camera = UsdThumbnail._make_framing_camera(stage, Usd.TimeCode.Default())
    eye = camera.ComputeLocalToWorldTransform(Usd.TimeCode.Default()).ExtractTranslation()

    # Clearly above the scene, looking down at its center.
    height = eye[up_index] - centroid[up_index]
    distance = (eye - centroid).GetLength()
    assert height / distance == pytest.approx(math.sin(math.radians(45.0)), abs=1e-6)
    cam_to_world = camera.ComputeLocalToWorldTransform(Usd.TimeCode.Default())
    forward = cam_to_world.TransformDir(Gf.Vec3d(0.0, 0.0, -1.0)).GetNormalized()
    assert Gf.IsClose(forward, (centroid - eye).GetNormalized(), 1e-6)

    _assert_all_corners_visible(camera, corners)


def test_flat_view_keeps_the_scene_upright(make_stage):
    # The camera "up" must point to the stage up axis side, not roll the image.
    stage = make_stage("Y")
    _add_flat_grid(stage, "Y")

    camera = UsdThumbnail._make_framing_camera(stage, Usd.TimeCode.Default())
    cam_to_world = camera.ComputeLocalToWorldTransform(Usd.TimeCode.Default())
    camera_up = cam_to_world.TransformDir(Gf.Vec3d(0.0, 1.0, 0.0)).GetNormalized()
    camera_right = cam_to_world.TransformDir(Gf.Vec3d(1.0, 0.0, 0.0)).GetNormalized()

    assert camera_up[1] > 0.5
    assert abs(camera_right[1]) < 1e-6  # horizon stays level


def test_moderately_low_scene_keeps_the_front_view(make_stage):
    # Height 30% of the width: above the 20% threshold, front view as before.
    stage = make_stage("Y")
    box = UsdGeom.Cube.Define(stage, "/World/Box")
    box.GetSizeAttr().Set(2.0)
    UsdGeom.XformCommonAPI(box).SetScale(Gf.Vec3f(10.0, 3.0, 10.0))

    camera = UsdThumbnail._make_framing_camera(stage, Usd.TimeCode.Default())
    eye = camera.ComputeLocalToWorldTransform(Usd.TimeCode.Default()).ExtractTranslation()

    assert eye[1] == pytest.approx(0.0, abs=1e-6)
    assert eye[2] > 0.0
    _assert_all_corners_visible(camera, _world_corners(stage)[0])


def test_front_view_keeps_every_corner_visible(make_stage):
    stage = make_stage("Y")
    _add_cube(stage)

    camera = UsdThumbnail._make_framing_camera(stage, Usd.TimeCode.Default())

    _assert_all_corners_visible(camera, _world_corners(stage)[0])


def _median_seconds(function, runs=5):
    """Return the median run time of function over several runs."""
    import time

    durations = []
    for _ in range(runs):
        start = time.perf_counter()
        function()
        durations.append(time.perf_counter() - start)
    return sorted(durations)[runs // 2]


@pytest.mark.parametrize("with_light", [False, True])
def test_geometry_range_costs_about_one_root_bound(make_stage, with_light):
    # Regression: walking every prim made framing ~7x slower than one root
    # bound on 2,500 prims, visible as slower thumbnails under load.
    stage = make_stage()
    for index in range(2500):
        cube = UsdGeom.Cube.Define(stage, "/World/Group_%d/Cube" % (index // 50) + "_%d" % index)
        UsdGeom.XformCommonAPI(cube).SetTranslate(Gf.Vec3d(index * 3.0, 0.0, 0.0))
    if with_light:
        UsdLux.SphereLight.Define(stage, "/World/Group_0/Lamp")

    def new_cache():
        return UsdGeom.BBoxCache(Usd.TimeCode.Default(), [UsdGeom.Tokens.default_, UsdGeom.Tokens.proxy], True)

    root_bound = _median_seconds(lambda: new_cache().ComputeWorldBound(stage.GetPseudoRoot()))
    geometry_range = _median_seconds(lambda: UsdThumbnail._compute_geometry_range(stage, new_cache()))

    assert geometry_range < 3.0 * root_bound + 0.005, (
        "geometry range %.1f ms vs root bound %.1f ms" % (geometry_range * 1000, root_bound * 1000)
    )


def test_framing_includes_point_instancer_instances(make_stage):
    stage = make_stage()
    instancer = UsdGeom.PointInstancer.Define(stage, "/World/Scatter")
    UsdGeom.Cube.Define(stage, "/World/Scatter/Prototypes/Cube").GetSizeAttr().Set(2.0)
    instancer.CreatePrototypesRel().AddTarget("/World/Scatter/Prototypes/Cube")
    instancer.CreateProtoIndicesAttr([0, 0])
    instancer.CreatePositionsAttr([Gf.Vec3f(0.0, 0.0, 0.0), Gf.Vec3f(10.0, 0.0, 0.0)])

    # Instances span x in [-1, 11] (flat layout: checked on the box itself).
    geometry_range = UsdThumbnail._compute_geometry_range(stage, _new_bbox_cache())
    assert Gf.IsClose(geometry_range.GetMin(), Gf.Vec3d(-1.0, -1.0, -1.0), 1e-6)
    assert Gf.IsClose(geometry_range.GetMax(), Gf.Vec3d(11.0, 1.0, 1.0), 1e-6)
