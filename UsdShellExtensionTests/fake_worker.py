# USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
# Licensed under the MIT License. See LICENSE.txt for details.
#
# Fake thumbnail worker for the CThumbnailWorkerPool unit tests: speaks the
# UsdThumbnailWorker.py protocol without USD or OpenGL.
# argv layout: [script.py]
#
# Behavior is chosen by the requested "usd" path:
#   contains "hang"       never answers
#   contains "crash"      exits without answering
#   contains "fail"       answers ok=false, error "fake failure"
#   contains "badjson"    answers a line that is not JSON
#   contains "slow:<ms>"  waits <ms> milliseconds, then succeeds
#   anything else         succeeds
# On success the "out" file receives "pid=<pid> count=<n> usd=<usd path>"
# so tests can see which worker rendered and what path it received.
"""Answer thumbnail requests like the real worker, without rendering."""

import json
import os
import re
import sys
import time


def main():
    """Serve requests from stdin until exit command or end of input."""
    render_count = 0
    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        request = json.loads(line)
        if request.get("cmd") == "exit":
            break

        usd = request.get("usd", "")
        if "hang" in usd:
            time.sleep(3600)
        if "crash" in usd:
            os._exit(3)
        if "badjson" in usd:
            sys.stdout.write("this is not json\n")
            sys.stdout.flush()
            continue

        slow = re.search(r"slow:(\d+)", usd)
        if slow:
            time.sleep(int(slow.group(1)) / 1000.0)

        render_count += 1
        if "fail" in usd:
            result = {"id": request.get("id"), "ok": False, "error": "fake failure"}
        else:
            with open(request["out"], "w", encoding="utf-8") as image:
                image.write("pid=%d count=%d usd=%s" % (os.getpid(), render_count, usd))
            result = {"id": request.get("id"), "ok": True, "error": ""}

        # Noise on stderr must never block the worker.
        sys.stderr.write("warning: " + "x" * 2000 + "\n")
        sys.stdout.write(json.dumps(result) + "\n")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
