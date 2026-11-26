#!/usr/bin/env python3
"""Read-only APK inspection; writes JSON/text evidence, never installs apps."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import zipfile


def require(value, message):
    if not value:
        raise RuntimeError(message)


def command(*args):
    return subprocess.check_output(list(map(str, args)), text=True)


def resource_path(table, identifier):
    match = re.search(r'^\s+resource ' + re.escape(identifier) + r' [^\n]+\n\s+\(string8\) "([^"]+)"', table, re.M)
    require(match, 'Cannot resolve packaged XML resource: ' + identifier)
    return match.group(1)


def exclusions(text):
    result = {}
    scope = 'backup'
    current = None
    for line in text.splitlines():
        match = re.search(r'E: (cloud-backup|device-transfer) ', line)
        if match:
            scope = match.group(1)
        if 'E: exclude ' in line:
            current = {}
            result.setdefault(scope, []).append(current)
        match = re.search(r'A: (domain|path)="([^"]*)"', line)
        if match and current is not None:
            current[match.group(1)] = match.group(2)
    return result


def inspect(artifacts, output, tools, source):
    results = []
    domains = {'root', 'file', 'database', 'sharedpref', 'external', 'device_root', 'device_file', 'device_database', 'device_sharedpref'}
    for kind, filename, application, label in [
        ('ordinary', 'nianxia-ordinary-release-INSPECTION-ONLY.apk', 'app.nianxia.nianxia', '念下'),
        ('isolated', 'nianxia-test-release-candidate.apk', 'app.nianxia.nianxia.test', '念下·测试'),
    ]:
        apk = artifacts / filename
        badging = command(tools / 'aapt', 'dump', 'badging', apk)
        manifest = command(tools / 'aapt', 'dump', 'xmltree', apk, 'AndroidManifest.xml')
        signature = command(tools / 'apksigner', 'verify', '--verbose', '--print-certs', apk)
        table = command(tools / 'aapt', 'dump', '--values', 'resources', apk)
        resources = {}
        for attribute in ['fullBackupContent', 'dataExtractionRules']:
            match = re.search(r'android:' + attribute + r'[^\n]*=@(0x[0-9a-f]+)', manifest)
            require(match, 'Missing backup resource: ' + attribute)
            path = resource_path(table, match.group(1))
            resources[attribute] = {'resourceId': match.group(1), 'apkPath': path,
                                    'xml': command(tools / 'aapt', 'dump', 'xmltree', apk, path)}
        for suffix, text in [('badging', badging), ('manifest', manifest), ('signature', signature), ('resources', table),
                             ('backup-rules', resources['fullBackupContent']['xml']), ('data-extraction-rules', resources['dataExtractionRules']['xml'])]:
            (output / (kind + '-' + suffix + '.txt')).write_text('\n'.join(line.rstrip() for line in text.splitlines()) + '\n')
        with zipfile.ZipFile(apk) as archive:
            names = archive.namelist()
            libraries = [n for n in names if n.startswith('lib/') and n.endswith('.so')]
            abis = sorted({n.split('/')[1] for n in libraries})
            crypto = [n for n in names if 'age_spike' in n or n.endswith('.age')]
            weights = [n for n in names if n.endswith(('.onnx', '.safetensors'))]
            userdata = [n for n in names if n.endswith(('.sqlite', '.db', '.wav', '.keystore', '.jks'))]
            model_matches = hashlib.sha256(archive.read('assets/flutter_assets/assets/models.json')).hexdigest() == source['modelManifestSha256']
            licenses = all('assets/flutter_assets/assets/licenses/' + n in names for n in ['BGE-LICENSE.txt', 'FunASR-MODEL-LICENSE.txt'])
        permissions = re.findall(r"^uses-permission: name='([^']+)'", badging, re.M)
        provider = 'app.nianxia.nianxia.ValidationResultProvider' in manifest
        signer = re.search(r'^Signer #1 certificate DN: (.+)$', signature, re.M)
        cert = re.search(r'^Signer #1 certificate SHA-256 digest: ([0-9a-f]+)$', signature, re.M)
        debug = 'application-debuggable' in badging or bool(re.search(r'android:debuggable.*0xffffffff', manifest))
        backup = exclusions(resources['fullBackupContent']['xml']).get('backup', [])
        extraction = exclusions(resources['dataExtractionRules']['xml'])
        def excludes_all(entries):
            return len(entries) == len(domains) and {r.get('domain') for r in entries} == domains and all(r.get('path') == '.' for r in entries)
        expected_permissions = {'android.permission.RECORD_AUDIO', 'android.permission.FOREGROUND_SERVICE', 'android.permission.FOREGROUND_SERVICE_MICROPHONE', 'android.permission.INTERNET', 'android.permission.ACCESS_NETWORK_STATE', application + '.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION'}
        checks = {
            'applicationId': badging.startswith("package: name='" + application + "' "), 'label': "application-label:'" + label + "'" in badging,
            'releaseNotDebuggable': not debug, 'minSdk24': "sdkVersion:'24'" in badging, 'targetSdk36': "targetSdkVersion:'36'" in badging,
            'arm64Only': abis == ['arm64-v8a'], 'backupDisabled': bool(re.search(r'android:allowBackup.*0x0\b', manifest)),
            'cleartextDisabled': bool(re.search(r'android:usesCleartextTraffic.*0x0\b', manifest)),
            'backupRulesExcludeAllDomains': excludes_all(backup), 'cloudAndTransferExcludeAllDomains': all(excludes_all(extraction.get(scope, [])) for scope in ['cloud-backup', 'device-transfer']),
            'noExperimentalCrypto': not crypto, 'noModelWeights': not weights, 'noUserDataOrKeystoreFiles': not userdata,
            'modelManifestMatchesSource': model_matches, 'modelLicenseFilesIncluded': licenses,
            'expectedValidationProvider': provider == (kind == 'isolated'), 'signatureVerified': cert is not None,
            'v2Signature': 'Verified using v2 scheme (APK Signature Scheme v2): true' in signature,
            'expectedPermissionSet': set(permissions) == expected_permissions,
        }
        failed = [key for key, value in checks.items() if not value]
        require(not failed, kind + ' inspection failed: ' + ', '.join(failed))
        results.append({'kind': kind, 'applicationId': application, 'label': label, 'mode': 'release', 'entry': 'lib/main.dart' if kind == 'ordinary' else 'integration_test/preview/main.dart',
                        'artifact': str(apk.resolve()), 'bytes': apk.stat().st_size, 'sha256': hashlib.sha256(apk.read_bytes()).hexdigest(),
                        'abis': abis, 'minSdk': 24, 'targetSdk': 36, 'permissions': permissions, 'nativeLibraries': libraries,
                        'signer': signer.group(1) if signer else None, 'certificateSha256': cert.group(1),
                        'trialDebugSignature': signer is not None and 'CN=Android Debug' in signer.group(1), 'validationProviderDeclared': provider,
                        'built': True, 'installed': False, 'launched': False, 'runtimeAccepted': False, 'publicDistributionReady': False,
                        'checks': checks, 'backupResources': {k: {a: b for a, b in v.items() if a != 'xml'} for k, v in resources.items()},
                        'sourceHead': source['head'], 'sourceDigest': source['sourceDigest']})
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifacts', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--tools', type=Path, required=True)
    parser.add_argument('--source', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    source = json.loads(args.source.read_text())
    results = inspect(args.artifacts, args.output, args.tools, source)
    summary = {'date': '2026-11-26', 'artifactChecksPassed': True, 'devicesTouched': False, 'candidates': results,
               'qualification': 'build/package inspection only; debug-signed trials; no install/runtime/device acceptance'}
    (args.output / 'android-candidates.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
    print('Both APKs passed', len(results[0]['checks']), 'artifact checks. No install or launch.')


if __name__ == '__main__':
    main()
