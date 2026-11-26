# USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
# Licensed under the MIT License. See LICENSE.txt for details.
#
# Persistent thumbnail worker, kept warm by the thumbnail server.
# argv layout: [script.py]
#
# Python, USD, Qt and the offscreen GL context are loaded once; each request
# then costs only the render (~30-170 ms instead of ~0.9 s for a new
# python.exe). Protocol, one JSON object per line:
#   stdin  request : {"id": 7, "usd": "C:/a.usd", "out": "C:/a.png",
#                     "width": 256, "renderer": ""}     (width, renderer optional)
#   stdin  stop    : {"cmd": "exit"}                     (or end of input)
#   stdout result  : {"id": 7, "ok": true, "error": ""}
# Everything else (USD warnings, prints) goes to stderr, never to stdout.
"""Serve thumbnail requests read on stdin, one JSON line each."""

import json
import os
import sys

DEFAULT_WIDTH = 256


def _parse_request(line):
    """Return (request_id, arguments, error) for one request line.

    arguments is (usd, out, width, renderer) when the request is valid,
    otherwise None with a readable error.
    """
    try:
        request = json.loads(line)
    except ValueError:
        return None, None, "invalid request: not JSON"
    if not isinstance(request, dict):
        return None, None, "invalid request: not a JSON object"

    request_id = request.get("id")
    for key in ("usd", "out"):
        if not isinstance(request.get(key), str) or not request[key]:
            return request_id, None, "invalid request: missing '%s'" % key

    width = request.get("width", DEFAULT_WIDTH)
    if isinstance(width, bool) or not isinstance(width, int):
        return request_id, None, "invalid request: invalid 'width'"

    renderer = request.get("renderer") or ""
    return request_id, (request["usd"], request["out"], width, renderer), ""


def handle_request(line, render):
    """Run one request line and return its result dictionary.

    A render that raises is reported as a failure: one broken file must not
    take the warm worker down.
    """
    request_id, arguments, error = _parse_request(line)
    if arguments is None:
        return {"id": request_id, "ok": False, "error": error}

    try:
        ok, error = render(*arguments)
    except Exception as exception:  # report any render failure, keep serving
        ok, error = False, "%s: %s" % (type(exception).__name__, exception)
    return {"id": request_id, "ok": bool(ok), "error": error or ""}


def _is_exit_command(line):
    """True for the {"cmd": "exit"} stop request."""
    try:
        message = json.loads(line)
    except ValueError:
        return False
    return isinstance(message, dict) and message.get("cmd") == "exit"


def serve(input_stream, output_stream, render):
    """Answer requests until end of input or an exit command.

    Each result is written and flushed at once: the server waits for it.
    """
    for raw_line in input_stream:
        line = raw_line.strip()
        if not line:
            continue
        if _is_exit_command(line):
            break
        result = handle_request(line, render)
        output_stream.write(json.dumps(result) + "\n")
        output_stream.flush()
    return 0


def main():
    """Load USD and the GL context once, then serve requests from stdin."""
    import UsdThumbnail

    # Same preparation as the one-shot mode, done once for all requests.
    UsdThumbnail.narrow_plugin_path()

    # Keep the real stdout for the protocol; any stray print goes to stderr.
    protocol_output = sys.stdout
    sys.stdout = sys.stderr

    _qt_app, _gl_surface = UsdThumbnail._setup_gl_context()
    exit_code = serve(sys.stdin, protocol_output, UsdThumbnail.render_thumbnail)

    # Skip interpreter teardown: destroying the Hydra objects after the GL
    # context floods stderr with thousands of GL errors.
    protocol_output.flush()
    sys.stderr.flush()
    os._exit(exit_code)


if __name__ == "__main__":
    main()
