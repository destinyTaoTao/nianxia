#!/usr/bin/env python3
"""Synthetic, temporary, file-to-file age interoperability and corruption tests."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import zipfile

ROOT = Path(__file__).resolve().parents[3]
SPIKE = Path(__file__).resolve().parent
WORK = ROOT / '.superpowers/sdd/2026-11-13-encrypted-backup'


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as file:
        for chunk in iter(lambda: file.read(1048576), b''):
            result.update(chunk)
    return result.hexdigest()


def convert(engine, mode, source, output, password, n=18):
    command = ([str(SPIKE / 'native/target/release/nx-age'), mode, str(source), str(output), str(n), '18', '65536']
               if engine == 'rust' else [str(WORK / 'age-reference'), mode, str(source), str(output), str(n)])
    started = time.monotonic()
    result = subprocess.run(command, input=password.encode('utf-8'), capture_output=True, timeout=1800)
    # Never include subprocess stderr, password, or input contents in reports.
    return result.returncode, round((time.monotonic()-started)*1000)


def payload(path, size):
    block = bytes(range(256))*4096
    with path.open('xb') as file:
        while size:
            count = min(size, len(block));file.write(block[:count]);size -= count


def roundtrip(work, size, large=False):
    plain = work / 'plain'
    if large:
        data = work / 'synthetic.bin';payload(data, size)
        with zipfile.ZipFile(plain, 'w', compression=zipfile.ZIP_STORED, allowZip64=True) as z:
            z.write(data, 'synthetic.bin')
        data.unlink()
    else:
        payload(plain, size)
    fingerprint = digest(plain)
    passwords = ['中文备份🔒', 'e\u0301组合字符', ' 前后空格 ', 'trailing ', ' leading'] if not large else ['合成大包🔒']
    cases = []
    for index, password in enumerate(passwords):
        for encryptor,decryptor in [('go','rust'),('rust','go')]:
            encrypted=work/f'cipher-{index}-{encryptor}';decoded=work/'decoded'
            code,enc_ms=convert(encryptor,'encrypt',plain,encrypted,password)
            if code:raise RuntimeError('reference interoperability encryption failed')
            code,dec_ms=convert(decryptor,'decrypt',encrypted,decoded,password)
            if code or digest(decoded)!=fingerprint:raise RuntimeError('reference interoperability mismatch')
            cases.append({'case':f'password-{index}-{encryptor}-to-{decryptor}','passed':True,'encryptMs':enc_ms,'decryptMs':dec_ms,'inputBytes':plain.stat().st_size})
            decoded.unlink();encrypted.unlink()
    if large:
        with zipfile.ZipFile(plain) as z:
            # Reads every actual byte and checks the ZIP CRC; no sparse/header-only fixture.
            if z.testzip() is not None:raise RuntimeError('ZIP64 integrity failed')
    else:
        encrypted=work/'valid';password='public synthetic corruption test'
        if convert('go','encrypt',plain,encrypted,password,n=16)[0]:raise RuntimeError('fixture encryption failed')
        data=encrypted.read_bytes();footer=data.index(b'\n--- ');start=data.index(b'\n',footer+1)+1+16
        flip=bytearray(data);flip[start+123]^=1
        header=bytearray(data);header[footer+6]^=1
        block=65536+16
        mutations={
            'wrong-password':data,'payload-bit':bytes(flip),'header-bit':bytes(header),
            'missing-final-byte':data[:-1],'missing-final-chunk':data[:start+block],
            'delete-first-chunk':data[:start]+data[start+block:],
            'reorder-chunks':data[:start]+data[start+block:start+2*block]+data[start:start+block]+data[start+2*block:],
            'trailing-garbage':data+b'x',
            'work-factor-30':data.replace(b' 16\n',b' 30\n',1),
            'header-over-budget':b'age-encryption.org/v1\n'+b'x'*65536,
        }
        for name,content in mutations.items():
            bad=work/'bad';bad.write_bytes(content);out=work/'rejected'
            code,elapsed=convert('rust','decrypt',bad,out,'different' if name=='wrong-password' else password)
            if code==0 or out.exists() or (work/'rejected.partial').exists():raise RuntimeError('corruption published plaintext: '+name)
            if name in ('work-factor-30','header-over-budget') and code!=2:raise RuntimeError('resource bound not enforced')
            cases.append({'case':name,'passed':True,'durationMs':elapsed,'errorCode':code})
    return {'fixtureSha256':fingerprint,'actualInputBytes':plain.stat().st_size,'cases':cases}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phase',required=True,choices=('host-contract','large-container'))
    parser.add_argument('--fixture-bytes',type=int,default=1048576)
    parser.add_argument('--minimum-bytes',type=int,default=4294967297)
    args=parser.parse_args()
    size=args.minimum_bytes if args.phase=='large-container' else args.fixture_bytes
    if size<150000 or size>8*1024**3:parser.error('synthetic fixture must be 150000..8GiB')
    if args.phase=='large-container' and size<=4294967296:parser.error('large fixture must exceed 4GiB')
    if shutil.disk_usage(WORK).free<size*4+1024**3:raise RuntimeError('insufficient private temporary space budget')
    with tempfile.TemporaryDirectory(prefix='age-synthetic-',dir=WORK) as temporary:
        work=Path(temporary);(work/'SYNTHETIC_FIXTURE').write_text('No user data\n')
        report=roundtrip(work,size,args.phase=='large-container')
    report.update({'executionDate':'2026-11-14','phase':args.phase,'platform':'macOS arm64 host','passed':True,'scope':'standard container interop only; not app restore or mobile acceptance'})
    out=ROOT/'docs/validation/2026-11-13-architecture-ui/backup';out.mkdir(parents=True,exist_ok=True)
    (out/f'{args.phase}.json').write_text(json.dumps(report,indent=2)+'\n')
    print(f'PASS {args.phase}: {len(report["cases"])} cases; actual input {report["actualInputBytes"]} bytes; synthetic workspace removed.')


if __name__=='__main__':main()
