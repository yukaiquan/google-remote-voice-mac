import Foundation
@main struct CaptureStartupTests {
 static func main() {
  var n=0, failures=0
  func check(_ x:@autoclosure()->Bool,_ label:String){n+=1;if !x(){failures+=1;print("FAIL: \(label)")}}
  var startup=CaptureStartup()
  check(!startup.shouldStart(enabled:true,ready:false,active:false),"wait for device and permissions")
  check(!startup.shouldStart(enabled:false,ready:true,active:false),"disabled preference never auto-starts")
  check(!startup.shouldStart(enabled:true,ready:true,active:true),"do not duplicate an active session")
  check(startup.shouldStart(enabled:true,ready:true,active:false),"start automatically when ready")
  check(!startup.shouldStart(enabled:true,ready:true,active:false),"cancel/error does not repeat authorization")
  startup.reset();startup.suppress()
  check(!startup.shouldStart(enabled:true,ready:true,active:false),"manual stop stays stopped for current app run")
  startup.reset()
  check(startup.shouldStart(enabled:true,ready:true,active:false),"explicit re-enable may retry once")
  startup.reset();startup.markAttempted()
  check(!startup.shouldStart(enabled:true,ready:true,active:false),"manual start failure also prevents automatic prompts")
  print("\(n-failures)/\(n) capture startup checks passed")
  exit(failures==0 ? 0:1)
 }
}
