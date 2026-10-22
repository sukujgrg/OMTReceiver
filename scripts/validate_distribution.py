#!/usr/bin/env python3
"""Local App Store packaging checks. Does not perform Apple's server validation."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def require(condition, message):
    if not condition:
        raise ValueError(message)


def load_plist(path):
    return plistlib.loads(path.read_bytes())


def validate_privacy(value):
    require(value.get('NSPrivacyTracking') is False, 'Tracking must be declared false')
    require(value.get('NSPrivacyTrackingDomains') == [], 'Unexpected tracking domains')
    require(value.get('NSPrivacyCollectedDataTypes') == [], 'Re-audit collection and policy before adding collected data')
    entries = value.get('NSPrivacyAccessedAPITypes', [])
    categories = {r['NSPrivacyAccessedAPIType']: set(r['NSPrivacyAccessedAPITypeReasons']) for r in entries}
    require(len(entries) == 2 and categories == {
        'NSPrivacyAccessedAPICategoryUserDefaults': {'CA92.1'},
        'NSPrivacyAccessedAPICategorySystemBootTime': {'35F9.1', '8FFB.1'}
    }, 'Required-reason declarations do not match the audited app')


def validate_source():
    version = (ROOT/'VERSION').read_text().strip()
    build = (ROOT/'BUILD_NUMBER').read_text().strip()
    require(re.fullmatch(r'[0-9]+\.[0-9]+(?:\.[0-9]+)?', version), 'Invalid VERSION')
    require(re.fullmatch(r'[1-9][0-9]*', build), 'Invalid BUILD_NUMBER')
    validate_privacy(load_plist(ROOT/'OMTReceiver/PrivacyInfo.xcprivacy'))
    require(load_plist(ROOT/'OMTReceiver/Info.plist').get('ITSAppUsesNonExemptEncryption') is False, 'Encryption declaration missing')
    notices = (ROOT/'OMTReceiver/Resources/ThirdPartyNotices.txt').read_text()
    require((ROOT/'LICENSE').read_text().strip() in notices, 'Original MIT licence is not bundled')
    require((ROOT/'Vendor/libvmx/LICENSE.txt').read_text().strip() in notices, 'VMX MIT licence is not bundled')
    require('Copyright (c) 2015-2024 SSE2NEON Contributors.' in notices, 'sse2neon notice is not bundled')
    require('THE SOFTWARE IS PROVIDED "AS IS"' in notices, 'Incomplete licence notice')
    metadata = json.loads((ROOT/'AppStore/Metadata.json').read_text())
    for key, limit in [('name',30),('subtitle',30),('keywords',100),('promotionalText',170),('description',4000)]:
        require(0 < len(metadata[key]) <= limit, key+' exceeds the store field limit')
    for key in ['supportURL','privacyPolicyURL','marketingURL']:
        require(metadata[key].startswith('https://sukujgrg.github.io/OMTReceiver/'), 'Unexpected public website URL')
    require(load_plist(ROOT/'AppStore/ExportOptions.plist').get('destination') == 'export', 'Export must not upload')
    assets = ROOT/'OMTReceiver/Assets.xcassets/AppIcon.brandassets'
    for stack, size in [('Small',(400,240)), ('Large',(1280,768))]:
        layers = json.loads((assets/(stack+'.imagestack')/'Contents.json').read_text())['layers']
        require(2 <= len(layers) <= 5, 'tvOS icon must have two to five layers')
        for layer in layers:
            directory = assets/(stack+'.imagestack')/layer['filename']/'Content.imageset'
            for item in json.loads((directory/'Contents.json').read_text())['images']:
                data = (directory/item['filename']).read_bytes()
                require(data[:8] == b'\x89PNG\r\n\x1a\n', 'Invalid icon PNG')
                dimensions = struct.unpack('>II',data[16:24])
                scale = int(item['scale'][:-1])
                require(dimensions == (size[0]*scale,size[1]*scale), 'Incorrect tvOS icon dimensions')
    print('Source, licence, privacy, icon and metadata checks passed.')


def audit_public_index():
    files = subprocess.check_output(['git','ls-files','-z'],cwd=ROOT).decode().split('\0')
    sensitive = [rb'-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----',
                 rb'(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})',
                 rb'AKIA[A-Z0-9]{16}', rb'/(?:Users)/[^/\s]+/',
                 rb'DEVELOPMENT_TEAM\s*[=:]\s*[\"\x27]?[A-Z0-9]{10}\b']
    findings = []
    for name in filter(None, files):
        if name.startswith(('Validation/','build/')) or 'xcuserdata/' in name or name.endswith(('.p8','.p12','.key','.mobileprovision')):
            findings.append(name+': private/generated file')
        path = ROOT/name
        if path.is_file():
            data = path.read_bytes()
            if any(re.search(pattern,data) for pattern in sensitive): findings.append(name+': credential or local identity pattern')
    require(not findings, 'Public source audit failed:\n'+'\n'.join(findings))
    print('Tracked public-source audit passed. This pattern audit is not a guarantee that arbitrary secrets cannot exist.')


def validate_app(app, distribution=False):
    info = load_plist(app/'Info.plist')
    require(info.get('CFBundleIdentifier') == 'com.suku.OMTReceiver', 'Unexpected bundle identifier')
    require(info.get('CFBundlePackageType') == 'APPL', 'Not an application bundle')
    require(info.get('UIDeviceFamily') == [3], 'Not a tvOS-only application')
    require(info.get('CFBundleSupportedPlatforms') == ['AppleTVOS'], 'Not a device tvOS build')
    require(info.get('CFBundleShortVersionString') == (ROOT/'VERSION').read_text().strip(), 'Archive version differs from VERSION')
    require(re.fullmatch(r'[1-9][0-9]*', info.get('CFBundleVersion','')), 'Invalid archive build number')
    sdk = re.search(r'appletvos([0-9]+)', info.get('DTSDKName',''))
    require(sdk and int(sdk[1]) >= 26, 'Archive must use tvOS SDK 26 or later')
    require(info.get('ITSAppUsesNonExemptEncryption') is False, 'Missing archive encryption declaration')
    validate_privacy(load_plist(app/'PrivacyInfo.xcprivacy'))
    for name in ['GettingStarted.txt','PrivacyPolicy.txt','ThirdPartyNotices.txt']:
        require((app/name).read_bytes() == (ROOT/'OMTReceiver/Resources'/name).read_bytes(), 'Missing or stale bundled '+name)
    executable = app/info['CFBundleExecutable']
    archs = subprocess.check_output(['xcrun','lipo','-archs',str(executable)],text=True).strip()
    require(archs == 'arm64', 'Unexpected application architectures: '+archs)
    require((app/'Assets.car').is_file(), 'Compiled assets missing')
    dependencies = subprocess.check_output(['otool','-L',str(executable)],text=True)
    require(not re.search(r'lib(?:omt|vmx)\.dylib|NDI|/Users/',dependencies,re.I), 'Unexpected external media runtime or local dependency')
    if (app/'_CodeSignature').exists():
        subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True,capture_output=True)
    elif distribution:
        raise ValueError('Distribution validation requires a signed app')
    if distribution:
        profile = subprocess.run(['security','cms','-D','-i',str(app/'embedded.mobileprovision')],check=True,capture_output=True)
        profile = plistlib.loads(profile.stdout)
        require('ProvisionedDevices' not in profile and not profile.get('ProvisionsAllDevices'), 'Not an App Store provisioning profile')
        require(profile.get('Entitlements',{}).get('get-task-allow') is False, 'Debugging is enabled in the distribution profile')
        result = subprocess.run(['codesign','-d','--entitlements',':-',str(app)],check=True,capture_output=True)
        entitlements = plistlib.loads(result.stdout)
        require(entitlements.get('get-task-allow') is not True, 'Debugging is enabled in the app signature')
    print('Local tvOS application packaging checks passed'+(' with distribution signing.' if distribution else '.'))
    print('This does not replace Apple validation, review, or physical performance tests.')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--app',type=Path)
    p.add_argument('--archive',type=Path)
    p.add_argument('--audit-public',action='store_true')
    p.add_argument('--require-distribution-signing',action='store_true')
    a = p.parse_args()
    try:
        validate_source()
        if a.audit_public: audit_public_index()
        if a.app and a.archive: p.error('Choose --app or --archive')
        app = a.app or (a.archive/'Products/Applications/OMTReceiver.app' if a.archive else None)
        if a.require_distribution_signing and app is None: p.error('An app or archive is required')
        if app: validate_app(app,a.require_distribution_signing)
    except (ValueError,OSError,KeyError,subprocess.CalledProcessError) as error:
        print('Validation failed: '+str(error),file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
