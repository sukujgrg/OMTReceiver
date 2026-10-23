#!/usr/bin/env python3
"""Run an installed OMTReceiver benchmark build and retain physical-device reports.

Uses only Python's standard library, Xcode devicectl and the optional Mac SDK
fixture. Does not build/install the application or measure physical panel latency.
"""
import argparse
from datetime import datetime, timezone
from fractions import Fraction
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
from urllib.parse import urlsplit
import uuid


def command(arguments, log, timeout=30):
    result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=timeout)
    log.write_text(result.stdout)
    if result.returncode:
        raise RuntimeError(f'Command failed ({result.returncode}); see {log}')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True, help='Paired Apple TV identifier or name')
    parser.add_argument('--source', required=True, help='Sender LAN address, e.g. omt://192.168.1.3:6488')
    parser.add_argument('--fps', default='30', help='Expected source rate, 1–60 as N or N/D; default 30')
    parser.add_argument('--seconds', type=int, default=1800, help='Measured receiver interval (30–14400; default 1800)')
    parser.add_argument('--scan-mode', choices=('progressive', 'interlaced'), default='progressive')
    parser.add_argument('--video-pause-after', type=float, default=0, help='Local fixture: inject a video-only pause at this source time')
    parser.add_argument('--video-pause-duration', type=float, default=0, help='Local fixture: pause length, at most five seconds')
    parser.add_argument('--restart-sender-after', type=int, default=0, help='Local fixture: restart once after this many measured seconds; a recovery test, not an uninterrupted screening run')
    parser.add_argument('--output', type=Path, required=True, help='New evidence directory; must not already exist')
    parser.add_argument('--bundle-id', default='com.suku.OMTReceiver')
    parser.add_argument('--external-sender', action='store_true', help='Use an already-running source on another Mac; do not start a local sender')
    parser.add_argument('--expect-audio', action=argparse.BooleanOptionalAction, default=True,
                        help='Require audio reception; use --no-expect-audio only for an intentionally video-only source')
    args = parser.parse_args()
    try:
        rate = Fraction(args.fps)
        if not 1 <= rate <= 60 or rate.numerator > 1_000_000 or rate.denominator > 100_000:
            raise ValueError()
    except (ValueError, ZeroDivisionError):
        parser.error('--fps must be 1–60 as N or N/D (for example 60 or 60000/1001)')
    address = urlsplit(args.source)
    if address.scheme != 'omt' or not address.hostname or not address.port or address.path not in ('', '/'):
        parser.error('--source must be omt://MAC-LAN-HOST:PORT')
    if not 30 <= args.seconds <= 14400:
        parser.error('--seconds must be between 30 and 14400')
    if (not 0 <= args.video_pause_after <= 3600 or not 0 <= args.video_pause_duration <= 5
            or bool(args.video_pause_after) != bool(args.video_pause_duration)
            or (args.video_pause_after and args.video_pause_after + args.video_pause_duration >= args.seconds)):
        parser.error('Video pause needs both positive values, at most five seconds, finishing before --seconds')
    if args.external_sender and args.video_pause_after:
        parser.error('Video pause injection requires a local fixture')
    if args.restart_sender_after and (args.external_sender or not 30 <= args.restart_sender_after < args.seconds - 30):
        parser.error('Sender restart requires a local fixture and at least 30 seconds on each side')
    if not args.external_sender and not os.environ.get('OMT_SDK_PATH'):
        parser.error('Set OMT_SDK_PATH to the official SDK root or MacOS library directory')
    args.output.mkdir(parents=True, exist_ok=False)
    run = str(uuid.uuid4()).upper()
    root = Path(__file__).resolve().parent.parent
    manifest = {'runID': run, 'requestedIntervalSeconds': args.seconds,
                'startedAt': datetime.now(timezone.utc).isoformat(),
                'physicalPanelLatencyMeasured': False,
                'sourceMode': 'external' if args.external_sender else 'local',
                'sourceURL': args.source, 'expectedFrameRateNumerator': rate.numerator,
                'expectedFrameRateDenominator': rate.denominator,
                'expectedScanMode': args.scan_mode,
                'expectAudio': args.expect_audio,
                'videoPauseAfterSeconds': args.video_pause_after,
                'videoPauseDurationSeconds': args.video_pause_duration,
                'plannedSenderRestartAfterSeconds': args.restart_sender_after,
                'scope': f'One 1920x1080 {args.scan_mode} {rate} opaque Medium-quality stream; stereo 48 kHz FPA1'}
    if args.external_sender:
        manifest['scope'] = f'External source at expected {rate} input frames/sec, {args.scan_mode}; actual format retained in receiver reports'
    (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Run {run}; evidence {args.output}', flush=True)
    source_log = (args.output / 'sender.log').open('w')
    sender = None

    def start_sender():
        fixture_options = ['--interlaced'] if args.scan_mode == 'interlaced' else []
        if args.video_pause_after:
            fixture_options += ['--video-pause-after', str(args.video_pause_after),
                                '--video-pause-duration', str(args.video_pause_duration)]
        return subprocess.Popen(['/usr/bin/caffeinate', '-i', str(root / 'Tools/run-official-sender.sh'),
                                   '--seconds', str(args.seconds + 120), '--port', str(address.port), '--fps', str(rate), '--benchmark', *fixture_options],
                                  stdout=source_log, stderr=subprocess.STDOUT, start_new_session=True)

    def stop_sender():
        if sender is not None and sender.poll() is None:
            try:
                os.killpg(sender.pid, signal.SIGINT)
            except ProcessLookupError:
                return
            try:
                sender.wait(timeout=20)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(sender.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                sender.wait(timeout=5)

    if not args.external_sender:
        sender = start_sender()
    else:
        source_log.write(f'External source: {args.source}; sender-side statistics remain on that Mac.\n')
        source_log.flush()
    activity = subprocess.Popen(['/usr/bin/caffeinate', '-i', '-w', str(os.getpid())],
                                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    launched = False
    last = None
    last_advance = time.monotonic()
    copy_errors = []

    def copy_series():
        command(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', args.device,
                 '--source', f'Library/Caches/OMTBenchmark/{run}.jsonl',
                 '--domain-type', 'appDataContainer', '--domain-identifier', args.bundle_id,
                 '--destination', str(args.output / 'receiver-series.jsonl'), '--timeout', '30'],
                args.output / 'copy-series.log', timeout=35)

    try:
        if sender is not None:
            startup_deadline = time.monotonic() + 30
            while 'Source: ' not in (args.output / 'sender.log').read_text():
                if sender.poll() is not None or time.monotonic() >= startup_deadline:
                    raise RuntimeError('Sender did not start; see sender.log')
                time.sleep(0.5)
        command(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', args.device,
                 '--terminate-existing', '--json-output', str(args.output / 'launch.json'),
                 args.bundle_id, '--', '--omt-benchmark-run', run,
                 '--omt-benchmark-source', args.source], args.output / 'launch.log')
        launched = True
        first = None
        wall_deadline = time.monotonic() + args.seconds + 100
        records = (args.output / 'polls.jsonl').open('w')
        try:
            while time.monotonic() < wall_deadline:
                if sender is not None and sender.poll() is not None:
                    raise RuntimeError('Mac sender stopped before the measured interval finished')
                try:
                    command(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', args.device,
                             '--source', f'Library/Caches/OMTBenchmark/{run}.json',
                             '--domain-type', 'appDataContainer', '--domain-identifier', args.bundle_id,
                             '--destination', str(args.output / 'receiver-latest.json'), '--timeout', '20'],
                            args.output / 'copy-latest.log', timeout=25)
                    report = json.loads((args.output / 'receiver-latest.json').read_text())
                    if report['phase'] == 'playing':
                        n, d = report.get('videoFrameRateNumerator'), report.get('videoFrameRateDenominator')
                        if not n or not d or Fraction(n, d) != rate:
                            raise RuntimeError(f'Source rate {n}/{d} does not match requested {rate}; check sender and receiver build')
                    if report.get('runID') != run:
                        raise RuntimeError('Report belongs to another run')
                    if last is not None and report['instanceID'] != last['instanceID']:
                        raise RuntimeError('Receiver process changed during the run')
                    if last is None or report['exportSequence'] > last['exportSequence']:
                        last_advance = time.monotonic()
                    elif time.monotonic() - last_advance > 20:
                        raise RuntimeError('Device report stopped advancing')
                    records.write(json.dumps(report, separators=(',', ':')) + '\n'); records.flush()
                    last = report
                    if first is None and report['phase'] == 'playing' and report['videoFramesAdmitted'] >= 60:
                        first = report
                        (args.output / 'receiver-baseline.json').write_text(json.dumps(first, indent=2) + '\n')
                    elapsed = report['uptime'] - first['uptime'] if first else 0
                    if first and args.restart_sender_after and elapsed >= args.restart_sender_after and 'senderRestart' not in manifest:
                        manifest['senderRestart'] = {'measuredElapsedSeconds': elapsed,
                                                     'receiverInstanceID': report['instanceID'],
                                                     'attemptsBefore': report['attempts']}
                        stop_sender()
                        sender = start_sender()
                        print('Injected isolated sender restart; retaining the same receiver process', flush=True)
                    decode = report.get('decodeMs', {})
                    print(f"[{elapsed:7.1f}s] {report['phase']} "
                          f"video={report['videoFramesAdmitted']} fps={report.get('windowVideoAdmissionFPS', 0):.2f} "
                          f"decodeP95<={decode.get('p95UpperBound')}ms "
                          f"memory={report.get('physicalFootprintMiB', 0):.1f}MiB "
                          f"thermal={report['thermalState']} attempts={report['attempts']} "
                          f"audioLate={report['lateAudioPackets']}", flush=True)
                    if first and elapsed >= args.seconds:
                        manifest['completedIntervalSeconds'] = elapsed
                        break
                    if first is None and report['elapsedSeconds'] > 65:
                        raise RuntimeError('Receiver did not reach fresh playing data within 65 seconds')
                except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
                    copy_errors.append(str(error))
                    print(f'Collection issue: {error}', flush=True)
                    if len(copy_errors) >= 5:
                        raise RuntimeError('Five collection failures; retaining available evidence') from error
                time.sleep(min(30, max(1, args.seconds - elapsed)) if first else 5)
            else:
                raise RuntimeError('Receiver did not complete the requested interval before the safety deadline')
        finally:
            records.close()
        copy_series()
        manifest['collectionResult'] = 'complete'
    except (RuntimeError, OSError, subprocess.TimeoutExpired, KeyboardInterrupt) as error:
        manifest['collectionResult'] = 'incomplete'
        manifest['error'] = str(error)
        print(f'Benchmark incomplete: {error}', flush=True)
    finally:
        if launched and manifest.get('collectionResult') != 'complete':
            # Preserve the five-second history before restoring the ordinary app,
            # even when a source, process or collection command failed mid-run.
            try:
                copy_series()
            except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
                copy_errors.append(f'Final evidence copy: {error}')
        manifest['finishedAt'] = datetime.now(timezone.utc).isoformat()
        manifest['collectionErrors'] = copy_errors
        (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        # Retire only our own isolated sender process group. Device reports are
        # collected first, so planned shutdown is not counted as a stream failure.
        stop_sender()
        source_log.close()
        if launched:
            try:
                command(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', args.device,
                         '--terminate-existing', args.bundle_id], args.output / 'restore-normal.log')
            except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
                print(f'Could not restore an ordinary app launch: {error}', flush=True)
        activity.terminate()
        activity.wait(timeout=5)
    return 0 if manifest.get('collectionResult') == 'complete' else 1


if __name__ == '__main__':
    sys.exit(main())
