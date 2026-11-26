# USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
# Licensed under the MIT License. See LICENSE.txt for details.
"""Shared pytest fixtures for the USD Python scripts."""

import os
import sys

import pytest

# The scripts are standalone files launched by the COM Local Servers, not an
# installed package: expose their folders so tests can import them by name.
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SCRIPT_DIRS = [
    os.path.join(REPO_ROOT, "UsdPythonToolsServer"),
    os.path.join(REPO_ROOT, "UsdPreviewHandlerServer"),
]
for script_dir in SCRIPT_DIRS:
    if script_dir not in sys.path:
        sys.path.insert(0, script_dir)


@pytest.fixture
def make_stage():
    """Return a factory building an empty in-memory stage.

    The factory takes the up axis ("Y" or "Z") so framing logic can be
    checked for both conventions without touching the file system.
    """
    from pxr import Usd, UsdGeom

    def _make_stage(up_axis="Y"):
        stage = Usd.Stage.CreateInMemory()
        UsdGeom.SetStageUpAxis(stage, up_axis)
        return stage

    return _make_stage
