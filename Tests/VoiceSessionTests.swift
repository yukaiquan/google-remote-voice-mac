import Foundation
@main struct VoiceSessionTests {
 static func main() {
  var checks=0, failures=0
  func check(_ condition: @autoclosure () -> Bool, _ name:String) {
   checks+=1; if !condition() { failures+=1;print("FAIL: \(name)") }
  }
  var session=VoiceSession()
  check(session.poll(at:100)==nil,"idle session never extends microphone")
  check(session.begin(Data([4,3,2,0x2B]),at:0),"accept full 16kHz voice start")
  check(session.poll(at:4.99)==nil,"do not extend before five seconds")
  check(session.poll(at:5)==Data([0x0E,0x2B]),"extend actual nonzero stream ID")
  check(session.poll(at:5.01)==nil,"no repeated extension in same interval")
  check(!session.begin(Data([4,3,2,0x2B]),at:9),"duplicate audio start is not a new session")
  check(session.poll(at:10)==Data([0x0E,0x2B]),"duplicate start cannot postpone keepalive")
  for second in stride(from:15,through:300,by:5) {
   check(session.poll(at:Double(second))==Data([0x0E,0x2B]),"hold remains active at \(second)s")
  }
  check(session.sentCount==60,"five minute hold sends sixty spaced extensions")
  session.stop()
  check(session.poll(at:400)==nil,"release/disconnect/quit cancels future extensions")
  check(session.begin(Data([4,3,2,0xA1]),at:500),"new stream replaces old ID")
  check(session.poll(at:505)==Data([0x0E,0xA1]),"new session never sends stale ID")
  check(session.sentCount==1,"new session resets extension count")
  check(session.poll(at:1000)==Data([0x0E,0xA1]),"late scheduler sends only one command")
  check(session.poll(at:1000)==nil,"late scheduler never bursts catch-up writes")
  session.stop()
  for packet in [Data(),Data([4]),Data([4,3,2]),Data([0,3,2,1]),Data([4,3,1,1])] {
   check(!session.begin(packet,at:0),"reject incomplete or unsupported start")
  }
  check(!session.begin(Data([4,3,2,1]),at:.nan),"reject invalid clock")
  check(session.poll(at:.infinity)==nil,"ignore invalid timer clock")
  check(!VoiceSession.audioStalled(at:2.99,startedAt:0,lastAudioAt:nil),"allow initial audio setup")
  check(VoiceSession.audioStalled(at:3,startedAt:0,lastAudioAt:nil),"detect a microphone which never supplies data")
  check(!VoiceSession.audioStalled(at:300,startedAt:0,lastAudioAt:299.99),"quiet pauses do not stop a live audio stream")
  check(VoiceSession.audioStalled(at:303,startedAt:0,lastAudioAt:300),"stop extending after missing audio data")
  print("\(checks-failures)/\(checks) voice session checks passed")
  exit(failures==0 ? 0:1)
 }
}
