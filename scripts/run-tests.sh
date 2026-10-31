#!/bin/sh
set -eu
TASK_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TASK_TEST_DIR="$(mktemp -d /tmp/miremote-tests.XXXXXX)"
trap '/bin/rm -r "$TASK_TEST_DIR"' EXIT
swiftc "$TASK_ROOT/Sources/GoogleCaptureCore.swift" "$TASK_ROOT/Tests/GoogleCaptureCoreTests.swift" -o "$TASK_TEST_DIR/core"
"$TASK_TEST_DIR/core"
swiftc "$TASK_ROOT/Sources/Model.swift" "$TASK_ROOT/Tests/GoogleModelTests.swift" -o "$TASK_TEST_DIR/model"
"$TASK_TEST_DIR/model"
swiftc "$TASK_ROOT/Sources/VoiceAudioCore.swift" "$TASK_ROOT/Sources/GoogleVoiceLink.swift" "$TASK_ROOT/Tests/VoiceAudioTests.swift" -o "$TASK_TEST_DIR/audio"
"$TASK_TEST_DIR/audio"
swiftc "$TASK_ROOT/Sources/VoiceSession.swift" "$TASK_ROOT/Tests/VoiceSessionTests.swift" -o "$TASK_TEST_DIR/session"
"$TASK_TEST_DIR/session"
swiftc "$TASK_ROOT/Sources/CaptureStartup.swift" "$TASK_ROOT/Tests/CaptureStartupTests.swift" -o "$TASK_TEST_DIR/startup"
"$TASK_TEST_DIR/startup"
python3 -m unittest discover -s "$TASK_ROOT/scripts" -p test_chromecast_packet_events.py
