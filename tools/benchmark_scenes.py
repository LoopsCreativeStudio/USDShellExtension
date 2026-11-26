# USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
# Licensed under the MIT License. See LICENSE.txt for details.
#
# Generates the deterministic USD scenes used by tools/Measure-Performance.ps1.
# argv layout: [script.py, output_dir]
"""Write the benchmark scenes (small, lights, medium) into a folder."""

import os
import sys

from pxr import Gf, Usd, UsdGeom, UsdLux

# Side of the cube grid of the medium scene (GRID_SIZE * GRID_SIZE prims).
GRID_SIZE = 50


def write_small(path):
    """Write a single cube: measures fixed costs only."""
    stage = Usd.Stage.CreateNew(path)
    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.y)
    UsdGeom.Xform.Define(stage, "/World")
    UsdGeom.Cube.Define(stage, "/World/Cube")
    stage.SetDefaultPrim(stage.GetPrimAtPath("/World"))
    stage.GetRootLayer().Save()


def write_lights(path):
    """Write a cube lit by authored lights: disables the camera headlight."""
    stage = Usd.Stage.CreateNew(path)
    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.y)
    UsdGeom.Xform.Define(stage, "/World")
    UsdGeom.Cube.Define(stage, "/World/Cube")
    UsdLux.DomeLight.Define(stage, "/World/Dome")
    key = UsdLux.SphereLight.Define(stage, "/World/Key")
    UsdGeom.XformCommonAPI(key).SetTranslate(Gf.Vec3d(3.0, 4.0, 3.0))
    stage.SetDefaultPrim(stage.GetPrimAtPath("/World"))
    stage.GetRootLayer().Save()


def write_medium(path):
    """Write a GRID_SIZE x GRID_SIZE grid of cubes in a binary crate file."""
    stage = Usd.Stage.CreateNew(path)
    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.y)
    UsdGeom.Xform.Define(stage, "/World")
    for row in range(GRID_SIZE):
        for col in range(GRID_SIZE):
            cube = UsdGeom.Cube.Define(stage, "/World/Cube_%d_%d" % (row, col))
            UsdGeom.XformCommonAPI(cube).SetTranslate(Gf.Vec3d(col * 3.0, 0.0, row * 3.0))
    stage.SetDefaultPrim(stage.GetPrimAtPath("/World"))
    stage.GetRootLayer().Save()


def main():
    """Generate every scene into the folder given on the command line."""
    if len(sys.argv) < 2:
        print("Usage: benchmark_scenes.py <output_dir>", file=sys.stderr)
        return 1

    output_dir = sys.argv[1]
    os.makedirs(output_dir, exist_ok=True)
    write_small(os.path.join(output_dir, "small.usda"))
    write_lights(os.path.join(output_dir, "lights.usda"))
    write_medium(os.path.join(output_dir, "medium.usdc"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
