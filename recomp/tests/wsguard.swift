// WindowServer guard: wsguard <pid> [log]
// Pings WindowServer (a CGWindowList query) every 0.5 s. If a ping is outstanding for over
// 1.5 s, the game is frozen with SIGSTOP so it stops submitting GPU work, and resumed with
// SIGCONT once WindowServer answers again. A frozen game cannot starve WindowServer's GPU
// access, while killing it would make the kernel tear down its GPU memory under the same
// lock. Exits when the game exits.
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 2, let pid = pid_t(args[1]) else {
    FileHandle.standardError.write("usage: wsguard <pid> [log]\n".data(using: .utf8)!)
    exit(2)
}
let logPath = args.count >= 3 ? args[2] : nil

func log(_ s: String) {
    let line = "wsguard: \(s)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    if let p = logPath, let h = FileHandle(forWritingAtPath: p) ?? {
        FileManager.default.createFile(atPath: p, contents: nil)
        return FileHandle(forWritingAtPath: p)
    }() {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    }
}

let lock = NSLock()
var pingStart: Double = 0   // start time of the outstanding ping, 0 when none
var lastPing: Double = 0

func now() -> Double { Date().timeIntervalSince1970 }

// WSGUARD_TEST_STALL=<s>: the first ping pretends WindowServer hangs that long (self-test).
var testStall = Double(ProcessInfo.processInfo.environment["WSGUARD_TEST_STALL"] ?? "") ?? 0
Thread.detachNewThread {
    while true {
        lock.lock(); pingStart = now(); lock.unlock()
        if testStall > 0 { Thread.sleep(forTimeInterval: testStall); testStall = 0 }
        _ = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        lock.lock(); lastPing = now() - pingStart; pingStart = 0; lock.unlock()
        Thread.sleep(forTimeInterval: 0.5)
    }
}

// WSGUARD_THRESHOLD (seconds) overrides 1.5 s, e.g. to test the pause path.
let threshold = Double(ProcessInfo.processInfo.environment["WSGUARD_THRESHOLD"] ?? "") ?? 1.5
var frozen = false
var frozenAt: Double = 0
log("guarding pid \(pid)")
while kill(pid, 0) == 0 {
    Thread.sleep(forTimeInterval: 0.1)
    lock.lock(); let start = pingStart; lock.unlock()
    let waiting = start > 0 ? now() - start : 0
    if !frozen && waiting > threshold {
        kill(pid, SIGSTOP)
        frozen = true; frozenAt = now()
        log(String(format: "WindowServer unresponsive for %.1f s: game paused", waiting))
    } else if frozen && start == 0 {
        // Give WindowServer a moment to catch up before resuming.
        Thread.sleep(forTimeInterval: 1.0)
        kill(pid, SIGCONT)
        frozen = false
        log(String(format: "WindowServer responsive again: game resumed after %.1f s", now() - frozenAt))
    }
}
log("game exited")
