#!/usr/bin/env python3
"""Select an installed 1080p tvOS simulator without modifying runtimes/devices."""
import argparse
import json
import os
import subprocess
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--github-env', action='store_true')
a = p.parse_args()
devices = json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','--json']))['devices']
choices = [(runtime, device) for runtime, group in devices.items() if '.tvOS-' in runtime
           for device in group if device.get('isAvailable') and 'Apple TV 4K' in device['name']]
if not choices:
    raise SystemExit('Install a tvOS simulator runtime in Xcode before running tests.')
choices.sort(key=lambda item: (item[0], '1080p' in item[1]['name']), reverse=True)
device = choices[0][1]
value = 'platform=tvOS Simulator,id='+device['udid']
if a.github_env:
    with open(os.environ['GITHUB_ENV'],'a') as stream:
        stream.write('OMT_TEST_DESTINATION='+value+'\n')
print(value)
