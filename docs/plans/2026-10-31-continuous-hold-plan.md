# Continuous Hold Voice Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Keep Google ATVV voice recording active for several minutes while the physical voice key stays held.

**Architecture:** A pure session policy parses AUDIO_START's stream ID and schedules a MIC_EXTEND command every five seconds. Engine owns protocol writes and stops the policy on release/disconnect/shutdown. Handy's hold mode remains unchanged.

**Tech Stack:** Swift, Foundation, CoreBluetooth, macOS, existing Swift executable tests.

---

### Task 1: Protocol policy regression
- Add `Tests/VoiceSessionTests.swift` and `Sources/VoiceSession.swift`.
- Verify no session yields no keepalive; a start packet `04 03 02 2B` yields `0E 2B` at five seconds, not earlier.
- Test duplicate start, ID change, malformed packets, nonfinite clock, release/disconnect, and a simulated five-minute hold.
- Run `swiftc Sources/VoiceSession.swift Tests/VoiceSessionTests.swift -o /tmp/google-voice-session-tests` then run the executable. Observe expected failure before implementing the policy, then green.

### Task 2: Engine integration
- Update `Sources/Engine.swift`: on full Google AUDIO_START pass session data to policy; poll from the existing main-actor watchdog; write returned command only for the same connected active voice session.
- Stop policy on AUDIO_STOP, disconnect and shutdown. Log periodic progress/counts and final duration/keepalive count; never log audio bytes.
- Add the new test executable to `scripts/run-tests.sh`.
- Preserve Google fork identity, existing volume and shortcuts when syncing the locally installed build.

### Task 3: Verification and delivery
- Run `sh scripts/run-tests.sh` and `./build.sh` in both source trees; verify app signatures.
- Safely replace installed app after capture helper restores settings; keep rollback and current configuration.
- Validate continuous physical hold for at least three minutes and exactly one Handy result on release. If the remote rejects extension or stops, record reason and fix before claiming long-hold acceptance.
- Update public README, protocol/troubleshooting and changelog with actual evidence/limits, then commit/push only sanitized source and verify CI.

## 验收调整与最终结果

用户在持续长按测试于95.07秒因蓝牙断开结束后，明确表示“1分钟35秒其实也可以了”。按用户更新后的验收口径交付，不再要求三分钟。实测4726包、约49.7包/秒、19次保活，Handy新增一次结果；取消、数据缺失、断线和自动启动边界的无特权检查均通过。蓝牙断开限制保留并公开说明，不宣称不限时或固定95秒上限。
