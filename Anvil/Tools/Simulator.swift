import AppKit
import Observation

/// iOS Simulator control. simctl (ships with Xcode) boots devices, installs and launches apps, opens URLs, takes
/// screenshots and reads logs. AXe (open source, `brew tap cameroncooke/axe && brew install axe`) reads the
/// accessibility tree and taps, types and swipes without touching the Mac's mouse. Without AXe the agent still
/// gets screenshots for the vision model.
nonisolated enum Sim {
    struct Device: Sendable, Equatable { var udid: String; var name: String; var state: String; var runtime: String }
    struct Element: Sendable, Equatable { var id: Int; var role: String; var label: String; var value: String; var identifier: String; var frame: CGRect }

    static var axePath: String? {
        let candidates = ["/opt/homebrew/bin/axe", "/usr/local/bin/axe", Paths.home.path + "/.local/bin/axe"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static let installAXe = "brew tap cameroncooke/axe && brew install axe"

    static func simctl(_ args: [String], timeout: Double = 120) async -> ProcessOutput {
        await ProcessRunner.run("/usr/bin/xcrun", ["simctl"] + args, timeout: timeout)
    }

    static func axe(_ args: [String], udid: String, timeout: Double = 30) async throws -> String {
        guard let axe = axePath else { throw ToolFailure("AXe isn't installed, so taps and element reading aren't available. Install it with: \(installAXe) (or use sim_screenshot to look).") }
        let r = await ProcessRunner.run(axe, args + ["--udid", udid], timeout: timeout)
        guard r.status == 0 else { throw ToolFailure("axe \(args.first ?? ""): \(Fmt.line(r.combined, 300))") }
        return r.stdout
    }

    static func devices() async -> [Device] {
        let r = await simctl(["list", "-j", "devices", "available"])
        return parseDevices(r.stdout)
    }

    static func parseDevices(_ json: String) -> [Device] {
        guard let j = JSON.parse(json)?["devices"]?.object else { return [] }
        var out: [Device] = []
        for (runtime, list) in j {
            let rt = runtime.components(separatedBy: ".").last?.replacingOccurrences(of: "-", with: " ") ?? runtime
            for d in list.array ?? [] {
                guard let udid = d["udid"]?.string, let name = d["name"]?.string else { continue }
                out.append(Device(udid: udid, name: name, state: d["state"]?.string ?? "", runtime: rt))
            }
        }
        return out.sorted { ($0.state == "Booted" ? 0 : 1, $0.runtime, $0.name) < ($1.state == "Booted" ? 0 : 1, $1.runtime, $1.name) }
    }

    /// The booted device (or a named one), else nil.
    static func target(_ name: String? = nil) async throws -> Device {
        let all = await devices()
        if all.isEmpty { throw ToolFailure("No iOS Simulator devices: no simulator runtime is installed. Install one in Xcode > Settings > Components, or run: xcodebuild -downloadPlatform iOS") }
        if let name, !name.isEmpty {
            if let d = all.first(where: { $0.udid == name || $0.name.caseInsensitiveCompare(name) == .orderedSame }) ?? all.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) { return d }
            throw ToolFailure("no simulator named \(name). Available: \(all.prefix(8).map(\.name).joined(separator: ", "))")
        }
        if let booted = all.first(where: { $0.state == "Booted" }) { return booted }
        throw ToolFailure("no simulator is booted; use sim_boot first")
    }

    /// Flattens AXe's describe-ui JSON (nested elements with frames) into numbered, visible elements.
    static func parseElements(_ json: String) -> [Element] {
        guard let root = JSON.parse(json) else { return [] }
        var out: [Element] = []
        func frame(_ j: JSON) -> CGRect? {
            if let f = j["frame"] ?? j["AXFrame"] {
                if let x = f["x"]?.double, let y = f["y"]?.double, let w = f["width"]?.double, let h = f["height"]?.double { return CGRect(x: x, y: y, width: w, height: h) }
                if let s = f.string {   // "{{x, y}, {w, h}}"
                    let n = s.components(separatedBy: CharacterSet(charactersIn: "{}, ")).compactMap(Double.init)
                    if n.count == 4 { return CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) }
                }
            }
            return nil
        }
        func walk(_ j: JSON) {
            if let arr = j.array { arr.forEach(walk); return }
            guard j.object != nil else { return }
            let role = (j["type"] ?? j["role"] ?? j["AXRole"])?.string ?? ""
            let label = (j["AXLabel"] ?? j["label"] ?? j["title"] ?? j["AXTitle"])?.string ?? ""
            let value = (j["AXValue"] ?? j["value"])?.string ?? ""
            let ident = (j["AXUniqueId"] ?? j["identifier"] ?? j["AXIdentifier"])?.string ?? ""
            if let f = frame(j), f.width > 0, f.height > 0, !(label.isEmpty && value.isEmpty && ident.isEmpty && ["Application", "Window", "Other", "Group", ""].contains(role)) {
                out.append(Element(id: out.count + 1, role: role, label: label, value: value, identifier: ident, frame: f))
            }
            for k in ["children", "AXChildren", "elements"] { if let c = j[k] { walk(c) } }
        }
        walk(root)
        return out
    }

    static func describe(_ e: [Element]) -> String {
        e.prefix(200).map { el in
            var s = "[\(el.id)] \(el.role.isEmpty ? "element" : el.role)"
            if !el.label.isEmpty { s += " \"\(Fmt.line(el.label, 60))\"" }
            if !el.value.isEmpty { s += " value=\"\(Fmt.line(el.value, 40))\"" }
            if !el.identifier.isEmpty { s += " #\(el.identifier)" }
            return s + " @\(Int(el.frame.midX)),\(Int(el.frame.midY))"
        }.joined(separator: "\n")
    }

    static func screenshot(_ udid: String) async throws -> Data {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-sim-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        let r = await simctl(["io", udid, "screenshot", "--type=jpeg", file.path], timeout: 30)
        guard r.status == 0, let d = try? Data(contentsOf: file) else { throw ToolFailure("screenshot failed: \(Fmt.line(r.combined, 200))") }
        return d
    }
}

/// The Device tab: a live view of the booted simulator (click to tap when AXe is installed).
@Observable
final class SimulatorController {
    private(set) var device: Sim.Device?
    private(set) var image: NSImage?
    private(set) var note = ""
    private(set) var pointSize: CGSize?
    var axeAvailable: Bool { Sim.axePath != nil }
    @ObservationIgnored private var refreshing = false

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let d = try await Sim.target()
            device = d
            let data = try await Sim.screenshot(d.udid)
            image = NSImage(data: data)
            note = ""
        } catch {
            device = nil
            image = nil
            note = (error as? ToolFailure)?.message ?? error.localizedDescription
        }
    }

    /// `unit` is the click position as a fraction of the screenshot (0...1).
    func tap(unit: CGPoint) async {
        guard let d = device else { return }
        if pointSize == nil, let json = try? await Sim.axe(["describe-ui"], udid: d.udid) {
            pointSize = Sim.parseElements(json).map(\.frame).max { $0.width * $0.height < $1.width * $1.height }?.size
        }
        guard let size = pointSize else { note = Sim.axePath == nil ? "Install AXe to tap from here: \(Sim.installAXe)" : "Couldn't read the screen size"; return }
        _ = try? await Sim.axe(["tap", "-x", "\(Int(unit.x * size.width))", "-y", "\(Int(unit.y * size.height))"], udid: d.udid)
        try? await Task.sleep(for: .milliseconds(350))
        await refresh()
    }

    func home() async {
        guard let d = device else { return }
        _ = try? await Sim.axe(["button", "home"], udid: d.udid)
        await refresh()
    }
}

/// The agent's simulator tools.
enum SimulatorTools {
    static func all() -> [ToolSpec] { [list, boot, runApp, launch, openURL, describe, tap, type, swipe, button, screenshot, logs, appearance] }

    static let list = ToolSpec(name: "sim_list", kind: .read, signature: "{}", summary: "iOS simulators and which is booted", group: .simulator) { _, _ in
        let all = await Sim.devices()
        if all.isEmpty { return .ok("No simulators: no iOS Simulator runtime is installed (Xcode > Settings > Components, or xcodebuild -downloadPlatform iOS).") }
        return .ok(all.prefix(40).map { "\($0.name) (\($0.runtime))\($0.state == "Booted" ? " BOOTED" : "") \($0.udid)" }.joined(separator: "\n")
                   + (Sim.axePath == nil ? "\n(AXe isn't installed: taps and element reading need it: \(Sim.installAXe))" : ""))
    }
    static let boot = ToolSpec(name: "sim_boot", kind: .network, signature: #"{"device": name or udid (default: an iPhone)}"#,
                               summary: "boot a simulator and show it in the Simulator app", group: .simulator) { a, _ in
        var name = a["device"]?.string ?? a["name"]?.string
        if name == nil { name = (await Sim.devices()).first { $0.name.hasPrefix("iPhone") }?.name }
        let d = try await Sim.target(name)
        if d.state != "Booted" {
            let r = await Sim.simctl(["boot", d.udid], timeout: 180)
            if r.status != 0 && !r.combined.contains("current state: Booted") { return .fail("boot failed: \(Fmt.line(r.combined, 300))") }
        }
        _ = await ProcessRunner.run("/usr/bin/open", ["-g", "-a", "Simulator"], timeout: 10)
        _ = await Sim.simctl(["bootstatus", d.udid], timeout: 180)
        return .ok("\(d.name) (\(d.runtime)) is booted")
    }
    static let runApp = ToolSpec(name: "sim_run_app", kind: .network, signature: #"{"app": path to a built .app, optional "args": [str]}"#,
                                 summary: "install a built .app on the booted simulator and launch it (build it first with xcodebuild ... -destination 'platform=iOS Simulator,name=...')", group: .simulator) { a, ctx in
        guard let p = a["app"]?.string ?? a["path"]?.string else { return .fail("missing app path") }
        let url = ctx.resolve(p)
        let d = try await Sim.target()
        let inst = await Sim.simctl(["install", d.udid, url.path], timeout: 180)
        guard inst.status == 0 else { return .fail("install failed: \(Fmt.line(inst.combined, 300))") }
        let plist = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist"))
        guard let bid = plist?["CFBundleIdentifier"] as? String else { return .fail("installed, but couldn't read the bundle id from Info.plist") }
        let r = await Sim.simctl(["launch", "--terminate-running-process", d.udid, bid] + (a["args"]?.array?.compactMap(\.string) ?? []))
        return r.status == 0 ? .ok("installed and launched \(bid) on \(d.name)") : .fail("launch failed: \(Fmt.line(r.combined, 300))")
    }
    static let launch = ToolSpec(name: "sim_launch", kind: .network, signature: #"{"bundle_id": str, optional "terminate": bool}"#,
                                 summary: "launch (or with terminate:true, quit) an installed app", group: .simulator) { a, _ in
        guard let bid = a["bundle_id"]?.string ?? a["app"]?.string else { return .fail("missing bundle_id") }
        let d = try await Sim.target()
        let r = a["terminate"]?.bool == true ? await Sim.simctl(["terminate", d.udid, bid]) : await Sim.simctl(["launch", "--terminate-running-process", d.udid, bid])
        return r.status == 0 ? .ok(r.stdout.isEmpty ? "done" : r.stdout) : .fail(Fmt.line(r.combined, 300))
    }
    static let openURL = ToolSpec(name: "sim_openurl", kind: .network, signature: #"{"url": str}"#, summary: "open a URL or deep link in the simulator", group: .simulator) { a, _ in
        guard let u = a["url"]?.string else { return .fail("missing url") }
        let d = try await Sim.target()
        let r = await Sim.simctl(["openurl", d.udid, u])
        return r.status == 0 ? .ok("opened \(u)") : .fail(Fmt.line(r.combined, 300))
    }
    static let describe = ToolSpec(name: "sim_describe", kind: .network, signature: "{}",
                                   summary: "the screen's accessibility elements, numbered (use the numbers with sim_tap); no screenshot needed", group: .simulator) { _, ctx in
        let d = try await Sim.target()
        let els = Sim.parseElements(try await Sim.axe(["describe-ui"], udid: d.udid))
        ctx.simElements = Dictionary(uniqueKeysWithValues: els.map { ($0.id, $0.frame) })
        if els.isEmpty { return .ok("no accessibility elements found (the app may draw custom UI): use sim_screenshot") }
        return .ok("\(d.name) screen:\n" + Sim.describe(els))
    }
    static let tap = ToolSpec(name: "sim_tap", kind: .network, signature: #"{"id": int} or {"x": num, "y": num} (points), optional "long": bool"#,
                              summary: "tap an element from sim_describe (preferred) or a point", group: .simulator) { a, ctx in
        let d = try await Sim.target()
        var p: CGPoint
        if let id = a["id"]?.int {
            guard let f = ctx.simElements[id] else { return .fail("element [\(id)] isn't in the last sim_describe; run it again") }
            p = CGPoint(x: f.midX, y: f.midY)
        } else if let x = a["x"]?.double, let y = a["y"]?.double { p = CGPoint(x: x, y: y) }
        else { return .fail("need id or x and y") }
        var args = ["tap", "-x", "\(Int(p.x))", "-y", "\(Int(p.y))"]
        if a["long"]?.bool == true { args += ["--pre-delay", "0", "--post-delay", "0", "--duration", "1.0"] }
        _ = try await Sim.axe(args, udid: d.udid)
        try? await Task.sleep(for: .milliseconds(400))
        return .ok("tapped at \(Int(p.x)),\(Int(p.y)); sim_describe again to see the new screen")
    }
    static let type = ToolSpec(name: "sim_type", kind: .network, signature: #"{"text": str}"#, summary: "type text into the focused field (tap the field first)", group: .simulator) { a, _ in
        guard let t = a["text"]?.string else { return .fail("missing text") }
        let d = try await Sim.target()
        _ = try await Sim.axe(["type", t], udid: d.udid)
        return .ok("typed \(t.count) characters")
    }
    static let swipe = ToolSpec(name: "sim_swipe", kind: .network, signature: #"{"direction": "up|down|left|right"} or {"from": [x, y], "to": [x, y]}"#,
                                summary: "swipe or scroll the screen", group: .simulator) { a, _ in
        let d = try await Sim.target()
        var from = CGPoint(x: 200, y: 600), to = CGPoint(x: 200, y: 250)
        if let f = a["from"]?.array?.compactMap(\.double), let t = a["to"]?.array?.compactMap(\.double), f.count == 2, t.count == 2 {
            from = CGPoint(x: f[0], y: f[1]); to = CGPoint(x: t[0], y: t[1])
        } else {
            switch a["direction"]?.string ?? "up" {
            case "down": swap(&from, &to)
            case "left": from = CGPoint(x: 340, y: 420); to = CGPoint(x: 40, y: 420)
            case "right": from = CGPoint(x: 40, y: 420); to = CGPoint(x: 340, y: 420)
            default: break
            }
        }
        _ = try await Sim.axe(["swipe", "--start-x", "\(Int(from.x))", "--start-y", "\(Int(from.y))", "--end-x", "\(Int(to.x))", "--end-y", "\(Int(to.y))"], udid: d.udid)
        return .ok("swiped")
    }
    static let button = ToolSpec(name: "sim_button", kind: .network, signature: #"{"name": "home|lock|siri|side-button|apple-pay"}"#,
                                 summary: "press a hardware button", group: .simulator) { a, _ in
        let d = try await Sim.target()
        _ = try await Sim.axe(["button", a["name"]?.string ?? "home"], udid: d.udid)
        return .ok("pressed \(a["name"]?.string ?? "home")")
    }
    static let screenshot = ToolSpec(name: "sim_screenshot", kind: .network, signature: "{}",
                                     summary: "a screenshot of the simulator, attached for the vision model (layout, custom drawing, or when sim_describe isn't enough)", group: .simulator) { _, _ in
        let d = try await Sim.target()
        let data = try await Sim.screenshot(d.udid)
        var r = ToolResult.ok("screenshot of \(d.name) attached")
        r.image = (data, "image/jpeg")
        return r
    }
    static let logs = ToolSpec(name: "sim_logs", kind: .read, signature: #"{optional "seconds": 30, "process": app name}"#,
                               summary: "recent device logs (crashes, prints, errors)", group: .simulator) { a, _ in
        let d = try await Sim.target()
        var args = ["spawn", d.udid, "log", "show", "--style", "compact", "--last", "\(Int(a["seconds"]?.double ?? 30))s"]
        if let p = a["process"]?.string { args += ["--predicate", "process == \"\(p.replacingOccurrences(of: "\"", with: ""))\""] }
        let r = await Sim.simctl(args, timeout: 60)
        let lines = r.stdout.components(separatedBy: "\n").suffix(120).joined(separator: "\n")
        return .ok(lines.isEmpty ? "no log lines" : Fmt.clip(lines, max: 10000))
    }
    static let appearance = ToolSpec(name: "sim_appearance", kind: .network, signature: #"{"mode": "dark|light"}"#, summary: "switch the simulator to dark or light mode", group: .simulator) { a, _ in
        let d = try await Sim.target()
        let r = await Sim.simctl(["ui", d.udid, "appearance", a["mode"]?.string ?? "dark"])
        return r.status == 0 ? .ok("appearance: \(a["mode"]?.string ?? "dark")") : .fail(Fmt.line(r.combined, 200))
    }
}
