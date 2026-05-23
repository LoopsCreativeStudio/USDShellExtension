# USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
# Licensed under the MIT License. See LICENSE.txt for details.
#
# Wrapper for usdfixbrokenpixarschemas: patches Tf.ErrorException.__str__
# before the tool runs to avoid CP1252/UTF-8 decode errors in error messages.
# argv layout: [wrapper.py, tool_script_path, file.usd]

from __future__ import print_function
import sys
import os
import importlib
import importlib.util
from importlib.machinery import SourceFileLoader
from importlib.util import spec_from_loader

# The COM server sets PXR_PLUGINPATH_NAME to the extension's install directory.
# When the NVIDIA SDK python.exe loads USD it already has usd_sdf.dll etc. from
# the SDK; inheriting that path makes plug try to load a second copy from
# Program Files, which fails with DllMain returning FALSE. Clear it so the SDK
# python uses only its own built-in plugin chain.
os.environ.pop('PXR_PLUGINPATH_NAME', None)

try:
    from pxr import Tf
    _orig_tf_err_str = Tf.ErrorException.__str__

    def _safe_tf_err_str(self):
        try:
            return _orig_tf_err_str(self)
        except UnicodeDecodeError as ude:
            # ude.object holds the raw bytes pxr_boost tried to decode as UTF-8.
            # Re-decode as CP1252 (Windows-1252) to recover the actual message.
            try:
                return bytes(ude.object).decode('cp1252', errors='replace')
            except Exception:
                return 'Tf.ErrorException (message undecodable)'
        except UnicodeEncodeError:
            return 'Tf.ErrorException (message undecodable)'

    Tf.ErrorException.__str__ = _safe_tf_err_str
except Exception:
    pass

_usd_path = sys.argv[2] if len(sys.argv) > 2 else ""

print("USD Fix")
print("=" * 72)
print("File: %s" % _usd_path)
print()

sys.argv = sys.argv[1:]
_script = sys.argv[0]

spec = spec_from_loader('__main__', SourceFileLoader('__main__', _script))
mod = importlib.util.module_from_spec(spec)
sys.modules['__main__'] = mod
try:
    spec.loader.exec_module(mod)
except SystemExit:
    pass
except Exception as e:
    if getattr(e, 'winerror', None) == 1224:
        print("\nError: Cannot write to the file while the Explorer Preview pane has it open.")
        print("  Switch to Details view to close the Preview pane, then try again.")
    else:
        print("\nError: %s" % str(e))

input("\nPress Enter to close...")
