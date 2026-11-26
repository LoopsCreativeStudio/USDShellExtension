# USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
# Licensed under the MIT License. See LICENSE.txt for details.
"""Tests of the persistent thumbnail worker protocol (no OpenGL needed).

The worker reads one JSON request per line on stdin and answers one JSON
result per line on stdout. Rendering is replaced by a fake function.
"""

import io
import json
import sys

import pytest

import UsdThumbnailWorker


class FakeRenderer:
    """Record render calls; succeed, fail or raise on demand."""

    def __init__(self, result=(True, ""), raise_on=None):
        self.calls = []
        self.result = result
        self.raise_on = raise_on

    def __call__(self, usd_file, output_path, image_width, renderer):
        self.calls.append((usd_file, output_path, image_width, renderer))
        if self.raise_on and self.raise_on in usd_file:
            raise RuntimeError("boom in %s" % usd_file)
        return self.result


def _serve(lines, render):
    """Run the worker loop on the given input lines; return parsed results."""
    output = io.StringIO()
    exit_code = UsdThumbnailWorker.serve(io.StringIO("".join(line + "\n" for line in lines)), output, render)
    results = [json.loads(line) for line in output.getvalue().splitlines()]
    return exit_code, results


def _request(request_id, usd="C:/a.usda", out="C:/a.png", **extra):
    request = {"id": request_id, "usd": usd, "out": out}
    request.update(extra)
    return json.dumps(request)


def test_renders_a_request_and_echoes_its_id():
    render = FakeRenderer()

    exit_code, results = _serve([_request(7, width=128, renderer="GL")], render)

    assert exit_code == 0
    assert results == [{"id": 7, "ok": True, "error": ""}]
    assert render.calls == [("C:/a.usda", "C:/a.png", 128, "GL")]


def test_applies_defaults_for_width_and_renderer():
    render = FakeRenderer()

    _serve([_request(1)], render)

    assert render.calls == [("C:/a.usda", "C:/a.png", 256, "")]


def test_answers_each_request_in_order():
    render = FakeRenderer()

    _, results = _serve([_request(1), _request(2), _request(3)], render)

    assert [result["id"] for result in results] == [1, 2, 3]
    assert len(render.calls) == 3


def test_reports_a_failed_render():
    render = FakeRenderer(result=(False, "Could not open USD stage"))

    _, results = _serve([_request(4)], render)

    assert results == [{"id": 4, "ok": False, "error": "Could not open USD stage"}]


def test_survives_a_render_exception_and_keeps_serving():
    # One broken file must not take the warm worker down.
    render = FakeRenderer(raise_on="broken")

    _, results = _serve([_request(1, usd="C:/broken.usda"), _request(2)], render)

    assert results[0]["id"] == 1
    assert results[0]["ok"] is False
    assert "boom in C:/broken.usda" in results[0]["error"]
    assert results[1] == {"id": 2, "ok": True, "error": ""}


@pytest.mark.parametrize(
    "line, expected_error",
    [
        ("not json", "invalid request"),
        ('{"id": 5, "out": "C:/a.png"}', "missing 'usd'"),
        ('{"id": 5, "usd": "C:/a.usda"}', "missing 'out'"),
        ('{"id": 5, "usd": "C:/a.usda", "out": "C:/a.png", "width": "big"}', "invalid 'width'"),
        ("[1, 2]", "invalid request"),
    ],
)
def test_rejects_malformed_requests_and_keeps_serving(line, expected_error):
    render = FakeRenderer()

    _, results = _serve([line, _request(9)], render)

    assert results[0]["ok"] is False
    assert expected_error in results[0]["error"]
    assert results[1] == {"id": 9, "ok": True, "error": ""}
    assert len(render.calls) == 1


def test_echoes_id_of_a_rejected_request_when_readable():
    _, results = _serve(['{"id": 12, "out": "C:/a.png"}'], FakeRenderer())

    assert results[0]["id"] == 12


def test_ignores_blank_lines():
    _, results = _serve(["", "   ", _request(1)], FakeRenderer())

    assert [result["id"] for result in results] == [1]


def test_exit_command_stops_the_loop():
    render = FakeRenderer()

    exit_code, results = _serve([_request(1), '{"cmd": "exit"}', _request(2)], render)

    assert exit_code == 0
    assert [result["id"] for result in results] == [1]
    assert len(render.calls) == 1


def test_end_of_input_stops_the_loop():
    exit_code, results = _serve([], FakeRenderer())

    assert exit_code == 0
    assert results == []


def test_flushes_each_result_immediately():
    # The C++ pool waits for each answer line: it must not sit in a buffer.
    class CountingOutput(io.StringIO):
        flushes = 0

        def flush(self):
            CountingOutput.flushes += 1
            super().flush()

    output = CountingOutput()
    UsdThumbnailWorker.serve(io.StringIO(_request(1) + "\n" + _request(2) + "\n"), output, FakeRenderer())

    assert CountingOutput.flushes >= 2


def test_importing_the_worker_loads_no_heavy_module():
    # pxr / PySide6 are imported by main() only, after the plugin path is
    # narrowed and the GL context exists. Checked in a fresh interpreter.
    import os
    import subprocess

    script_dir = os.path.dirname(UsdThumbnailWorker.__file__)
    code = (
        "import sys; sys.path.insert(0, %r); import UsdThumbnailWorker; "
        "print(sorted(m for m in sys.modules if m.split('.')[0] in ('pxr', 'PySide6')))" % script_dir
    )
    output = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, check=True).stdout

    assert output.strip() == "[]"
