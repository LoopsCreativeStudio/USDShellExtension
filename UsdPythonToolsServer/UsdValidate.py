# USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
# Licensed under the MIT License. See LICENSE.txt for details.
#
# Runs USD compliance checking via pxr.UsdUtils.ComplianceChecker.
# argv layout: [script.py, file.usd]

from __future__ import print_function
import sys
import os

os.environ.pop('PXR_PLUGINPATH_NAME', None)


def main():
    if len(sys.argv) < 2:
        print("Usage: UsdValidate.py <usd_file>")
        input("\nPress Enter to close...")
        return 1

    usd_path = sys.argv[1]

    try:
        from pxr import Tf, UsdUtils
    except ImportError as e:
        print("Error: could not import pxr USD library.")
        print(str(e))
        input("\nPress Enter to close...")
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

    print("USD Validate")
    print("=" * 72)
    print("File: %s" % usd_path)
    print()

    try:
        import inspect
        _sig = inspect.signature(UsdUtils.ComplianceChecker.__init__)
        _valid = set(_sig.parameters.keys())
        _kwargs = {}
        for _k in ('arkit', 'skipARKinds', 'rootPackageOnly', 'skipVariants', 'verbose'):
            if _k in _valid:
                _kwargs[_k] = False
        checker = UsdUtils.ComplianceChecker(**_kwargs)
    except Exception as e:
        print("Error: Failed to initialize ComplianceChecker.")
        print("  %s" % str(e))
        print()
        input("Press Enter to close...")
        return 1

    try:
        checker.CheckCompliance(usd_path)
    except Exception as e:
        print("Error during validation: %s" % str(e))
        print()
        input("Press Enter to close...")
        return 1

    errors = checker.GetErrors()
    warnings = checker.GetWarnings()

    if warnings:
        for w in warnings:
            print(str(w))
        print()

    if errors:
        for err in errors:
            print(str(err))
        print()
        print("Failed!")
    else:
        if warnings:
            print("Success (with warnings).")
        else:
            print("Success!")

    print()
    input("Press Enter to close...")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
