# USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
# Licensed under the MIT License. See LICENSE.txt for details.
#
# Runs USD validation via the pxr.UsdValidation framework, with the same
# validators as usdchecker (UsdUtils.ComplianceChecker was removed in
# OpenUSD 26.08).
# argv layout: [script.py, file1.usd [, file2.usd ...]]

from __future__ import print_function
import sys
import os

os.environ.pop('PXR_PLUGINPATH_NAME', None)

# Validator checking only the root layer of a package; usdchecker uses it
# only with --rootPackageOnly and otherwise checks the whole package.
ROOT_PACKAGE_VALIDATOR = "usdUtilsValidators:RootPackageValidator"


def is_validator_used(validator_name):
    """Tell whether a registered validator is part of the Validate command

    Args:
        validator_name (str): Full validator name ("plugin:Validator").

    Returns:
        bool: False for the root-package-only validator, True otherwise.
    """
    return validator_name != ROOT_PACKAGE_VALIDATOR


def make_validation_context(usd_validation):
    """Build a validation context with every registered validator used by usdchecker

    Args:
        usd_validation (module): The pxr.UsdValidation module.

    Returns:
        UsdValidation.ValidationContext: Context running those validators.
    """
    registry = usd_validation.ValidationRegistry()
    # shortcut: validator suites are left out (none registered in OpenUSD
    # 26.11); load them with GetOrLoadValidatorSuitesByName when one appears.
    validator_names = [
        metadata.name for metadata in registry.GetAllValidatorMetadata()
        if not metadata.isSuite and is_validator_used(metadata.name)
    ]
    return usd_validation.ValidationContext(registry.GetOrLoadValidatorsByName(validator_names))


def main():
    if len(sys.argv) < 2:
        print("Usage: UsdValidate.py <usd_file> [...]")
        return 1

    usd_paths = sys.argv[1:]

    try:
        from pxr import Tf, Usd, UsdValidation
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

    try:
        validation_context = make_validation_context(UsdValidation)
    except Exception as e:
        print("Error: Failed to load the USD validators.")
        print("  %s" % str(e))
        return 1

    print("USD Validate")
    print("=" * 72)

    passed = 0
    failed = 0

    for idx, usd_path in enumerate(usd_paths):
        if idx > 0:
            print()

        if len(usd_paths) > 1:
            print("[ %s ]" % os.path.basename(usd_path))
            print("  %s" % usd_path)
        else:
            print("File: %s" % usd_path)
        print()

        # Validate the stage with its default variant selections, like
        # usdchecker's first pass.
        # shortcut: other variant combinations are not validated (usdchecker
        # tries them up to a limit); add it if users ask for it.
        try:
            stage = Usd.Stage.Open(usd_path)
            validation_errors = validation_context.Validate(stage)
        except Exception as e:
            print("Error during validation: %s" % str(e))
            print()
            print("Failed!")
            failed += 1
            continue

        error_type = UsdValidation.ValidationErrorType
        errors = [e.GetErrorAsString() for e in validation_errors if e.GetType() == error_type.Error]
        warnings = [e.GetErrorAsString() for e in validation_errors if e.GetType() != error_type.Error]

        if warnings:
            for w in warnings:
                print(str(w))
            print()

        if errors:
            for err in errors:
                print(str(err))
            print()
            print("Failed!")
            failed += 1
        else:
            if warnings:
                print("Success (with warnings).")
            else:
                print("Success!")
            passed += 1

    if len(usd_paths) > 1:
        print()
        print("-" * 72)
        print("Summary: %d/%d passed" % (passed, len(usd_paths)))

    print()
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
