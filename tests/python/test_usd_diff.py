# USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
# Licensed under the MIT License. See LICENSE.txt for details.
"""Tests for UsdDiff.py, the "Diff" context menu command.

The SDK ships usddiff as a Python script without extension (bin\\usddiff),
run as __main__ like the command line does.
"""

import sys

import UsdDiff

# Stand-in for bin\usddiff: prints its arguments and exits with a code,
# only when run as the main module (like the real script).
FAKE_USDDIFF = """
import sys
if __name__ == "__main__":
    print("usddiff args:", sys.argv[1:])
    sys.exit(3)
"""


def test_runs_the_extensionless_usddiff_script_as_main(tmp_path, monkeypatch, capsys):
    usddiff_path = tmp_path / "usddiff"
    usddiff_path.write_text(FAKE_USDDIFF)
    monkeypatch.setattr(sys, "argv", ["UsdDiff.py", str(usddiff_path), "a.usda", "b.usda"])

    assert UsdDiff.main() == 3
    assert "usddiff args: ['a.usda', 'b.usda']" in capsys.readouterr().out


def test_without_enough_arguments_prints_usage(monkeypatch, capsys):
    monkeypatch.setattr(sys, "argv", ["UsdDiff.py", "usddiff"])

    assert UsdDiff.main() == 1
    assert "Usage" in capsys.readouterr().out
