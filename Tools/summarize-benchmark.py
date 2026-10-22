#!/usr/bin/env python3
"""Summarize the receiver and sender evidence from benchmark-apple-tv.py."""
import argparse
import json
from pathlib import Path
import statistics
import math
from fractions import Fraction


def summarize(directory):
    manifest = json.loads((directory / 'manifest.json').read_text())
    first = json.loads((directory / 'receiver-baseline.json').read_text())
    series_path = directory / 'receiver-series.jsonl'
    if not series_path.exists():
        series_path = directory / 'polls.jsonl'
    records = [json.loads(line) for line in series_path.read_text().splitlines() if line.strip()]
    records = [r for r in records if r['runID'] == manifest['runID'] and r['uptime'] >= first['uptime']]
    if not records:
        raise ValueError('No receiver evidence after baseline')
    last = records[-1]
    if len({r['instanceID'] for r in records}) != 1:
        raise ValueError('Receiver process changed; evidence cannot be combined into one interval')
    duration = last['uptime'] - first['uptime']
    if duration <= 0:
        raise ValueError('No measured interval yet')
    admitted = last['videoFramesAdmitted'] - first['videoFramesAdmitted']
    rate = Fraction(manifest.get('expectedFrameRateNumerator', first.get('videoFrameRateNumerator', 30)),
                    manifest.get('expectedFrameRateDenominator', first.get('videoFrameRateDenominator', 1)))
    target_fps = float(rate)
    if not 0 < target_fps <= 60:
        raise ValueError('Unsupported benchmark target frame rate')
    source_frame_advance = round((last['lastVideoSourceTimestamp100ns'] - first['lastVideoSourceTimestamp100ns']) * target_fps / 10_000_000)
    audio = last['audioPacketsAdmitted'] - first['audioPacketsAdmitted']
    warmed = [r for r in records if r['uptime'] >= first['uptime'] + 120 and 'physicalFootprintMiB' in r]
    if not warmed:
        warmed = [r for r in records if 'physicalFootprintMiB' in r]
    post_warmup_count = len([r for r in records if r['uptime'] >= first['uptime'] + 120 and 'physicalFootprintMiB' in r])
    memory = [r['physicalFootprintMiB'] for r in warmed]
    memory_early = statistics.mean(memory[:12]) if memory else None
    memory_late = statistics.mean(memory[-12:]) if memory else None
    native = [(r['renderer'], r['uptime']) for r in records if r.get('renderer') and 'totalFrames' in r['renderer']]
    native_summary = {'available': False}
    native_counters = ('totalFrames', 'droppedFrames', 'corruptedFrames', 'optimizedCompositingFrames')
    native_monotonic = all(all(b[0][key] >= a[0][key] for key in native_counters)
                           for a, b in zip(native, native[1:]))
    if native and (not native_monotonic or last['attempts'] != 1):
        native_summary['reason'] = 'Renderer counters reset or multiple connection attempts; do not combine renderer lifetimes.'
    if len(native) >= 2 and native_monotonic and last['attempts'] == 1:
        a, b = native[0][0], native[-1][0]
        native_duration = b['sampledAtUptime'] - a['sampledAtUptime']
        total = b['totalFrames'] - a['totalFrames']
        dropped = b['droppedFrames'] - a['droppedFrames']
        native_summary = {'available': True, 'durationSeconds': native_duration,
                          'totalFrames': total, 'droppedFrames': dropped,
                          'corruptedFrames': b['corruptedFrames'] - a['corruptedFrames'],
                          'optimizedCompositingFrames': b['optimizedCompositingFrames'] - a['optimizedCompositingFrames'],
                          'dropPercent': dropped * 100 / total if total > 0 else None,
                          'estimatedDisplayedFPS': (total - dropped) / native_duration if native_duration > 0 else None,
                          'meanAccumulatedFrameDelayMs': (b['accumulatedFrameDelayMs'] - a['accumulatedFrameDelayMs']) / (total - dropped) if total > dropped else None}
    observation_path = directory / 'operator-observation.json'
    observation = json.loads(observation_path.read_text()) if observation_path.exists() else None
    sender = [json.loads(line) for line in (directory / 'sender.log').read_text().splitlines() if line.startswith('{')]
    cpu = [r['cpuPercentOfOneCore'] for r in records if 'cpuPercentOfOneCore' in r]
    windows = [r['windowVideoAdmissionFPS'] for r in records[1:] if 'windowVideoAdmissionFPS' in r]
    clock_rows = [r for r in records if r['uptime'] >= first['uptime'] + 120]
    lead_trend = {}
    if len(clock_rows) >= 3 and len({r['lastVideoAdmissionUptime'] for r in clock_rows}) > 1:
        x = [r['lastVideoAdmissionUptime'] for r in clock_rows]
        xm = statistics.mean(x)
        sxx = sum((t - xm) ** 2 for t in x)
        def fit(y):
            ym = statistics.mean(y)
            slope = sum((t - xm) * (v - ym) for t, v in zip(x, y)) / sxx
            error = math.sqrt(sum((v - ym - slope * (t - xm)) ** 2 for t, v in zip(x, y)) / (len(x) - 2) / sxx)
            return slope, error
        video_leads = [r['currentVideoLeadMs'] for r in clock_rows]
        audio_leads = [r['currentAudioLeadMs'] for r in clock_rows]
        for label, y in [('video', video_leads), ('audio', audio_leads)]:
            slope, error = fit(y)
            lead_trend[label] = {'millisecondsPerMinute': slope * 60,
                                 'earlyMeanMs': statistics.mean(y[:12]),
                                 'lateMeanMs': statistics.mean(y[-12:]),
                                 'changeInMeansMs': statistics.mean(y[-12:]) - statistics.mean(y[:12])}
        source_pts = [r['lastVideoSourceTimestamp100ns'] / 10_000_000 for r in clock_rows]
        slope, error = fit(source_pts)
        lead_trend['apparentSourceClockVsTVHostPPM'] = (slope - 1) * 1_000_000
        lead_trend['sampleCount'] = len(clock_rows)
        lead_trend['fitIntervalSeconds'] = x[-1] - x[0]
        lead_trend['interpretation'] = 'Apparent relative clock skew inferred from frame admission timing; includes sender, network and scheduling variation. Not physical panel latency.'
    delta = lambda name: last.get(name, 0) - first.get(name, 0)
    checks = {
        'collectionCompleted': manifest.get('collectionResult') == 'complete',
        'nativeRendererMetricsAvailable': native_summary['available'],
        'uniqueFixtureFramesNotDoubleCounted': source_frame_advance >= admitted,
        'sourceFrameLossBelow0_1Percent': source_frame_advance > 0 and max(0, source_frame_advance - admitted) / source_frame_advance < 0.001,
        'requestedDurationReached': duration >= manifest['requestedIntervalSeconds'],
        'oneConnectionAttempt': last['attempts'] == 1,
        'noReportedFailures': not last.get('failures') and last.get('failureCount', 0) == 0,
        'allSamplesPlaying': all(r['phase'] == 'playing' for r in records),
        'admissionAtLeastTargetMinus0_1FPS': admitted / duration >= target_fps - 0.1,
        'advertisedFrameRateMatchesTarget': all(
            Fraction(r.get('videoFrameRateNumerator', rate.numerator), r.get('videoFrameRateDenominator', rate.denominator)) == rate
            and ('expectedFrameRateNumerator' not in manifest or 'videoFrameRateNumerator' in r) for r in records),
        'noAudioAdmittedAfterItsPTS': delta('lateAudioPackets') == 0,
        'noAudioAdmittedInsideRouteHorizon': delta('audioPacketsBelowRouteHorizon') == 0,
        'noAudioTimestampDiscontinuities': delta('audioTimestampDiscontinuities') == 0,
        'noTimelineResets': delta('audioTimelineResets') == 0 and delta('videoTimelineResets') == 0,
        'noSeriousOrCriticalThermalState': max(r['thermalState'] for r in records) < 2,
        'postWarmupMemoryGrowthBelow20MiB': post_warmup_count >= 24 and memory_early is not None and memory_late - memory_early < 20,
    }
    if native_summary['available']:
        checks['nativeRendererCoverageAtLeast95Percent'] = native_summary['durationSeconds'] >= duration * 0.95
        checks['nativeRendererNoCorruptedFrames'] = native_summary['corruptedFrames'] == 0
        checks['nativeRendererDropRateBelow0_1Percent'] = native_summary['dropPercent'] is not None and native_summary['dropPercent'] < 0.1
    first_windows = [r['windowVideoAdmissionFPS'] for r in records
                     if 0 < r['uptime'] - first['uptime'] <= 60 and 'windowVideoAdmissionFPS' in r]
    last_windows = [r['windowVideoAdmissionFPS'] for r in records
                    if last['uptime'] - 60 <= r['uptime'] < last['uptime'] and 'windowVideoAdmissionFPS' in r]
    return {
        'runID': manifest['runID'], 'collectionResult': manifest.get('collectionResult', 'running'),
        'intervalSeconds': duration, 'receiverSamples': len(records),
        'videoFramesAdmitted': admitted, 'videoAdmissionFPS': admitted / duration,
        'expectedFrameRateNumerator': rate.numerator, 'expectedFrameRateDenominator': rate.denominator,
        'targetFPS': target_fps, 'sourceFrameAdvance': source_frame_advance,
        **({'sourceFrameAdvanceAt30FPS': source_frame_advance} if rate == 30 else {}),
        'sourceFrameAdvanceMinusAdmissions': source_frame_advance - admitted,
        'worstFiveSecondAdmissionFPS': min(windows) if windows else None,
        'firstMinuteWindowFPSMean': statistics.mean(first_windows) if first_windows else None,
        'lastMinuteWindowFPSMean': statistics.mean(last_windows) if last_windows else None,
        'audioPacketsAdmitted': audio, 'audioPacketsPerSecond': audio / duration,
        'audioLatePackets': delta('lateAudioPackets'),
        'audioInsideRouteHorizon': delta('audioPacketsBelowRouteHorizon'),
        'audioTimestampDiscontinuities': delta('audioTimestampDiscontinuities'),
        'audioTimelineResets': delta('audioTimelineResets'), 'videoTimelineResets': delta('videoTimelineResets'),
        'ingressCoalescedVideo': delta('ingressCoalescedVideo'),
        'playbackCoalescedVideo': delta('playbackCoalescedVideo'),
        'poolStalls': delta('poolStalls'), 'attempts': last['attempts'], 'failures': last['failures'],
        'decodeMsIncludingWarmup': last['decodeMs'],
        'audioAdmissionGapMsIncludingWarmup': last['audioAdmissionGapMs'],
        'minimumAudioLeadMsIncludingWarmup': last.get('minimumAudioLeadMs'),
        'maximumAudioLeadMsIncludingWarmup': last.get('maximumAudioLeadMs'),
        'minimumSampledVideoLeadMs': min(r['currentVideoLeadMs'] for r in records),
        'maximumSampledVideoLeadMs': max(r['currentVideoLeadMs'] for r in records),
        'payloadAfterTransportMailboxMbps': (last['payloadBytesAfterTransportMailbox'] - first['payloadBytesAfterTransportMailbox']) * 8 / duration / 1_000_000,
        'scheduledPlaybackLeadTrend': lead_trend,
        'latencyStabilityFlagged': bool(lead_trend) and any(lead_trend[lane]['changeInMeansMs'] > 1000 / target_fps for lane in ['video','audio']),
        'route': last['route'], 'nativeRenderer': native_summary,
        'cpuPercentOfOneCoreMean': statistics.mean(cpu) if cpu else None,
        'cpuPercentOfOneCoreMaximum': max(cpu) if cpu else None,
        'memoryAfterWarmupMiB': {'minimum': min(memory) if memory else None,
                                'maximum': max(memory) if memory else None,
                                'earlyMean': memory_early, 'lateMean': memory_late,
                                'changeInMeans': memory_late - memory_early if memory else None,
                                'postWarmupSampleCount': post_warmup_count},
        'maximumThermalState': max(r['thermalState'] for r in records),
        'senderLastReport': sender[-1] if sender else None,
        'runtimeTargets': checks,
        'allRuntimeTargetsMet': all(checks.values()),
        'physicalPanelLatencyMeasured': False,
        'operatorObservation': observation,
        'audibleContinuityVerifiedForThisRun': bool(observation and observation.get('physicalAudioCheckPerformed')
                                                    and observation.get('audibleContinuityPassed')),
        'limits': 'Instrumented single opaque SDK-generated test pattern. Native renderer data does not measure physical HDMI/panel delivery. No phone/capture latency measurement. Audio listening evidence, when available, is recorded separately in operatorObservation. Decode/audio gap extrema include warmup. Process CPU is expressed as a percentage of one CPU core.'
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = summarize(args.directory)
    text = json.dumps(result, indent=2) + '\n'
    if args.output:
        args.output.write_text(text)
    else:
        print(text, end='')


if __name__ == '__main__':
    main()
