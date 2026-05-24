# USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
# Licensed under the MIT License. See LICENSE.txt for details.
#
# Computes and displays stage statistics via pxr.UsdUtils.ComputeUsdStageStats.
# argv layout: [script.py, file.usd]

from __future__ import print_function
import sys
import os

os.environ.pop('PXR_PLUGINPATH_NAME', None)


def _print_dict(data, indent=0):
    prefix = "  " * indent
    for key, value in sorted(data.items()):
        if hasattr(value, 'items'):
            print("%s%s" % (prefix, key))
            _print_dict(value, indent + 1)
        else:
            print("%s%s = %s" % (prefix, key, value))


def main():
    if len(sys.argv) < 2:
        print("Usage: UsdStageStats.py <usd_file>")
        return 1

    usd_path = sys.argv[1]

    try:
        from pxr import Tf, UsdUtils
    except ImportError as e:
        print("Error: could not import pxr USD library.")
        print(str(e))
        return 1

    try:
        _orig_tf_err_str = Tf.ErrorException.__str__

        def _safe_tf_err_str(self):
            try:
                return _orig_tf_err_str(self)
            except UnicodeDecodeError as ude:
                try:
                    return bytes(ude.object).decode('cp1252', errors='replace')
                except Exception:
                    return 'Tf.ErrorException (message undecodable)'
            except UnicodeEncodeError:
                return 'Tf.ErrorException (message undecodable)'

        Tf.ErrorException.__str__ = _safe_tf_err_str
    except Exception:
        pass

    print("USD Stage Stats")
    print("=" * 72)
    print("File: %s" % usd_path)
    print()

    try:
        try:
            raw = UsdUtils.ComputeUsdStageStats(usd_path)
            if isinstance(raw, dict):
                # NVIDIA USD 25.08: returns stats dict directly (no stage).
                stats = raw
                stage = True
            elif isinstance(raw, tuple):
                stage = raw[0]
                stats = next(
                    (x for x in raw[1:] if hasattr(x, 'items')),
                    {}
                )
            else:
                stage = raw
                stats = {}
        except TypeError:
            stats = {}
            stage = UsdUtils.ComputeUsdStageStats(usd_path, stats)
    except Exception as e:
        print("Error: %s" % str(e))
        print()
        return 1

    if stage is None:
        print("Error: could not open USD stage.")
        print()
        return 1

    _print_dict(stats)

    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
