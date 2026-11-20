#!/usr/bin/env python3
"""Set SDK locations while preserving Flutter version and user properties."""
import argparse
from pathlib import Path


def configure(android_dir: Path, flutter_sdk: Path, android_sdk: Path) -> None:
    if not (flutter_sdk / 'packages/flutter_tools/gradle').is_dir():
        raise ValueError(f'Flutter Gradle plugin is missing from {flutter_sdk}')
    if not android_sdk.is_dir():
        raise ValueError(f'Android SDK directory does not exist: {android_sdk}')
    target = android_dir / 'local.properties'
    original = target.read_text() if target.exists() else ''
    retained = [line for line in original.splitlines()
                if not line.lstrip().startswith(('sdk.dir=', 'flutter.sdk='))]
    def escape(value: Path) -> str:
        return str(value.resolve()).replace(chr(92), chr(92) * 2)
    retained.extend([f'sdk.dir={escape(android_sdk)}', f'flutter.sdk={escape(flutter_sdk)}'])
    target.write_text(chr(10).join(retained) + chr(10))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--android-dir', type=Path, required=True)
    parser.add_argument('--flutter-sdk', type=Path, required=True)
    parser.add_argument('--android-sdk', type=Path, required=True)
    args = parser.parse_args()
    configure(args.android_dir, args.flutter_sdk, args.android_sdk)
