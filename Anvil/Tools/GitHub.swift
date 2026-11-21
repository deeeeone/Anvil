import Foundation

/// GitHub through the `gh` CLI (signed in with `gh auth login`): read issues, pull requests, review
/// comments and CI, open pull requests and comment. Anything that publishes asks first (see Permissions).
nonisolated enum GitHub {
    static var gh: String? { LSP.find("gh", root: Paths.home) }

    /// "owner/name" from a GitHub remote URL.
    static func repo(fromRemote url: String) -> String? {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = u.range(of: #"github\.com[:/]([^/\s]+)/([^/\s]+?)(\.git)?/?$"#, options: .regularExpression) else { return nil }
        let tail = u[r].replacingOccurrences(of: "github.com", with: "").trimmingCharacters(in: CharacterSet(charactersIn: ":/"))
        let parts = tail.split(separator: "/")
        guard parts.count == 2 else { return nil }
        var name = String(parts[1])
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        return "\(parts[0])/\(name)"
    }

    static func repo(_ root: URL) async -> String? {
        let r = await Git.run(["remote", "get-url", "origin"], in: root)
        return r.status == 0 ? repo(fromRemote: r.stdout) : nil
    }

    static func run(_ args: [String], in root: URL, timeout: Double = 60) async throws -> String {
        guard let gh else { throw ToolFailure("the GitHub CLI isn't installed: brew install gh, then gh auth login") }
        let r = await ProcessRunner.run(gh, args, cwd: root, timeout: timeout)
        if r.timedOut { throw ToolFailure("gh timed out") }
        if r.status != 0 {
            let msg = r.combined.trimmingCharacters(in: .whitespacesAndNewlines)
            if msg.contains("gh auth login") { throw ToolFailure("gh isn't signed in. The owner needs to run: gh auth login") }
            throw ToolFailure("gh \(args.prefix(2).joined(separator: " ")) failed: \(Fmt.line(msg, 600))")
        }
        return r.stdout
    }

    /// The task a labeled issue becomes in the queue.
    static func issuePrompt(number: Int, title: String, body: String, repo: String) -> String {
        """
        Resolve GitHub issue #\(number) in \(repo): \(title)

        \(Fmt.clip(body.isEmpty ? "(no description)" : body, max: 4000))

        Read the issue's comments with gh_issue first. Fix it, verify with the tests, then open a pull request with gh_pr_create \
        whose body says "Fixes #\(number)" and how you verified it.
        """
    }

    // MARK: Tools

    static func tools() -> [ToolSpec] {
        guard gh != nil else { return [] }
        let issue = ToolSpec(name: "gh_issue", kind: .network,
                             signature: #"{optional "number": int, optional "label": str, optional "state": "open"|"closed"|"all"}"#,
                             summary: "a GitHub issue with its comments, or (without number) the repo's issues",
                             group: .web) { a, ctx in
            if let n = a["number"]?.int {
                let raw = try await run(["issue", "view", "\(n)", "--json", "number,title,state,author,labels,body,comments,url"], in: ctx.root)
                return .ok(formatThread(JSON.parse(raw)))
            }
            var args = ["issue", "list", "--limit", "30", "--json", "number,title,labels,updatedAt", "--state", a["state"]?.string ?? "open"]
            if let l = a["label"]?.string, !l.isEmpty { args += ["--label", l] }
            let list = JSON.parse(try await run(args, in: ctx.root))?.array ?? []
            if list.isEmpty { return .ok("no issues") }
            return .ok(list.map { i in "#\(i["number"]?.int ?? 0) \(i["title"]?.string ?? "")\(labels(i))" }.joined(separator: "\n"))
        }

        let pr = ToolSpec(name: "gh_pr", kind: .network,
                          signature: #"{optional "number": int}"#,
                          summary: "a pull request (default: this branch's) with its description, reviews and inline review comments; without one, the open PRs",
                          group: .web) { a, ctx in
            let n = a["number"]?.int
            let fields = "number,title,state,author,body,url,headRefName,baseRefName,reviewDecision,mergeable,comments,reviews"
            let raw: String
            do { raw = try await run(["pr", "view"] + (n.map { ["\($0)"] } ?? []) + ["--json", fields], in: ctx.root) }
            catch let e as ToolFailure where n == nil && e.message.contains("no pull requests found") {
                let list = JSON.parse(try await run(["pr", "list", "--limit", "20", "--json", "number,title,headRefName"], in: ctx.root))?.array ?? []
                return .ok("this branch has no pull request. Open PRs:\n" + (list.isEmpty ? "(none)" : list.map { "#\($0["number"]?.int ?? 0) \($0["title"]?.string ?? "") [\($0["headRefName"]?.string ?? "")]" }.joined(separator: "\n")))
            }
            let j = JSON.parse(raw)
            var out = formatThread(j)
            out += "\nbranch: \(j?["headRefName"]?.string ?? "") → \(j?["baseRefName"]?.string ?? "")  review: \(j?["reviewDecision"]?.string ?? "none")  mergeable: \(j?["mergeable"]?.string ?? "?")"
            for r in j?["reviews"]?.array ?? [] where !(r["body"]?.string ?? "").isEmpty || r["state"]?.string == "CHANGES_REQUESTED" {
                out += "\nREVIEW by \(r["author"]?["login"]?.string ?? "?") [\(r["state"]?.string ?? "")]: \(Fmt.clip(r["body"]?.string ?? "", max: 1500))"
            }
            if let number = j?["number"]?.int,
               let inline = JSON.parse(try await run(["api", "repos/{owner}/{repo}/pulls/\(number)/comments", "--paginate"], in: ctx.root))?.array, !inline.isEmpty {
                out += "\nINLINE REVIEW COMMENTS:"
                for c in inline.prefix(40) {
                    let line = c["line"]?.int ?? c["original_line"]?.int ?? 0
                    out += "\n- \(c["path"]?.string ?? ""):\(line) \(c["user"]?["login"]?.string ?? "?"): \(Fmt.clip(c["body"]?.string ?? "", max: 800))"
                }
            }
            return .ok(out)
        }

        let checks = ToolSpec(name: "gh_checks", kind: .network,
                              signature: #"{optional "number": int}"#,
                              summary: "CI checks of a pull request (default: this branch's), with the failing jobs' log tails",
                              group: .web) { a, ctx in
            let target = a["number"]?.int.map { ["\($0)"] } ?? []
            guard let gh else { return .fail("gh isn't installed") }
            // `gh pr checks` exits non-zero when checks fail or are pending, so read the JSON regardless.
            let r = await ProcessRunner.run(gh, ["pr", "checks"] + target + ["--json", "name,state,bucket,link,workflow"], cwd: ctx.root, timeout: 60)
            guard let list = JSON.parse(r.stdout)?.array else { return .fail("gh pr checks: \(Fmt.line(r.combined, 400))") }
            if list.isEmpty { return .ok("no checks on this pull request") }
            var out = list.map { "- \($0["workflow"]?.string.map { $0 + " / " } ?? "")\($0["name"]?.string ?? ""): \($0["state"]?.string ?? "")" }.joined(separator: "\n")
            let failed = list.filter { $0["bucket"]?.string == "fail" }
            var seen = Set<String>()
            for f in failed.prefix(3) {
                guard let link = f["link"]?.string, let run = link.range(of: #"/runs/(\d+)"#, options: .regularExpression).map({ String(link[$0].dropFirst(6)) }),
                      seen.insert(run).inserted else { continue }
                let log = await ProcessRunner.run(gh, ["run", "view", run, "--log-failed"], cwd: ctx.root, timeout: 90)
                let tail = log.stdout.split(separator: "\n").suffix(120).joined(separator: "\n")
                if !tail.isEmpty { out += "\n\nFAILED LOG (run \(run), last lines):\n" + Fmt.clip(tail, max: 8000) }
            }
            let pending = list.filter { $0["bucket"]?.string == "pending" }.count
            if pending > 0 { out += "\n(\(pending) check(s) still running; call gh_checks again later)" }
            return .ok(out)
        }

        let create = ToolSpec(name: "gh_pr_create", kind: .exec,
                              signature: #"{"title": str, "body": str, optional "base": str, optional "draft": bool}"#,
                              summary: "push this branch and open a pull request (asks the owner first). Commit your work before calling it",
                              group: .web,
                              command: { a in "git push -u origin HEAD && gh pr create --title \(Fmt.line(a["title"]?.string ?? "", 80))" }) { a, ctx in
            guard let title = a["title"]?.string, !title.isEmpty else { return .fail("need a title") }
            let st = await Git.status(ctx.root)
            if !st.files.isEmpty { return .fail("commit your \(st.files.count) uncommitted change(s) first; a pull request only contains commits") }
            guard let branch = st.branch, !["main", "master"].contains(branch) else {
                return .fail("you're on \(st.branch ?? "a detached HEAD"); create a branch (git switch -c name) and commit there first")
            }
            let push = await Git.run(["push", "-u", "origin", "HEAD"], in: ctx.root, timeout: 120)
            if push.status != 0 { return .fail("git push failed: \(Fmt.line(push.combined, 500))") }
            var args = ["pr", "create", "--title", title, "--body", a["body"]?.string ?? ""]
            if let base = a["base"]?.string, !base.isEmpty { args += ["--base", base] }
            if a["draft"]?.bool == true { args.append("--draft") }
            let url = try await run(args, in: ctx.root, timeout: 90).trimmingCharacters(in: .whitespacesAndNewlines)
            return .ok("opened \(url)")
        }

        let comment = ToolSpec(name: "gh_comment", kind: .exec,
                               signature: #"{"number": int, "body": str}"#,
                               summary: "post a comment on an issue or pull request (asks the owner first)",
                               group: .web,
                               command: { a in "gh issue comment \(a["number"]?.int ?? 0)" }) { a, ctx in
            guard let n = a["number"]?.int, let body = a["body"]?.string, !body.isEmpty else { return .fail("need number and body") }
            let url = try await run(["issue", "comment", "\(n)", "--body", body], in: ctx.root).trimmingCharacters(in: .whitespacesAndNewlines)
            return .ok("commented: \(url)")
        }

        return [issue, pr, checks, create, comment]
    }

    private static func labels(_ j: JSON) -> String {
        let l = (j["labels"]?.array ?? []).compactMap { $0["name"]?.string }
        return l.isEmpty ? "" : " [\(l.joined(separator: ", "))]"
    }

    /// Title, state, body and comments of an issue or pull request.
    static func formatThread(_ j: JSON?) -> String {
        guard let j else { return "(no data)" }
        var out = "#\(j["number"]?.int ?? 0) \(j["title"]?.string ?? "") [\(j["state"]?.string ?? "")] by \(j["author"]?["login"]?.string ?? "?")\(labels(j))"
        if let u = j["url"]?.string { out += "\n\(u)" }
        out += "\n\n" + Fmt.clip(j["body"]?.string ?? "", max: 6000)
        let comments = j["comments"]?.array ?? []
        if !comments.isEmpty {
            out += "\n\nCOMMENTS:"
            for c in comments.suffix(30) {
                out += "\n- \(c["author"]?["login"]?.string ?? "?"): \(Fmt.clip(c["body"]?.string ?? "", max: 1500))"
            }
        }
        return out
    }
}
