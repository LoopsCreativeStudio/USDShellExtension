# USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
# Licensed under the MIT License. See LICENSE.txt for details.
"""Tests for UsdValidate.py, the "Validate" context menu command.

The script uses the UsdValidation framework: UsdUtils.ComplianceChecker was
removed in OpenUSD 26.08.
"""

import sys

import pytest
from pxr import Usd, UsdGeom

import UsdValidate


def _write_stage(path, meters_per_unit=None):
    """Write a stage with one sphere, optionally with metersPerUnit set."""
    stage = Usd.Stage.CreateNew(str(path))
    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.y)
    if meters_per_unit is not None:
        UsdGeom.SetStageMetersPerUnit(stage, meters_per_unit)
    sphere = UsdGeom.Sphere.Define(stage, "/World/Sphere")
    stage.SetDefaultPrim(sphere.GetPrim().GetParent())
    stage.GetRootLayer().Save()
    return str(path)


def _run(monkeypatch, *usd_paths):
    """Run UsdValidate.main() with the given files as argv."""
    monkeypatch.setattr(sys, "argv", ["UsdValidate.py", *usd_paths])
    return UsdValidate.main()


def test_valid_stage_succeeds(tmp_path, monkeypatch, capsys):
    usd_path = _write_stage(tmp_path / "valid.usda", meters_per_unit=0.01)

    assert _run(monkeypatch, usd_path) == 0
    assert "Success!" in capsys.readouterr().out


def test_stage_without_meters_per_unit_fails_with_the_validator_message(tmp_path, monkeypatch, capsys):
    usd_path = _write_stage(tmp_path / "no_units.usda")

    assert _run(monkeypatch, usd_path) == 1
    output = capsys.readouterr().out
    assert "MissingMetersPerUnitMetadata" in output
    assert "Failed!" in output


def test_unreadable_file_fails(tmp_path, monkeypatch, capsys):
    missing_path = str(tmp_path / "missing.usda")

    assert _run(monkeypatch, missing_path) == 1
    assert "Failed!" in capsys.readouterr().out


def test_several_files_print_a_summary(tmp_path, monkeypatch, capsys):
    valid_path = _write_stage(tmp_path / "valid.usda", meters_per_unit=1.0)
    invalid_path = _write_stage(tmp_path / "no_units.usda")

    assert _run(monkeypatch, valid_path, invalid_path) == 1
    assert "Summary: 1/2 passed" in capsys.readouterr().out


def test_without_argument_prints_usage(monkeypatch, capsys):
    assert _run(monkeypatch) == 1
    assert "Usage" in capsys.readouterr().out


@pytest.mark.parametrize("validator_name, expected", [
    ("usdUtilsValidators:RootPackageValidator", False),
    ("usdGeomValidators:StageMetadataChecker", True),
])
def test_root_package_validator_is_left_out(validator_name, expected):
    # Same choice as usdchecker without --rootPackageOnly: the whole package
    # is checked, so the root-layer-only package validator is not used.
    assert UsdValidate.is_validator_used(validator_name) is expected
