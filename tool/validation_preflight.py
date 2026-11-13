#!/usr/bin/env python3
"""Read build prerequisites without installing tools or touching any app data."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess


def probe(command):
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=15)
        return result.stdout.strip() if result.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def collect():
    flutter = os.environ.get('FLUTTER_BIN') or shutil.which('flutter')
    version = {}
    if flutter:
        try:
            version = json.loads((Path(flutter).parent / 'cache/flutter.version.json').read_text())
        except (OSError, ValueError):
            pass
    sdk_value = os.environ.get('ANDROID_SDK_ROOT') or os.environ.get('ANDROID_HOME')
    sdk = Path(sdk_value) if sdk_value else None
    adb = sdk / 'platform-tools/adb' if sdk else None
    android_available = bool(adb and adb.is_file() and any((sdk / 'build-tools').glob('*/aapt')))
    developer = probe(['xcode-select', '-p'])
    ios_sdk = probe(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'])
    full_xcode = bool(developer and not developer.endswith('/CommandLineTools') and ios_sdk)
    return {
        'schemaVersion': 1,
        'flutter': {
            'path': flutter,
            'version': version.get('flutterVersion'),
            'dartVersion': version.get('dartSdkVersion'),
            'available': bool(flutter and Path(flutter).is_file()),
        },
        'android': {'sdkAvailable': android_available, 'sdkPath': str(sdk) if sdk else None},
        'ios': {'developerDirectory': developer, 'sdkAvailable': bool(ios_sdk),
                'readyForBuild': bool(full_xcode and flutter)},
        'cryptoPrototype': {'goAvailable': shutil.which('go') is not None,
                            'cargoAvailable': shutil.which('cargo') is not None},
        'deviceVerification': 'not-performed',
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--json', action='store_true', help='Print a machine-readable report')
    parser.parse_args()
    print(json.dumps(collect(), indent=2, ensure_ascii=False))


if __name__ == '__main__':
    main()
