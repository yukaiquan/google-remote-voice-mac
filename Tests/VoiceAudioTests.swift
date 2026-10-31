import Foundation
@main struct VoiceAudioTests {
 static func main() {
  var failures = 0, checks = 0
  func check(_ value: @autoclosure () -> Bool, _ label: String) {
   checks += 1; if !value() { failures += 1; print("FAIL: \(label)") }
  }
  var dsp = VoiceDSP()
  let initial = dsp.gain
  dsp.gain = 24; dsp.reset()
  check(dsp.gain == initial, "reset must not carry previous session gain")
  dsp = VoiceDSP()
  let quiet = (0..<32000).map { Float(0.003 * sin(2 * Double.pi * 1000 * Double($0) / 16000)) }
  _ = dsp.process(quiet)
  check(dsp.gain <= 4, "quiet background must not drive automatic amplification to 24x")
  check(dsp.process(Array(repeating: 0, count: 16000)).suffix(100).allSatisfy { abs($0) < 0.00001 }, "silence settles to silence")
  var fresh = VoiceDSP()
  let loud = fresh.process((0..<1600).map { Float(sin(2 * Double.pi * 300 * Double($0) / 16000)) })
  check(loud.allSatisfy { $0.isFinite && abs($0) <= 1 }, "loud input remains finite and bounded")
  check(GoogleVoiceLink.supportsABI("v32@0:8q16@24"), "accept verified arm64 latency-request ABI")
  check(!GoogleVoiceLink.supportsABI(nil), "skip missing runtime method")
  check(!GoogleVoiceLink.supportsABI("v32@0:8@16@24"), "reject object/scalar mismatch before invoking runtime method")
  check(!GoogleVoiceLink.supportsABI("q32@0:8q16@24"), "reject changed return ABI")
  print("\(checks-failures)/\(checks) audio checks passed")
  exit(failures == 0 ? 0 : 1)
 }
}
