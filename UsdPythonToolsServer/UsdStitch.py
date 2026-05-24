# USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
# Licensed under the MIT License. See LICENSE.txt for details.

from __future__ import print_function
import sys
import os
import traceback

os.environ.pop('PXR_PLUGINPATH_NAME', None)


def main():
    if len(sys.argv) < 3:
        print("Usage: UsdStitch.py <output_file> <input1> [input2 ...]")
        return 1

    output_path = sys.argv[1]
    input_paths = sys.argv[2:]

    try:
        from pxr import Sdf, Tf, UsdUtils
    except ImportError as e:
        print("Error: could not import pxr USD library.")
        print(str(e))
        return 1

    try:
        _orig_tf_err_str = Tf.ErrorException.__str__

        def _safe_tf_err_str(self):
            try:
                return _orig_tf_err_str(self)
            except (UnicodeDecodeError, UnicodeEncodeError) as ude:
                try:
                    return bytes(ude.object).decode('cp1252', errors='replace')
                except Exception:
                    return 'Tf.ErrorException (message undecodable)'

        Tf.ErrorException.__str__ = _safe_tf_err_str
    except Exception:
        pass

    print("USD Stitch")
    print("=" * 72)
    print("Output: %s" % output_path)
    print()
    print("Inputs (%d):" % len(input_paths))
    for p in input_paths:
        print("  %s" % p)
    print()

    try:
        if os.path.exists(output_path):
            output_layer = Sdf.Layer.FindOrOpen(output_path)
        else:
            output_layer = Sdf.Layer.CreateNew(output_path)

        if output_layer is None:
            print("Error: could not create output layer: %s" % output_path)
            return 1

        for input_path in input_paths:
            layer = Sdf.Layer.FindOrOpen(input_path)
            if layer is None:
                print("Warning: could not open: %s" % input_path)
                continue
            UsdUtils.StitchLayers(output_layer, layer)
            print("Stitched: %s" % os.path.basename(input_path))

        output_layer.Save()
        print()
        print("Saved: %s" % output_path)
        return 0

    except Exception as e:
        print("Error: %s" % str(e))
        traceback.print_exc()
        return 1


if __name__ == "__main__":
    sys.exit(main())
