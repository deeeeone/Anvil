#if SWIFT_PACKAGE
@testable import AnvilCore
#else
@testable import Anvil
#endif
import XCTest

final class PresetDataTests: XCTestCase {
    /// The embedded presets load on every platform (Linux has no bundle to read them from).
    func testEmbeddedPresetsLoadAndAreValid() {
        let presets = ProviderPlugins.presets
        XCTAssertEqual(presets.count, PresetData.files.filter { $0.key.hasPrefix("preset-") }.count)
        XCTAssertFalse(presets.isEmpty)
        for p in presets { XCTAssertEqual(p.problems(), [], p.name) }
        XCTAssertEqual(presets.map(\.name), presets.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

#if canImport(Darwin)
    /// The embedded copies must stay byte-identical to the JSON files (regenerate with scripts/sync-presets.sh).
    func testEmbeddedPresetsMatchTheJSONFiles() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Anvil/Providers/Presets")
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertFalse(onDisk.isEmpty)
        XCTAssertEqual(Set(PresetData.files.keys), Set(onDisk))
        for name in onDisk {
            let bytes = try Data(contentsOf: dir.appendingPathComponent(name))
            XCTAssertEqual(PresetData.files[name].map { Data($0.utf8) }, bytes, "\(name) drifted; run scripts/sync-presets.sh")
        }
    }
#endif
}
