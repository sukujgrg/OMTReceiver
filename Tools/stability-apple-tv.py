#!/usr/bin/env python3
"""Run a bounded, unattended Apple TV stability suite against isolated SDK sources.

Requires the current signed app already installed. Saves every case separately,
continues after a failed case, and never converts recovery tests into sustained
performance passes. Uses only the standard library and existing benchmark tools.
"""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def recovery_result(directory, kind):
    manifest = json.loads((directory / 'manifest.json').read_text())
    baseline = json.loads((directory / 'receiver-baseline.json').read_text())
    records = [json.loads(line) for line in (directory / 'polls.jsonl').read_text().splitlines() if line.strip()]
    last = records[-1]
    # Require several fresh reports at normal cadence after the disturbance.
    tail = [r for r in records if r['uptime'] >= last['uptime'] - 45]
    checks = {
        'collectionCompleted': manifest.get('collectionResult') == 'complete',
        'sameReceiverProcess': all(r['instanceID'] == baseline['instanceID'] for r in records),
        'returnedToPlaying': len(tail) >= 2 and all(r['phase'] == 'playing' for r in tail),
        'observedStableRecoveryWindow': len(tail) >= 2 and tail[-1]['uptime'] - tail[0]['uptime'] >= 25,
        'freshVideoAfterRecovery': len(tail) >= 2 and tail[-1]['videoFramesAdmitted'] > tail[0]['videoFramesAdmitted'],
        'recoveredCadence': len(tail) >= 2 and all(r.get('windowVideoAdmissionFPS', 0) >= 59.9 for r in tail),
        'recoveredAudio': len(tail) >= 2 and tail[-1]['audioPacketsAdmitted'] > tail[0]['audioPacketsAdmitted'] and all(r.get('windowAudioPacketsPerSecond', 0) >= 49 for r in tail),
        'noSeriousOrCriticalThermalState': max(r['thermalState'] for r in records) < 2,
    }
    if kind == 'sender-restart':
        restart = manifest.get('senderRestart')
        checks['restartWasInjected'] = restart is not None
        checks['receiverReconnected'] = bool(restart and last['attempts'] > restart['attemptsBefore'])
    else:
        checks['pauseWasInjected'] = '"fixture-video-pause"' in (directory / 'sender.log').read_text()
        checks['noReconnectNeeded'] = last['attempts'] == 1
        checks['noTimelineResetNeeded'] = last['videoTimelineResets'] == baseline['videoTimelineResets'] and last['audioTimelineResets'] == baseline['audioTimelineResets']
        checks['noLateAudio'] = last['lateAudioPackets'] == baseline['lateAudioPackets']
    return {'kind': kind, 'checks': checks, 'passed': all(checks.values()),
            'scope': 'Automatic recovery in the same app process; excludes uninterrupted performance qualification and listening/panel observations.'}


def cases(smoke=False):
    sustained = 30 if smoke else 1800
    return [
        ('progressive60', 30 if smoke else 5400, ['--fps', '60']),
        ('interlaced30', sustained, ['--fps', '30', '--scan-mode', 'interlaced']),
        ('interlaced60', sustained, ['--fps', '60', '--scan-mode', 'interlaced']),
        ('progressive5994', sustained, ['--fps', '60000/1001']),
        ('video-delay', 120 if smoke else 180, ['--fps', '60', '--video-pause-after', '45', '--video-pause-duration', '0.6']),
        ('sender-restart', 120 if smoke else 180, ['--fps', '60', '--restart-sender-after', '45']),
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--source', required=True, help='Reachable address of this Mac and an unused fixture port')
    parser.add_argument('--output', type=Path, required=True, help='New evidence directory')
    parser.add_argument('--budget-seconds', type=int, default=12600, help='Hard overall budget including setup and cleanup; default 3.5 hours')
    parser.add_argument('--smoke', action='store_true', help='Short tool check; never qualifies sustained performance')
    args = parser.parse_args()
    if not 600 <= args.budget_seconds <= 14400:
        parser.error('--budget-seconds must be 600–14400')
    if not os.environ.get('OMT_SDK_PATH'):
        parser.error('Set OMT_SDK_PATH to the official local SDK')
    args.output.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parent
    spec = importlib.util.spec_from_file_location('omt_summary', root / 'summarize-benchmark.py')
    summarizer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(summarizer)
    deadline = time.monotonic() + args.budget_seconds
    status = {'startedAt': datetime.now(timezone.utc).isoformat(), 'state': 'running',
              'smokeOnly': args.smoke, 'budgetSeconds': args.budget_seconds, 'cases': []}
    status_path = args.output / 'status.json'

    def save():
        temporary = status_path.with_suffix('.tmp')
        temporary.write_text(json.dumps(status, indent=2) + '\n')
        temporary.replace(status_path)

    save()
    activity = subprocess.Popen(['/usr/bin/caffeinate', '-i', '-w', str(os.getpid())],
                                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    child = None
    try:
        for name, duration, options in cases(args.smoke):
            remaining = deadline - time.monotonic()
            if remaining < duration + 180:
                status['cases'].append({'name': name, 'state': 'skipped', 'reason': 'Insufficient time in the access window'})
                save()
                continue
            entry = {'name': name, 'state': 'running', 'requestedSeconds': duration,
                     'startedAt': datetime.now(timezone.utc).isoformat()}
            status['cases'].append(entry)
            save()
            print(f'Starting {name}, {duration} measured seconds', flush=True)
            folder = args.output / name
            with (args.output / f'{name}.log').open('w') as log:
                child = subprocess.Popen([sys.executable, str(root / 'benchmark-apple-tv.py'),
                                          '--device', args.device, '--source', args.source,
                                          '--seconds', str(duration), '--output', str(folder), *options],
                                         stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    entry['exitCode'] = child.wait(timeout=min(duration + 300, remaining - 120))
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGINT)
                    try:
                        child.wait(timeout=110)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGKILL)
                        child.wait(timeout=5)
                    entry['error'] = 'Case exceeded its safety deadline'
                finally:
                    child = None
            try:
                result = (recovery_result(folder, name) if name in ('video-delay', 'sender-restart')
                          else summarizer.summarize(folder))
                (folder / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
                entry['passed'] = result.get('passed', result.get('allRuntimeTargetsMet', False))
            except (OSError, ValueError, KeyError, IndexError, TypeError, ArithmeticError) as error:
                entry['error'] = f'Could not summarize available evidence: {error}'
                entry['passed'] = False
            entry['state'] = 'complete' if entry.get('exitCode') == 0 else 'incomplete'
            entry['finishedAt'] = datetime.now(timezone.utc).isoformat()
            save()
            print(f"Finished {name}: state={entry['state']}, checksPassed={entry['passed']}", flush=True)
        status['state'] = 'complete'
    except KeyboardInterrupt:
        status['state'] = 'interrupted'
    except (OSError, RuntimeError) as error:
        status['state'] = 'failed'
        status['error'] = str(error)
    finally:
        if child is not None and child.poll() is None:
            os.killpg(child.pid, signal.SIGINT)
            try:
                child.wait(timeout=110)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
        status['finishedAt'] = datetime.now(timezone.utc).isoformat()
        status['allCasesPassed'] = status['state'] == 'complete' and all(case.get('passed', False) for case in status['cases'])
        save()
        activity.terminate()
        activity.wait(timeout=5)
    return 0 if status['allCasesPassed'] else 1


if __name__ == '__main__':
    sys.exit(main())
