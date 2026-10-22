#!/usr/bin/env python3
"""Create a local tvOS archive or export an IPA; never uploads or submits."""
import argparse
from datetime import datetime
from pathlib import Path
import re
import plistlib
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
p = argparse.ArgumentParser(description=__doc__)
commands = p.add_subparsers(dest='command', required=True)
a = commands.add_parser('archive')
a.add_argument('--unsigned', action='store_true', help='Local packaging/CI only; cannot be submitted')
a.add_argument('--output', type=Path)
a.add_argument('--build-number', help='Override BUILD_NUMBER for this archive')
a.add_argument('--team-id', help='Otherwise use Config/Signing.local.xcconfig')
e = commands.add_parser('export')
e.add_argument('archive', type=Path)
e.add_argument('--output', type=Path, required=True)
args = p.parse_args()
if args.command == 'archive':
    version = (ROOT/'VERSION').read_text().strip()
    build = args.build_number or (ROOT/'BUILD_NUMBER').read_text().strip()
    if not re.fullmatch(r'[1-9][0-9]*', build): p.error('Build number must be a positive integer')
    if args.team_id and not re.fullmatch(r'[A-Z0-9]{10}', args.team_id): p.error('Invalid team ID')
    mode = 'unsigned' if args.unsigned else 'signed'
    output = args.output or ROOT/'build/AppStore'/f'{version}-{build}-{mode}-{datetime.now():%Y%m%d-%H%M%S}'/'OMTReceiver.xcarchive'
    output = output.resolve()
    if output.exists(): p.error('Archive exists; choose a new output to preserve it')
    output.parent.mkdir(parents=True, exist_ok=True)
    cmd = ['xcodebuild', '-project', 'OMTReceiver.xcodeproj', '-scheme', 'OMTReceiver',
           '-configuration', 'Release', '-destination', 'generic/platform=tvOS',
           '-derivedDataPath', 'build/DerivedData', '-archivePath', str(output),
           'CURRENT_PROJECT_VERSION='+build]
    if args.unsigned: cmd += ['CODE_SIGNING_ALLOWED=NO']
    else: cmd += ['-allowProvisioningUpdates']
    if args.team_id: cmd += ['DEVELOPMENT_TEAM='+args.team_id]
    cmd += ['archive']
    log = output.parent/'archive.log'
else:
    options = plistlib.loads((ROOT/'AppStore/ExportOptions.plist').read_bytes())
    if options.get('destination') != 'export' or options.get('method') != 'app-store-connect':
        p.error('Only a local App Store export is permitted; upload settings are rejected')
    output = args.output.resolve()
    if output.exists(): p.error('Export directory exists; choose a new output to preserve it')
    output.mkdir(parents=True)
    cmd = ['xcodebuild', '-exportArchive', '-archivePath', str(args.archive.resolve()),
           '-exportOptionsPlist', str(ROOT/'AppStore/ExportOptions.plist'),
           '-exportPath', str(output), '-allowProvisioningUpdates']
    log = output/'export.log'
print('Local '+args.command+'; log: '+str(log), flush=True)
with log.open('w') as stream:
    result = subprocess.run(cmd, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
if result.returncode:
    print(log.read_text()[-12000:], file=sys.stderr)
    sys.exit(result.returncode)
print(output)
