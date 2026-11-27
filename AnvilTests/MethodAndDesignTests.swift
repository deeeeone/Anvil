import XCTest
@testable import Anvil

/// The build method and design guidance in the prompt, UI request detection, design skill choice, and the first-turn
/// effort. No network: the agent's replies are scripted.
final class MethodAndDesignTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-method-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// Writes a SKILL.md under `root/<folder>/SKILL.md`.
    func writeSkill(_ name: String, under root: URL, body: String = "Use real type scales.") throws {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: Design guidance for \(name).\n---\n\(body)\n".write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    /// Only the skills found in the temp project (source "project"), so the user's own ~/.claude/skills can't change the result.
    func projectSkills(_ project: URL) -> [FolderSkill] {
        SkillLibrary.all(project: project).filter { $0.source == "project" }
    }

    // MARK: Prompt

    func testFixedPromptHasMethodAndDesignSections() {
        let p = PromptBuilder.fixed(catalog: "CATALOG")
        XCTAssertTrue(p.contains("BUILDING SOMETHING NEW"))
        XCTAssertTrue(p.contains("UI AND DESIGN QUALITY"))
        XCTAssertTrue(p.contains("own new folder"))
        XCTAssertTrue(p.contains("browser_open"))
        XCTAssertTrue(p.contains("browser_viewport"))
        XCTAssertTrue(p.contains("4.5 to 1"))
        XCTAssertLessThan(p.range(of: "BUILDING SOMETHING NEW")!.lowerBound, p.range(of: "ACTIONS")!.lowerBound, "the sections come before the catalog")
        XCTAssertFalse(p.contains("\u{2014}"), "no em dashes in prompt text")
        XCTAssertFalse(p.contains("\u{2013}"), "no en dashes in prompt text")
    }

    func testFirstReplyMayPlanButRoutineRepliesStayShort() {
        let p = PromptBuilder.fixed(catalog: "")
        XCTAssertTrue(p.contains("The first reply to a build task may be a short plan"))
        XCTAssertTrue(PromptBuilder.formatReminder.contains("a short plan is fine as the first reply to a build task"))
    }

    func testJudgeRequiresBrowserEvidenceForUI() {
        let p = CompletionJudge.prompt(goal: "build a page", criteria: [], diff: "", files: "", lastCheck: "", answer: "done")
        XCTAssertTrue(p.contains("UI not verified in the browser"))
    }

    // MARK: UI detection

    func testUIRequestDetection() {
        XCTAssertTrue(SkillLibrary.isUIRequest("build a polished JSON diff tool (React)"))
        XCTAssertTrue(SkillLibrary.isUIRequest("make a landing page for my shop"))
        XCTAssertTrue(SkillLibrary.isUIRequest("fix the CSS of the sidebar"))
        XCTAssertTrue(SkillLibrary.isUIRequest("UI: add a dark mode toggle"))
        XCTAssertFalse(SkillLibrary.isUIRequest("rename calc to calculateTotal"))
        XCTAssertFalse(SkillLibrary.isUIRequest("add a due date option to the CLI with tests"))
        XCTAssertFalse(SkillLibrary.isUIRequest("fix the flaky parser test"), "whole words only")
        XCTAssertFalse(SkillLibrary.isUIRequest("add pagination to the API"), "'pagination' is not 'page'")
    }

    // MARK: Design skill choice

    func testDesignSkillPriority() throws {
        let skills = dir.appendingPathComponent(".claude/skills")
        try writeSkill("anti-slop", under: skills)
        try writeSkill("impeccable", under: skills)
        XCTAssertEqual(SkillLibrary.designSkill(project: dir, among: projectSkills(dir))?.name, "impeccable")

        try writeSkill("frontend-design", under: skills)
        XCTAssertEqual(SkillLibrary.designSkill(project: dir, among: projectSkills(dir))?.name, "frontend-design")
    }

    func testDesignSkillNoneAvailable() throws {
        XCTAssertNil(SkillLibrary.designSkill(project: dir, among: []))
        try writeSkill("code-review", under: dir.appendingPathComponent(".claude/skills"))
        XCTAssertNil(SkillLibrary.designSkill(project: dir, among: projectSkills(dir)))
    }

    func testDesignSkillFromAnvilFolderBeatsLowerPriority() throws {
        // .anvil/skills and .claude/skills are both project folders; the priority is by name, not by folder.
        try writeSkill("anti-slop", under: dir.appendingPathComponent(".anvil/skills"))
        try writeSkill("frontend-design", under: dir.appendingPathComponent(".claude/skills"))
        XCTAssertEqual(SkillLibrary.designSkill(project: dir, among: projectSkills(dir))?.name, "frontend-design")
    }

    // MARK: First-turn note

    func testSkillNoteIncludesDesignSkillOnFirstUITurn() throws {
        try writeSkill("frontend-design", under: dir.appendingPathComponent(".claude/skills"), body: "MARKER_DESIGN_TEXT")
        let note = SkillLibrary.skillNote(for: "build a landing page", project: dir, firstTurn: true)
        XCTAssertTrue(note.contains("DESIGN SKILL (loaded automatically for this UI task): frontend-design"))
        XCTAssertTrue(note.contains("MARKER_DESIGN_TEXT"))
        XCTAssertFalse(note.contains("SKILLS THAT MAY HELP") && note.contains("- frontend-design:"), "the design skill is not listed twice")
        // Later turns and non-UI requests don't get it.
        XCTAssertFalse(SkillLibrary.skillNote(for: "build a landing page", project: dir, firstTurn: false).contains("DESIGN SKILL"))
        XCTAssertFalse(SkillLibrary.skillNote(for: "add a due date option to the CLI", project: dir, firstTurn: true).contains("DESIGN SKILL"))
    }

    func testSkillNoteClipsLongDesignSkill() throws {
        try writeSkill("frontend-design", under: dir.appendingPathComponent(".claude/skills"), body: String(repeating: "word ", count: 3000))
        let note = SkillLibrary.skillNote(for: "style the dashboard", project: dir, firstTurn: true)
        XCTAssertTrue(note.contains("DESIGN SKILL (loaded automatically for this UI task): frontend-design"))
        XCTAssertLessThan(note.count, 6800)
    }

    // MARK: Effort

    func testFirstTurnOfAFeatureUsesFullEffort() {
        func e(_ size: RequestSize, step: Int = 1, full: String) -> String {
            AdaptiveEffort.effort(.init(step: step, size: size, editedThisRequest: false, lastBatchExploratory: false, lastBatchFailed: false,
                                        verifiedSinceEdit: false, parseFailures: 0), full: full)
        }
        XCTAssertEqual(e(.feature, full: "max"), "max", "first turn of a feature gets the owner's full effort")
        XCTAssertEqual(e(.hard, full: "max"), "max")
        XCTAssertEqual(e(.simple, full: "max"), "low", "simple requests still start low")
        XCTAssertEqual(e(.question, full: "max"), "medium")
        XCTAssertEqual(e(.feature, full: "medium"), "medium", "the setting is still the ceiling")
    }

    func testUIFixIsNotClassifiedSimple() {
        XCTAssertEqual(RequestSize.classify("fix the typo on the landing page"), .feature)
        XCTAssertEqual(RequestSize.classify("fix the typo in the README"), .simple)
    }

    // MARK: The agent's first message

    func testFirstTurnIntroIncludesDesignSkillForUIRequest() async throws {
        try "def add(a, b):\n    return a + b\n".write(to: dir.appendingPathComponent("calc.py"), atomically: true, encoding: .utf8)
        try writeSkill("frontend-design", under: dir.appendingPathComponent(".claude/skills"), body: "MARKER_DESIGN_TEXT")
        let host = TestHost()
        var histories: [[ChatMessage]] = []
        let brain = Brain(client: OpenAIClient(baseURL: URL(string: "http://localhost:1")!, apiKey: ""), model: "m", visionModel: "", effort: "high", visionEffort: "low")
        brain.override = { history, _ in
            histories.append(history)
            return #"{"say": "done", "actions": [], "done": true}"#
        }
        let ctx = ToolContext(root: dir, processes: ProcessManager(), host: host)
        let a = Agent(ctx: ctx, brain: brain)
        a.mode = .bypass
        a.autoVerify = false
        a.selfReview = false
        a.streaming = false
        a.prepareWhilePlanning = false
        a.memory = ProjectMemory()
        _ = await a.run(goal: "build a polished landing page for the calculator")
        let text = histories.flatMap { $0 }.map(\.text).joined(separator: "\n")
        XCTAssertFalse(histories.isEmpty)
        XCTAssertTrue(text.contains("DESIGN SKILL"), "the first message carries the design skill")
        XCTAssertTrue(text.contains("MARKER_DESIGN_TEXT"))
    }
}
