# USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
# Licensed under the MIT License. See LICENSE.txt for details.
#
# Wrapper for usddiff. Patches Tf.ErrorException for CP1252 safety then
# delegates to the usddiff script found in the USD SDK.
# argv layout: [script.py, usddiff_path, file1.usd, file2.usd]

from __future__ import print_function
import sys
import os

os.environ.pop('PXR_PLUGINPATH_NAME', None)


def main():
    if len(sys.argv) < 4:
        print("Usage: UsdDiff.py <usddiff_path> <file1.usd> <file2.usd>")
        return 1

    usddiff_path, file1, file2 = sys.argv[1], sys.argv[2], sys.argv[3]

    try:
        from pxr import Tf
        _orig = Tf.ErrorException.__str__

        def _safe(self):
            try:
                return _orig(self)
            except UnicodeDecodeError as e:
                try:
                    return bytes(e.object).decode('cp1252', errors='replace')
                except Exception:
                    return 'Tf.ErrorException (message undecodable)'
            except UnicodeEncodeError:
                return 'Tf.ErrorException (message undecodable)'

        Tf.ErrorException.__str__ = _safe
    except Exception:
        pass

    print("USD Diff")
    print("=" * 72)
    print("File 1: %s" % file1)
    print("File 2: %s" % file2)
    print()

    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location("usddiff", usddiff_path)
        mod = importlib.util.module_from_spec(spec)
        sys.argv = ["usddiff", file1, file2]
        spec.loader.exec_module(mod)
        return 0
    except SystemExit as e:
        return e.code if isinstance(e.code, int) else 0
    except Exception as e:
        print("Error: %s" % str(e))
        return 1


if __name__ == "__main__":
    sys.exit(main())
