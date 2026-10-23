import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location('stability', Path(__file__).parents[1] / 'stability-apple-tv.py')
stability = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stability)


class RecoveryEvidenceTests(unittest.TestCase):
    def fixture(self, folder, *, process_changed=False, frozen=False, attempts=2, audio_frozen=False):
        base = dict(instanceID='one', uptime=100, phase='playing', videoFramesAdmitted=600,
                    windowVideoAdmissionFPS=60, audioPacketsAdmitted=500,
                    windowAudioPacketsPerSecond=50, thermalState=0, attempts=1,
                    videoTimelineResets=0, audioTimelineResets=0, lateAudioPackets=0)
        rows = [dict(base, uptime=250, attempts=attempts, videoFramesAdmitted=9600, audioPacketsAdmitted=8000),
                dict(base, uptime=280, attempts=attempts, videoFramesAdmitted=9600 if frozen else 11400,
                     audioPacketsAdmitted=8000 if audio_frozen else 9500,
                     instanceID='two' if process_changed else 'one')]
        (folder / 'manifest.json').write_text(json.dumps(dict(collectionResult='complete', senderRestart=dict(attemptsBefore=1))))
        (folder / 'receiver-baseline.json').write_text(json.dumps(base))
        (folder / 'polls.jsonl').write_text(''.join(json.dumps(row)+'\n' for row in rows))
        (folder / 'sender.log').write_text('{"type":"fixture-video-pause"}\n')

    def test_sender_recovery_requires_same_process_new_attempt_and_advancing_video_and_audio(self):
        for settings, expected in [({}, True), ({'process_changed': True}, False),
                                   ({'frozen': True}, False), ({'audio_frozen': True}, False), ({'attempts': 1}, False)]:
            with self.subTest(settings=settings), tempfile.TemporaryDirectory() as temporary:
                folder = Path(temporary)
                self.fixture(folder, **settings)
                self.assertEqual(stability.recovery_result(folder, 'sender-restart')['passed'], expected)

    def test_video_delay_recovery_cannot_hide_a_reconnect(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            self.fixture(folder, attempts=1)
            self.assertTrue(stability.recovery_result(folder, 'video-delay')['passed'])
            self.fixture(folder, attempts=2)
            self.assertFalse(stability.recovery_result(folder, 'video-delay')['passed'])


if __name__ == '__main__':
    unittest.main()
