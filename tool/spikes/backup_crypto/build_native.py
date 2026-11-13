#!/usr/bin/env python3
"""Build the locked experimental age library; never install an app or change global tools."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT=Path(__file__).resolve().parents[3]
SPIKE=Path(__file__).resolve().parent
WORK=ROOT/'.superpowers/sdd/2026-11-13-encrypted-backup'

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--platform',required=True,choices=('host','android'));args=parser.parse_args()
    env=dict(os.environ)
    cargo=shutil.which('cargo')
    if not cargo:
        cargo=str(WORK/'cargo/bin/cargo');env.update(RUSTUP_HOME=str(WORK/'rustup'),CARGO_HOME=str(WORK/'cargo'))
    command=[cargo,'build','--locked','--release','--manifest-path',str(SPIKE/'native/Cargo.toml')]
    if args.platform=='android':
        sdk=Path(env.get('ANDROID_SDK_ROOT',''))
        ndk=sdk/'ndk/28.2.13676358'
        candidates=list((ndk/'toolchains/llvm/prebuilt').glob('*/bin/aarch64-linux-android24-clang'))
        if len(candidates)!=1:parser.error('Expected installed NDK 28.2.13676358 with API24 ARM64 linker')
        env['CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER']=str(candidates[0])
        command+=['--target','aarch64-linux-android','--lib']
    subprocess.run(command,env=env,check=True)
    if args.platform=='android':
        source=SPIKE/'native/target/aarch64-linux-android/release/libnianxia_age_spike.so'
        destination=ROOT/'build/backup_crypto/jniLibs/arm64-v8a/libnianxia_age_spike.so'
        destination.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,destination)
        print('Prepared isolated test native library; no application installed.')

if __name__=='__main__':main()
