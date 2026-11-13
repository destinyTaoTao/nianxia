#!/usr/bin/env python3
"""Boot the existing macOS/API36 AVD with a verified audio-buffer image copy.

No application install, userdata operation, root service, or SDK image mutation.
The hashes deliberately pin the tested system image; SDK updates fail closed.
"""
import argparse
import hashlib
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import uuid


SOURCE_SHA256 = 'a9d4f0b6fd7ef770a18272bfe675df4afbd9bb56f06a865b0ed69332e3081c8c'
TUNED_SHA256 = '907a2454e02b9d610e990b34bb24d0734e242a8cdc3737515bbd63607d31df89'
ORIGINAL_PROPERTY = b'ro.hardware.audio.tinyalsa.period_size_multiplier=2'
TUNED_PROPERTY = b'ro.hardware.audio.tinyalsa.period_size_multiplier=8'


def file_hash(path):
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(8 * 1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def prepare_image(source, output, original_hash, tuned_hash):
    if source.resolve() == output.resolve():
        raise ValueError('Refused to modify the original SDK image')
    if file_hash(source) != original_hash:
        raise ValueError('Unrecognized SDK image; keep the existing AVD and revalidate audio')
    if output.exists() or output.is_symlink():
        if output.is_symlink() or file_hash(output) != tuned_hash:
            raise ValueError('Existing profile is unrecognized; it was not overwritten')
        return output

    offsets = []
    carry, position = b'', 0
    with source.open('rb') as handle:
        for block in iter(lambda: handle.read(8 * 1024 * 1024), b''):
            data = carry + block
            cursor = 0
            while True:
                found = data.find(ORIGINAL_PROPERTY, cursor)
                if found < 0:
                    break
                offsets.append(position - len(carry) + found)
                cursor = found + len(ORIGINAL_PROPERTY)
            carry = data[-(len(ORIGINAL_PROPERTY) - 1):]
            position += len(block)
    if len(offsets) != 1:
        raise ValueError('Expected one frozen vendor audio property; image was not modified')

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name('.' + output.name + '.' + uuid.uuid4().hex + '.partial')
    try:
        if platform.system() == 'Darwin':
            # APFS clone: the multi-GB base stays shared, only the changed block
            # is copied. Other filesystems can use a normal private copy.
            result = subprocess.run(['/bin/cp', '-c', str(source), str(temporary)],
                                    capture_output=True)
            if result.returncode:
                if temporary.exists():
                    temporary.unlink()
                shutil.copyfile(source, temporary)
        else:
            shutil.copyfile(source, temporary)
        with temporary.open('r+b') as handle:
            handle.seek(offsets[0])
            if handle.read(len(ORIGINAL_PROPERTY)) != ORIGINAL_PROPERTY:
                raise ValueError('Copy verification failed')
            handle.seek(offsets[0])
            handle.write(TUNED_PROPERTY)
            handle.flush()
            os.fsync(handle.fileno())
        if file_hash(temporary) != tuned_hash:
            raise ValueError('Tuned image verification failed; original image is unchanged')
        # Hard-link publication fails if another process already owns the path.
        os.link(temporary, output)
    finally:
        if temporary.exists():
            temporary.unlink()
    return output


def prepare_directory(source_directory, directory, image):
    directory.mkdir(parents=True, exist_ok=True)
    for source in source_directory.iterdir():
        target = image if source.name == 'system.img' else source
        destination = directory / source.name
        if destination.exists() or destination.is_symlink():
            if not destination.is_symlink() or destination.resolve() != target.resolve():
                raise ValueError('Existing system directory has an unexpected file')
        else:
            destination.symlink_to(target.resolve(), target_is_directory=source.is_dir())
    return directory


def boot_command(sdk, directory, avd):
    return [str(sdk / 'emulator' / 'emulator'), '-avd', avd, '-port', '5554',
            '-sysdir', str(directory), '-audio', 'coreaudio', '-allow-host-audio',
            '-no-snapshot', '-no-boot-anim', '-crash-report-mode', 'disabled',
            '-no-metrics']


def read_properties(file):
    return {key.strip(): value.strip()
            for line in file.read_text().splitlines()
            if not line.lstrip().startswith('#') and '=' in line
            for key, value in [line.split('=', 1)]}


def validate_avd(config, sdk, source, profile):
    expected = {'target': 'android-36', 'abi.type': 'arm64-v8a',
                'hw.cpu.arch': 'arm64', 'tag.id': 'google_apis'}
    if any(config.get(key) != value for key, value in expected.items()):
        raise ValueError('AVD target/ABI does not match the verified API36 image; data was not opened')
    image_directory = config.get('image.sysdir.1')
    if not image_directory or (sdk / image_directory).resolve() not in (
            source.resolve(), (profile / 'sysdir').resolve()):
        raise ValueError('AVD uses a different system image; data was not opened')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--avd', choices=['nianxia-api36'], default='nianxia-api36')
    parser.add_argument('--prepare-only', action='store_true')
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        raise ValueError('This workaround is verified only for macOS CoreAudio')
    setting = os.environ.get('ANDROID_SDK_ROOT') or os.environ.get('ANDROID_HOME')
    if not setting:
        raise ValueError('Set ANDROID_SDK_ROOT')
    sdk = Path(setting).expanduser().resolve()
    source = sdk / 'system-images/android-36/google_apis/arm64-v8a'
    if not (sdk / 'emulator/emulator').is_file() or not (source / 'system.img').is_file():
        raise ValueError('Expected the verified API36 google_apis/arm64-v8a SDK image')
    profile = sdk.parent / 'emulator-overrides' / 'api36-microphone'
    android_home = Path(os.environ.get('ANDROID_USER_HOME', Path.home() / '.android'))
    avd_home = Path(os.environ.get('ANDROID_AVD_HOME', android_home / 'avd'))
    descriptor = read_properties(avd_home / (args.avd + '.ini'))
    if 'path' not in descriptor:
        raise ValueError('AVD descriptor has no explicit data directory')
    validate_avd(read_properties(Path(descriptor['path']) / 'config.ini'),
                  sdk, source, profile)
    if not args.prepare_only:
        state = subprocess.run([str(sdk / 'platform-tools/adb'), '-s',
                                'emulator-5554', 'get-state'], capture_output=True, text=True)
        if state.returncode == 0:
            raise ValueError('emulator-5554 is running; close it normally first. No data was cleared')
    image = prepare_image(source / 'system.img', profile / 'system-audio.img',
                          SOURCE_SHA256, TUNED_SHA256)
    directory = prepare_directory(source, profile / 'sysdir', image)
    print('Verified audio profile:', directory, flush=True)
    if args.prepare_only:
        return
    environment = {k: v for k, v in os.environ.items()
                   if not k.startswith(('QEMU_AUDIO_', 'QEMU_COREAUDIO_'))}
    environment.update(QEMU_AUDIO_IN_DRV='coreaudio', QEMU_AUDIO_OUT_DRV='coreaudio')
    command = boot_command(sdk, directory, args.avd)
    os.execvpe(command[0], command, environment)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError) as error:
        print('Error:', error, file=sys.stderr)
        sys.exit(1)
