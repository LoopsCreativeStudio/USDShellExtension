# USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
# Licensed under the MIT License. See LICENSE.txt for details.

from __future__ import print_function
import sys
import os

os.environ.pop('PXR_PLUGINPATH_NAME', None)


def main():
    if len(sys.argv) < 2:
        print("Usage: UsdLayerStack.py <usd_file>")
        input("\nPress Enter to close...")
        return 1

    usd_path = sys.argv[1]

    try:
        from pxr import Tf, Usd, Sdf
    except ImportError as e:
        print("Error: could not import pxr USD library.")
        print(str(e))
        input("\nPress Enter to close...")
        return 1

    # pxr/Tf/__init__.py defines ErrorException.__str__ in Python; it calls
    # str() on each Tf.Error in self.args, which can fail with UnicodeDecodeError
    # when the C++ error text contains CP1252 bytes.  Wrap it so we always get
    # a printable string.
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

    print("USD Layer Stack")
    print("=" * 72)
    print("File: %s" % usd_path)
    print()

    stage = None
    for load_set in (Usd.Stage.LoadNone, Usd.Stage.LoadAll):
        try:
            stage = Usd.Stage.Open(usd_path, load_set)
            break
        except Exception:
            continue

    if stage is None:
        # Stage open failed entirely; fall back to the raw SDF layer so the
        # user can still see sublayer paths and basic composition info.
        try:
            layer = Sdf.Layer.FindOrOpen(usd_path)
        except Exception:
            layer = None

        if layer is not None:
            print("Note: could not open as a full USD stage; showing root layer only.")
            print()
            print("Identifier: %s" % layer.identifier)
            if layer.subLayerPaths:
                print()
                print("Sublayers (%d):" % len(layer.subLayerPaths))
                for sl in layer.subLayerPaths:
                    print("  %s" % sl)
        else:
            print("Error: could not open file as a USD stage or SDF layer.")
        print()
        return 1

    session = stage.GetSessionLayer()

    layer_stack = stage.GetLayerStack()
    count = len(layer_stack)
    print("Layer stack  (%d layer%s, ordered by strength):" % (count, "" if count == 1 else "s"))
    for i, layer in enumerate(layer_stack):
        real = layer.realPath or layer.identifier
        label = " [session]" if layer == session else ""
        print("  [%d] %s%s" % (i, real, label))

    used = stage.GetUsedLayers()
    non_session = [lyr for lyr in used if lyr != session]
    if len(non_session) > count:
        print()
        print("All used layers (includes references and payloads; %d total):" % len(non_session))
        for i, layer in enumerate(sorted(non_session,
                                          key=lambda lyr: lyr.realPath or lyr.identifier)):
            real = layer.realPath or layer.identifier
            print("  [%d] %s" % (i, real))

    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
