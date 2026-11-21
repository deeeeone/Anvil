import XCTest
import SwiftUI
@testable import Anvil

final class MarkdownTests: XCTestCase {
    static let sample = """
    I built **The Internet Graveyard** in Next.js (`internet-graveyard`).

    <Image alt="Illustration of a vintage computer" caption="Vintage computer" src="image_agent_tag_152458"/>

    ---

    ### What's Inside the Archive

    | Memorial | Category | Lifespan |
    | --- | --- | --- |
    | **Adobe Flash Player** | Culture & Platforms | 1996 - 2020 |
    | **Google Reader** | APIs & Feeds | 2005 - 2013 |
    | **Microsoft Zune HD** | Hardware, and a long description that should wrap onto a second line inside its cell | 2009 - 2011 |

    **Reviewer Fixes**

    - `src/app/layout.tsx`: wired up Geist
    - **Verification**: passed `npm run lint`

    1. First
    2. Second

    <ElicitationsGroup message="Where would you like to take it next?">
      <Elicitation label="Add a form" query="Add a form to bury new memorials"/>
      <Elicitation label="Expand the archive" query="Expand the archive with AIM and ICQ"/>
    </ElicitationsGroup>
    """

    func testParsesTheGeminiReply() {
        let blocks = MarkdownText.parse(Self.sample)
        let kinds = blocks.map { b -> String in
            switch b {
            case .heading: return "h"; case .paragraph: return "p"; case .bullets: return "ul"; case .numbered: return "ol"
            case .quote: return "q"; case .code: return "code"; case .table: return "table"; case .rule: return "hr"; case .suggestions: return "chips"
            }
        }
        XCTAssertEqual(kinds, ["p", "hr", "h", "table", "p", "ul", "ol", "chips"])
        guard case .table(let header, let rows) = blocks[3] else { return XCTFail() }
        XCTAssertEqual(header, ["Memorial", "Category", "Lifespan"])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1][0], "**Google Reader**")
        guard case .suggestions(let msg, let items) = blocks[7] else { return XCTFail() }
        XCTAssertEqual(msg, "Where would you like to take it next?")
        XCTAssertEqual(items.map(\.query), ["Add a form to bury new memorials", "Expand the archive with AIM and ICQ"])
        XCTAssertFalse(blocks.contains { if case .paragraph(let t) = $0 { return t.contains("<Image") } else { return false } })
    }

    func testRendersToAnImage() throws {
        let view = MarkdownText(text: Self.sample).frame(width: 760).padding(24).background(Theme.window).environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: view)
        r.scale = 2
        let img = try XCTUnwrap(r.nsImage)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: img.tiffRepresentation!))
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/anvil-markdown-render.png"))
        XCTAssertGreaterThan(img.size.height, 300)
    }
}

final class CompatTests: XCTestCase {
    /// A session saved before newer fields existed must still load (old sessions wouldn't open).
    func testOldSessionStillDecodes() throws {
        let json = """
        {"id": "8EB5D059-DD1C-4703-A364-EFA985B98E53", "title": "yo wassup", "created": "2026-11-21T01:00:00Z", "updated": "2026-11-21T01:01:00Z",
         "projectPath": "/tmp/lab", "allowedCommands": [], "briefing": "", "checkpoints": [], "messages": [{"role": "user", "text": "hi"}],
         "model": "gemini-auto", "todos": [], "usage": {"calls": 1, "prompt": 10, "completion": 2, "cached": 0, "cost": 0},
         "items": [{"id": "11111111-1111-1111-1111-111111111111", "kind": "user", "text": "yo wassup", "date": "2026-11-21T01:00:00Z", "final": false, "images": 0}]}
        """
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let s = try dec.decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(s.title, "yo wassup")
        XCTAssertEqual(s.items.first?.text, "yo wassup")
        XCTAssertFalse(s.items.first?.skillWorthy ?? true)
        XCTAssertNil(s.costLimit)
        // Round trip with the current format.
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let back = try dec.decode(Session.self, from: enc.encode(s))
        XCTAssertEqual(back.items.count, 1)
    }
}
