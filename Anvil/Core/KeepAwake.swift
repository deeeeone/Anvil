import Foundation
#if canImport(IOKit)
import IOKit.pwr_mgt
#endif

/// Keeps the Mac awake while Anvil works. The power assertion stops idle sleep without admin rights; working with
/// the lid closed needs `pmset disablesleep 1`, which asks for your password once (and is undone when you turn it off
/// or quit Anvil).
final class KeepAwake {
    static let shared = KeepAwake()
#if canImport(IOKit)
    private var assertion: IOPMAssertionID = 0
#endif
    private(set) var held = false

    func update(working: Bool) {
#if canImport(IOKit)
        let want = working && AppSettings.shared.keepAwake
        if want && !held {
            held = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                               "Anvil is working on a task" as CFString, &assertion) == kIOReturnSuccess
        } else if !want && held {
            IOPMAssertionRelease(assertion)
            held = false
        }
#else
        // TODO(linux): no power assertion API here; keep-awake is a no-op.
#endif
    }

    /// Whether sleep is disabled system-wide (lid-closed mode).
    static func lidClosedModeOn() async -> Bool {
#if os(macOS)
        let r = await ProcessRunner.run("/usr/bin/pmset", ["-g"], timeout: 5)
        return r.stdout.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
#else
        return false // TODO(linux): lid-closed mode is a macOS feature.
#endif
    }

    /// Turns lid-closed mode on or off. macOS shows its own password prompt. Returns an error message, or nil.
    static func setLidClosedMode(_ on: Bool) async -> String? {
#if os(macOS)
        let script = "do shell script \"/usr/bin/pmset -a disablesleep \(on ? 1 : 0)\" with administrator privileges"
        let r = await ProcessRunner.run("/usr/bin/osascript", ["-e", script], timeout: 120)
        if r.status == 0 {
            UserDefaults.standard.set(on, forKey: "lidModeSetByAnvil")
            return nil
        }
        return r.combined.contains("-128") ? "Cancelled." : Fmt.line(r.combined, 200)
#else
        return "Lid-closed mode is only available on macOS."
#endif
    }
}
