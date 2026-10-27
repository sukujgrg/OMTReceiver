import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("benchmark_summary", Path(__file__).parents[1] / "summarize-benchmark.py")
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)


class FrameRateCollectorArgumentTests(unittest.TestCase):
    def check_rate(self, rate, expected_error):
        # Invalid source deliberately stops preflight before output directories,
        # connected-device access or launching the official SDK fixture.
        result = subprocess.run([
            sys.executable, str(Path(__file__).parents[1] / 'benchmark-apple-tv.py'),
            '--device', 'unused', '--source', 'invalid', '--output', '/unused', f'--fps={rate}'
        ], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn(expected_error, result.stderr)

    def test_signed_int32_rate_terms_reach_source_validation(self):
        for rate in ['3000003/100000', '3000004/100001', '2147483647/100000001',
                     '2147483647/2147483646', '60', '1']:
            with self.subTest(rate=rate):
                self.check_rate(rate, '--source must be')

    def test_invalid_terms_and_actual_rates_stop_before_source_validation(self):
        for rate in ['2147483648/100000001', '2147483647/2147483648',
                     '0', '-30/1', '30/0', '1/2', '60001/1000']:
            with self.subTest(rate=rate):
                self.check_rate(rate, '--fps must be')


class FrameRateSummaryTests(unittest.TestCase):
    def test_audio_warning_events_are_deduplicated_across_exports(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            self.fixture(path)
            rows = [json.loads(line) for line in (path / 'receiver-series.jsonl').read_text().splitlines()]
            event = {'sequence': 1, 'sourceTimestamp100ns': 42, 'leadMs': 94,
                     'reasons': ['routeHorizon', 'receiveGap']}
            for row in rows:
                row['audioPipelineTiming'] = {'eventCount': 1, 'recentEvents': [event],
                                              'firstRouteWarnings': [event]}
                row['audioPacketsBelowRouteHorizon'] = 1
            (path / 'receiver-series.jsonl').write_text(''.join(json.dumps(row)+'\n' for row in rows))
            result = summary.summarize(path)['audioRouteHorizonEventsIncludingWarmup']
            self.assertEqual(result['observedWarningEventCount'], 1)
            self.assertEqual(result['retainedWarningEvents'], [event])
            self.assertTrue(result['exactWarningCoverageComplete'])

    def test_missing_warning_event_does_not_hide_the_authoritative_counter(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            self.fixture(path)
            rows = [json.loads(line) for line in (path / 'receiver-series.jsonl').read_text().splitlines()]
            rows[-1]['audioPacketsBelowRouteHorizon'] = 2
            rows[-1]['audioPipelineTiming'] = {'eventCount': 100, 'recentEvents': [
                {'sequence': 99, 'sourceTimestamp100ns': 42, 'reasons': ['routeHorizon']}]}
            (path / 'receiver-series.jsonl').write_text(''.join(json.dumps(row)+'\n' for row in rows))
            result = summary.summarize(path)
            self.assertEqual(result['audioInsideRouteHorizon'], 2)
            self.assertFalse(result['runtimeTargets']['noAudioAdmittedInsideRouteHorizon'])
            self.assertFalse(result['audioRouteHorizonEventsIncludingWarmup']['exactWarningCoverageComplete'])

    def fixture(self, directory, frames=3600, numerator=60, denominator=1, seconds=60, advertised=None, legacy=False):
        manifest = {"runID": "test", "requestedIntervalSeconds": seconds, "collectionResult": "complete"}
        if not legacy:
            manifest.update(expectedFrameRateNumerator=numerator, expectedFrameRateDenominator=denominator)
        first = {"runID": "test", "instanceID": "one", "uptime": 100, "videoFramesAdmitted": 0,
                 "lastVideoSourceTimestamp100ns": 0, "lastVideoAdmissionUptime": 100,
                 "audioPacketsAdmitted": 0, "attempts": 1, "phase": "playing", "thermalState": 0,
                 "decodeMs": {}, "audioAdmissionGapMs": {}, "failures": [], "route": {},
                 "currentVideoLeadMs": 210, "currentAudioLeadMs": 230, "payloadBytesAfterTransportMailbox": 0}
        if not legacy:
            first.update(videoFrameRateNumerator=advertised or numerator, videoFrameRateDenominator=denominator)
        last = dict(first, uptime=100+seconds, videoFramesAdmitted=frames,
                    lastVideoSourceTimestamp100ns=round(seconds*10_000_000), lastVideoAdmissionUptime=100+seconds,
                    audioPacketsAdmitted=round(seconds*50), windowVideoAdmissionFPS=frames/seconds)
        (directory / "manifest.json").write_text(json.dumps(manifest))
        (directory / "receiver-baseline.json").write_text(json.dumps(first))
        (directory / "receiver-series.jsonl").write_text(json.dumps(first)+"\n"+json.dumps(last)+"\n")
        (directory / "sender.log").write_text("")

    def test_sixty_fps_counts_source_frames_at_sixty(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder);self.fixture(path)
            result=summary.summarize(path)
            self.assertEqual(result["sourceFrameAdvance"], 3600)
            self.assertEqual(result["sourceFrameAdvanceMinusAdmissions"], 0)
            self.assertTrue(result["runtimeTargets"]["admissionAtLeastTargetMinus0_1FPS"])
            self.assertNotIn("sourceFrameAdvanceAt30FPS",result)

    def test_thirty_fps_delivery_cannot_pass_sixty_fps_target(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder);self.fixture(path,frames=1800)
            result=summary.summarize(path)
            self.assertFalse(result["runtimeTargets"]["admissionAtLeastTargetMinus0_1FPS"])
            self.assertEqual(result["sourceFrameAdvanceMinusAdmissions"],1800)

    def test_fractional_sixty_preserves_exact_source_sequence(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder);self.fixture(path,numerator=60000,denominator=1001,seconds=60.06)
            result=summary.summarize(path)
            self.assertEqual(result["sourceFrameAdvance"],3600)
            self.assertAlmostEqual(result["videoAdmissionFPS"],60000/1001)
            self.assertTrue(result["runtimeTargets"]["advertisedFrameRateMatchesTarget"])

    def test_wrong_advertised_rate_fails_even_when_counters_claim_sixty(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder);self.fixture(path,advertised=30)
            result=summary.summarize(path)
            self.assertFalse(result["runtimeTargets"]["advertisedFrameRateMatchesTarget"])

    def test_legacy_thirty_reports_keep_their_original_rate(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder);self.fixture(path,frames=1800,numerator=30,legacy=True)
            result=summary.summarize(path)
            self.assertEqual(result["sourceFrameAdvanceAt30FPS"],1800)
            self.assertEqual(result["videoAdmissionFPS"],30)

    def test_interlaced_thirty_requires_sixty_output_samples(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            self.fixture(path, frames=1800, numerator=30)
            manifest = json.loads((path / "manifest.json").read_text())
            manifest['expectedScanMode'] = 'interlaced'
            (path / "manifest.json").write_text(json.dumps(manifest))
            rows = [json.loads(line) for line in (path / "receiver-series.jsonl").read_text().splitlines()]
            for index, row in enumerate(rows):
                row.update(videoSourceScanMode='interlaced', videoSamplesAdmitted=index * 1800)
            (path / "receiver-series.jsonl").write_text(''.join(json.dumps(row)+'\n' for row in rows))
            result = summary.summarize(path)
            self.assertTrue(result['runtimeTargets']['advertisedScanModeMatchesTarget'])
            self.assertFalse(result['runtimeTargets']['outputSamplesAtLeastTargetMinus0_1FPS'])
            rows[-1]['videoSamplesAdmitted'] = 3600
            (path / "receiver-series.jsonl").write_text(''.join(json.dumps(row)+'\n' for row in rows))
            self.assertTrue(summary.summarize(path)['runtimeTargets']['outputSamplesAtLeastTargetMinus0_1FPS'])

    def test_progressive_source_cannot_pass_an_interlaced_check(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            self.fixture(path)
            manifest = json.loads((path / "manifest.json").read_text())
            manifest['expectedScanMode'] = 'interlaced'
            (path / "manifest.json").write_text(json.dumps(manifest))
            self.assertFalse(summary.summarize(path)['runtimeTargets']['advertisedScanModeMatchesTarget'])

    def test_fresh_report_does_not_hide_stalled_video(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            self.fixture(path)
            rows = [json.loads(line) for line in (path / 'receiver-series.jsonl').read_text().splitlines()]
            rows[-1]['lastVideoAdmissionUptime'] -= 5
            (path / 'receiver-series.jsonl').write_text(''.join(json.dumps(row)+'\n' for row in rows))
            self.assertFalse(summary.summarize(path)['runtimeTargets']['noSampledVideoStallOverTwoSeconds'])

    def test_missing_audio_cannot_pass_an_audio_video_run(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            self.fixture(path)
            rows = [json.loads(line) for line in (path / 'receiver-series.jsonl').read_text().splitlines()]
            for row in rows:
                row['audioPacketsAdmitted'] = 0
                row.pop('currentAudioLeadMs', None)
            (path / 'receiver-series.jsonl').write_text(''.join(json.dumps(row)+'\n' for row in rows))
            self.assertFalse(summary.summarize(path)['runtimeTargets']['expectedAudioIsAdvancing'])
            manifest = json.loads((path / 'manifest.json').read_text())
            manifest['expectAudio'] = False
            (path / 'manifest.json').write_text(json.dumps(manifest))
            self.assertNotIn('expectedAudioIsAdvancing', summary.summarize(path)['runtimeTargets'])

    def test_external_publisher_timestamps_do_not_claim_unique_fixture_frames(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            self.fixture(path)
            manifest = json.loads((path / 'manifest.json').read_text())
            manifest['sourceMode'] = 'external'
            (path / 'manifest.json').write_text(json.dumps(manifest))
            result = summary.summarize(path)
            self.assertNotIn('uniqueFixtureFramesNotDoubleCounted', result['runtimeTargets'])
            self.assertNotIn('sourceFrameLossBelow0_1Percent', result['runtimeTargets'])
            self.assertIn('nativeRendererMetricsAvailable', result['runtimeTargets'])
            self.assertIn('admissionAtLeastTargetMinus0_1FPS', result['runtimeTargets'])


if __name__ == "__main__":
    unittest.main()
