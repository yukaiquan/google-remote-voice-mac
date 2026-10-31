import unittest
import subprocess
import sys
import json
from pathlib import Path
from chromecast_packet_events import EventDecoder

def notification(value, name="Chromecast Remote", attribute="0x0046", connection="0x0041"):
    return (f"2026-10-31T17:14:26.628+08:00  ATT Receive      {name}  {connection}  RECV  "
            f"Handle Value Notification - Handle:{attribute} - Value: {value}  "
            "41 20 08 00 04 00 04 00 1B 46 00 03\n")

class DecoderTests(unittest.TestCase):
    def setUp(self):
        self.decoder = EventDecoder(0x46)

    def test_single_press_release_from_short_reports(self):
        self.assertEqual(self.decoder.feed(notification("03")), [("down", 3)])
        self.assertEqual(self.decoder.feed(notification("00")), [("up", 3)])

    def test_chord_diff_and_release(self):
        self.assertEqual(self.decoder.feed(notification("0B")), [("down", 11)])
        self.assertEqual(self.decoder.feed(notification("030B")), [("down", 3)])
        self.assertEqual(self.decoder.feed(notification("00")), [("up", 3), ("up", 11)])

    def test_duplicate_notification_is_not_another_press(self):
        self.decoder.feed(notification("03"))
        self.assertEqual(self.decoder.feed(notification("03")), [])

    def test_filters_other_device_and_attribute(self):
        self.assertEqual(self.decoder.feed(notification("03", name="Other keyboard")), [])
        self.assertEqual(self.decoder.feed(notification("03", attribute="0x0028")), [])
        self.assertEqual(self.decoder.feed(notification("03")), [("down", 3)])

    def test_rejects_invalid_payload_without_releasing_held_key(self):
        self.decoder.feed(notification("03"))
        for invalid in ["FF", "03FF", "030B00", "0", "GG"]:
            self.assertEqual(self.decoder.feed(notification(invalid)), [])
        self.assertEqual(self.decoder.feed(notification("00")), [("up", 3)])

    def test_zero_second_slot_and_spaced_values(self):
        self.assertEqual(self.decoder.feed(notification("03 00")), [("down", 3)])
        self.assertEqual(self.decoder.feed(notification("00 00")), [("up", 3)])

    def test_changed_connection_releases_old_state(self):
        self.decoder.feed(notification("03"))
        self.assertEqual(self.decoder.feed(notification("0B", connection="0x0042")),
                         [("up", 3), ("down", 11)])

    def test_cli_reads_stdin_and_emits_only_events(self):
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("chromecast_packet_events.py")),
                                 "--attribute", "0x46"],
                                input=notification("03") + notification("00"), text=True,
                                capture_output=True, check=True)
        self.assertEqual([json.loads(line) for line in result.stdout.splitlines()],
                         [{"event": "down", "button": 3}, {"event": "up", "button": 3}])

if __name__ == "__main__":
    unittest.main()
