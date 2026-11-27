import Foundation
import Observation

@Observable final class Counter {
    var n = 0
}

/// No annotation: under defaultIsolation(MainActor.self) this is MainActor-isolated.
final class Plain {
    var value = 41

    func describe() -> String {
        "Plain.value=\(value)"
    }
}

/// Set from the onChange closure, which Observation may invoke on any thread.
nonisolated final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    nonisolated init() {}

    nonisolated func fire() {
        lock.lock()
        fired = true
        lock.unlock()
    }

    nonisolated func isFired() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
}

func runObserve() async -> Bool {
    MainActor.assertIsolated()
    print("  MainActor.assertIsolated() succeeded inside async @main")

    // Non-annotated class, used without await from the main actor.
    let plain = Plain()
    print("  \(plain.describe()) read without await (MainActor by default)")

    let counter = Counter()
    let flag = Flag()
    withObservationTracking({ _ = counter.n }, onChange: { flag.fire() })

    try? await Task.sleep(for: .milliseconds(50))
    counter.n += 1
    try? await Task.sleep(for: .milliseconds(50))

    let fired = flag.isFired()
    return report(fired, "observe", "onChange fired=\(fired), counter.n=\(counter.n)")
}
