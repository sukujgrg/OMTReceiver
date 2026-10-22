import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("benchmark_summary", Path(__file__).parents[1] / "summarize-benchmark.py")
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)


class FrameRateSummaryTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
