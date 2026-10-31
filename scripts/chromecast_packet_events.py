"""Read-only PacketLogger notification decoder; never injects input."""
import argparse
import json
import re
import sys

NOTIFICATION = re.compile(
    r"^\S+\s+ATT Receive\s+Chromecast Remote\s+(0x[0-9A-Fa-f]+)\s+RECV\s+"
    r"Handle Value Notification - Handle:(0x[0-9A-Fa-f]+) - Value: "
    r"([0-9A-Fa-f]+(?: [0-9A-Fa-f]+)*)(?:\s{2,}|$)"
)

class EventDecoder:
    def __init__(self, attribute):
        self.attribute = attribute
        self.connection = None
        self.held = set()

    def feed(self, line):
        match = NOTIFICATION.match(line)
        if not match or int(match[2], 16) != self.attribute:
            return []
        try:
            payload = bytes.fromhex(match[3])
        except ValueError:
            return []
        if len(payload) not in (1, 2) or any(value > 17 for value in payload):
            return []
        connection = int(match[1], 16)
        events = []
        if self.connection is not None and connection != self.connection:
            events.extend(("up", value) for value in sorted(self.held))
            self.held.clear()
        self.connection = connection
        pressed = set(payload) - {0}
        events.extend(("up", value) for value in sorted(self.held - pressed))
        events.extend(("down", value) for value in sorted(pressed - self.held))
        self.held = pressed
        return events

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--attribute", required=True, type=lambda value: int(value, 0),
                        help="Verified ATT input attribute for this session; do not guess")
    args = parser.parse_args()
    decoder = EventDecoder(args.attribute)
    for line in sys.stdin:
        for event, button in decoder.feed(line):
            print(json.dumps({"event": event, "button": button}), flush=True)
