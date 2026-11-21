import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac awake while Anvil works. The power assertion stops idle sleep without admin rights; working with
/// the lid closed needs `pmset disablesleep 1`, which asks for your password once (and is undone when you turn it off
/// or quit Anvil).
final class KeepAwake {
    static let shared = KeepAwake()
    private var assertion: IOPMAssertionID = 0
    private(set) var held = false

    func update(working: Bool) {
        let want = working && AppSettings.shared.keepAwake
        if want && !held {
            held = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                               "Anvil is working on a task" as CFString, &assertion) == kIOReturnSuccess
        } else if !want && held {
            IOPMAssertionRelease(assertion)
            held = false
        }
    }

    /// Whether sleep is disabled system-wide (lid-closed mode).
    static func lidClosedModeOn() async -> Bool {
        let r = await ProcessRunner.run("/usr/bin/pmset", ["-g"], timeout: 5)
        return r.stdout.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
    }

    /// Turns lid-closed mode on or off. macOS shows its own password prompt. Returns an error message, or nil.
    static func setLidClosedMode(_ on: Bool) async -> String? {
        let script = "do shell script \"/usr/bin/pmset -a disablesleep \(on ? 1 : 0)\" with administrator privileges"
        let r = await ProcessRunner.run("/usr/bin/osascript", ["-e", script], timeout: 120)
        if r.status == 0 {
            UserDefaults.standard.set(on, forKey: "lidModeSetByAnvil")
            return nil
        }
        return r.combined.contains("-128") ? "Cancelled." : Fmt.line(r.combined, 200)
    }
}
