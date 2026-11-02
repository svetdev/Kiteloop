import Foundation

/// The stage between green checks and the human gate: reads the unresolved
/// review threads on the pull request `PullRequestPublisher` opened, and either
/// fixes each one or answers it — so the human is summoned to a pull request
/// whose threads have all been addressed rather than to a list of bot comments
/// somebody has to triage before they can start reviewing.
///
/// A code-review bot's comment is usually mechanical, and a run that walks away
/// from it puts the human back below the gate ADR-0001 placed them above: the
/// first thing they do is what the worker could have done unattended. So one
/// pass runs, and only one.
///
/// Four properties are load-bearing and are enforced here rather than left to
/// the caller:
///
/// * **Exactly one pass.** There is no loop. Every thread is handed to the
///   worker once, together; comments that arrive after the pass wait for the
///   human. A second pass would race the bots that are still commenting, and an
///   unattended run must not spend an item's cap chasing them.
/// * **A "fixed" claim over an unchanged tree is not honoured.** `actionable`
///   drops every `.fixed` disposition when the pass committed nothing — a thread
///   is only resolved off the back of a commit that exists. Posting "fixed in
///   the latest push" onto a branch that did not move is a false statement made
///   on the run's behalf, on a PR a human is about to read.
/// * **The item's prohibitions bind over the bot's suggestion.** A comment
///   asking for something the item put out of scope is declined with the item
///   cited, not built. `prompt` puts the Out of Scope list in front of the
///   worker for exactly that reason; the reviewer rubric already treats an
///   item's prohibitions as binding, and a robot reviewer does not outrank them.
/// * **A declined thread stays open.** Only a fix resolves a thread. Resolving
///   one the run argued with would hide the argument from the person the
///   argument is for.
///
/// The decisions — how `gh`'s GraphQL reads, what the worker is asked, which
/// dispositions are acted on, what the item's Notes say — are pure statics, so
/// they can be checked without a network, a repository or a GitHub account.
package enum PullRequestComments {

    // MARK: - What is being addressed

    /// One comment in a review thread.
    package struct Comment: Equatable, Sendable {
        package let author: String
        package let body: String
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(author: String, body: String) {
            self.author = author
            self.body = body
        }
    }

    /// One review thread on the pull request — the unit a reply is posted to and
    /// the unit that gets resolved.
    package struct Thread: Equatable, Sendable {
        /// The GraphQL node id. Both mutations are addressed to it, and it is
        /// what the worker names a disposition by.
        package let id: String
        /// The file the thread hangs off, empty for a thread with no path.
        package let path: String
        /// Nil for a file-level thread, or one whose line no longer exists.
        package let line: Int?
        package let isResolved: Bool
        /// The thread's code has changed since it was written. Kept rather than
        /// filtered: an outdated thread can still be right, and the worker is
        /// told so it can weigh it.
        package let isOutdated: Bool
        package let comments: [Comment]

        /// Who opened the thread — the bot or person whose comment this is.
        package var author: String { comments.first?.author ?? "someone" }

        /// `path:line`, or just the path, or nothing to say.
        package var location: String {
            guard !path.isEmpty else { return "" }
            guard let line else { return path }
            return "\(path):\(line)"
        }
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(id: String, path: String, line: Int?, isResolved: Bool, isOutdated: Bool, comments: [Comment]) {
            self.id = id
            self.path = path
            self.line = line
            self.isResolved = isResolved
            self.isOutdated = isOutdated
            self.comments = comments
        }
    }

    /// What the worker decided about one thread.
    package enum Action: String, Sendable {
        /// Changed on the branch. The run resolves the thread after the push.
        case fixed
        /// Argued with. The run posts the reply and leaves the thread open.
        case declined
    }

    package struct Disposition: Equatable, Sendable {
        package let threadID: String
        package let action: Action
        /// What gets posted on the thread. May be empty for a fix — the commit
        /// speaks for itself — but never for a decline, which is the whole point
        /// of declining out loud.
        package let reply: String
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(threadID: String, action: Action, reply: String) {
            self.threadID = threadID
            self.action = action
            self.reply = reply
        }
    }

    /// How the pass ended. Every case is terminal; there is no waiting state,
    /// because there is no second pass to wait for.
    package enum Outcome: Equatable, Sendable {
        /// `left` is threads the pass did not settle either way — ones the
        /// worker said nothing about, and ones it claimed to have fixed without
        /// committing anything.
        case addressed(fixed: Int, answered: Int, left: Int)
        /// The pull request had no unresolved threads. The ordinary case, and
        /// not a skip: nothing went wrong.
        case nothingToAddress
        /// The pass could not run, or could not finish. Carries the sentence the
        /// item's Notes get.
        case skipped(reason: String)
    }

    /// Where the thread list is read from.
    package enum Listing: Equatable, Sendable {
        case threads([Thread])
        case unavailable(reason: String)
    }

    /// How many threads one pass will carry. A pull request annotated by a
    /// linter can have hundreds, and past this the prompt is bigger than the
    /// diff it is about — the rest wait for the human, which `note` says out
    /// loud rather than leaving the tally to imply the PR was cleared.
    package static let maxThreads = 20

    /// How much of one comment the worker is handed. Enough for a bot's
    /// suggestion and the code block under it.
    package static let commentBodyLimit = 1_500

    /// How many comments deep into a thread the pass reads. A thread this long
    /// is a conversation, and its head is what the run is answering.
    package static let maxCommentsPerThread = 10

    /// The key the dispositions ride on, in the worker's declared output schema
    /// and in the workflow state the pass reads back.
    package static let outputKey = "dispositions"

    // MARK: - Reading what `gh` said

    /// The repository coordinates in a pull request URL, which is what the
    /// GraphQL query is parameterised by. Nil for anything that isn't one —
    /// there is nothing to ask GitHub about.
    package struct Repository: Equatable, Sendable {
        package let owner: String
        package let name: String
        package let number: Int
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(owner: String, name: String, number: Int) {
            self.owner = owner
            self.name = name
            self.number = number
        }
    }

    package static func repository(fromURL url: String) -> Repository? {
        let pattern = #"://[^/]+/([^/\s]+)/([^/\s]+)/pull/(\d+)"#
        guard let match = url.range(of: pattern, options: .regularExpression) else { return nil }
        let parts = url[match].split(separator: "/")
        // "", "<host>", "<owner>", "<repo>", "pull", "<number>" — the leading
        // "://" contributes one empty field, which `split` drops.
        guard parts.count >= 5, let number = Int(parts[parts.count - 1]) else { return nil }
        return Repository(owner: String(parts[parts.count - 4]),
                          name: String(parts[parts.count - 3]),
                          number: number)
    }

    /// The one query the pass makes. `first: 100` rather than pagination: a pull
    /// request with more than a hundred threads is past `maxThreads` many times
    /// over, and the pass is bounded either way.
    package static let threadsQuery = """
    query($owner:String!,$repo:String!,$number:Int!){\
    repository(owner:$owner,name:$repo){\
    pullRequest(number:$number){\
    reviewThreads(first:100){nodes{\
    id path line isResolved isOutdated \
    comments(first:20){nodes{body author{login}}}\
    }}}}}
    """

    /// The threads in a `gh api graphql` transcript, or nil when there is no
    /// readable answer in it.
    ///
    /// Every balanced `{…}` slice is tried, not the first and not the whole
    /// output: `gh` merges stderr into the same capture, so its upgrade notice
    /// routinely sits below the JSON and a slice running to end-of-output would
    /// hand `JSONSerialization` a line it can only reject — the same trap
    /// `PullRequestChecks.checks(inJSON:)` was written around.
    package static func threads(inJSON output: String) -> [Thread]? {
        for slice in StructuredOutputExtractor.balancedSlices(in: output, open: "{", close: "}") {
            guard let data = slice.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let nodes = threadNodes(in: root)
            else { continue }
            return nodes.compactMap(thread(from:))
        }
        return nil
    }

    private static func threadNodes(in root: [String: Any]) -> [[String: Any]]? {
        guard let data = root["data"] as? [String: Any],
              let repository = data["repository"] as? [String: Any],
              let pullRequest = repository["pullRequest"] as? [String: Any],
              let threads = pullRequest["reviewThreads"] as? [String: Any],
              let nodes = threads["nodes"] as? [[String: Any]]
        else { return nil }
        return nodes
    }

    private static func thread(from node: [String: Any]) -> Thread? {
        guard let id = node["id"] as? String, !id.isEmpty else { return nil }
        let comments = ((node["comments"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? [])
            .compactMap(comment(from:))
            .prefix(maxCommentsPerThread)
        return Thread(
            id: id,
            path: (node["path"] as? String) ?? "",
            line: node["line"] as? Int,
            isResolved: (node["isResolved"] as? Bool) ?? false,
            isOutdated: (node["isOutdated"] as? Bool) ?? false,
            comments: Array(comments)
        )
    }

    private static func comment(from node: [String: Any]) -> Comment? {
        let body = ((node["body"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        // A comment by a deleted account has a null author; it still says
        // something, and dropping it would leave the thread looking empty.
        let login = ((node["author"] as? [String: Any])?["login"] as? String) ?? "someone"
        return Comment(author: login, body: clip(body, limit: commentBodyLimit))
    }

    /// The threads a pass would act on: unresolved, and no more than
    /// `maxThreads` of them. A resolved thread has already been settled — by a
    /// human, by an earlier pass, or by the bot itself — and re-answering it
    /// would argue with a conversation that is over.
    package static func actionableThreads(in threads: [Thread], limit: Int = maxThreads) -> [Thread] {
        Array(threads.filter { !$0.isResolved }.prefix(limit))
    }

    /// What one `gh api graphql` invocation for the thread list means.
    package static func listing(exitStatus: Int32, output: String) -> Listing {
        if let failure = failure(exitStatus: exitStatus, output: output) {
            return .unavailable(reason: failure)
        }
        guard let threads = threads(inJSON: output) else {
            return .unavailable(reason: "gh api graphql printed no review threads")
        }
        return .threads(threads)
    }

    /// Why a `gh api graphql` call did not take effect, or nil when it did.
    ///
    /// The GraphQL errors are read *before* the exit status, and not only when
    /// it is non-zero: an API that answers `{"data": …, "errors": […]}` has
    /// refused part of the request while telling `gh` nothing is wrong, and a
    /// resolve that was rejected for permissions must not be counted as a thread
    /// this run settled.
    package static func failure(exitStatus: Int32, output: String) -> String? {
        if let message = graphQLError(inJSON: output) { return message }
        guard exitStatus != 0 else { return nil }
        return "gh api graphql failed" + PullRequestPublisher.failureDetail(output)
    }

    /// The first message in a GraphQL `errors` array, if the output carries one.
    package static func graphQLError(inJSON output: String) -> String? {
        for slice in StructuredOutputExtractor.balancedSlices(in: output, open: "{", close: "}") {
            guard let data = slice.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let errors = root["errors"] as? [[String: Any]]
            else { continue }
            let message = errors.compactMap { $0["message"] as? String }
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return message.map { clip($0, limit: 200) } ?? "gh api graphql returned an error"
        }
        return nil
    }

    // MARK: - What the worker is asked

    /// The verdict the pass reads back. One field: a disposition per thread.
    package static let outputSchema = OutputSchema(fields: [
        outputKey: .init(
            type: "array",
            required: true,
            description: "One entry per thread, each "
                       + "{thread: \"<id>\", action: \"fixed\"|\"declined\", reply: \"<text>\"}"),
    ])

    /// The prompt the one pass hands the worker.
    ///
    /// Deliberately narrow in the same way `PullRequestChecks.fixPrompt` is: the
    /// diff on this branch has been reviewed and approved, so a change beyond
    /// what a comment asks for is unreviewed work. Narrower in one more way — the
    /// item's own Out of Scope list is quoted, because the thing this pass exists
    /// to do is act on someone else's suggestions, and the item is what says
    /// which of them are not this item's to take.
    package static func prompt(
        item: BacklogItem,
        detail: BacklogItemDetail?,
        branch: String,
        url: String,
        threads: [Thread],
        buildOutputNote: String?
    ) -> String {
        var parts = ["""
        The pull request for `\(item.id)` — \(item.title) — has \
        \(count(threads.count, "unresolved review thread")) on it. Its checks are green; \
        addressing these is the last thing between this work and the person who will \
        approve it.

        Pull request: \(url)
        Branch: \(branch)
        """]

        let outOfScope = (detail?.outOfScope ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !outOfScope.isEmpty {
            parts.append("""
            ## What this item put out of scope

            \(outOfScope.map { "- \($0)" }.joined(separator: "\n"))

            These bind. A comment asking for one of them gets a `declined` reply that \
            says so and cites the item — a reviewer, robot or otherwise, does not widen \
            an item's scope.
            """)
        }

        parts.append("## The threads\n\n" + threads.enumerated()
            .map { renderThread($0.element, number: $0.offset + 1) }
            .joined(separator: "\n\n"))

        if let buildOutputNote, !buildOutputNote.isEmpty {
            parts.append("## Build Output\n\n\(buildOutputNote)")
        }

        parts.append("""
        ## What to do

        You are in a git worktree checked out on `\(branch)` — the branch this pull \
        request is built from. Read every thread above and settle each one exactly once:

        - **Fix it.** Make the change and commit it. Keep it to what the comment asks \
        for: the rest of this branch has already been reviewed, so an unrelated edit \
        is unreviewed work riding in on a bot's suggestion.
        - **Decline it.** Say why, plainly and specifically — it contradicts the item, \
        it is wrong about the code, it belongs in its own backlog item. A reasoned no \
        is a complete answer; agreeing with everything is not the goal.

        Do not reply on GitHub and do not resolve anything yourself — the run posts \
        your replies and resolves the threads you fixed, once it has pushed your \
        commits. This is the only pass: comments that arrive after it wait for a human, \
        so there is no second round to defer a thread to.

        ## How to answer

        Reply with a JSON object carrying a `\(outputKey)` array — one entry per thread, \
        using the thread ids exactly as written above:

        ```json
        {"\(outputKey)": [
          {"thread": "<id>", "action": "fixed", "reply": "Good catch — fixed in the latest push."},
          {"thread": "<id>", "action": "declined", "reply": "This item explicitly puts X out of scope, so I've left it; worth its own item."}
        ]}
        ```

        Every entry needs a reply a human will read on the pull request. A `declined` \
        entry without one is the failure this pass exists to avoid: a thread nobody \
        answered, which is what it already was.
        """)
        return parts.joined(separator: "\n\n")
    }

    private static func renderThread(_ thread: Thread, number: Int) -> String {
        var header = "### Thread \(number) — `\(thread.id)`"
        if !thread.location.isEmpty { header += "\n\n\(thread.location)" }
        if thread.isOutdated {
            header += (thread.location.isEmpty ? "\n\n" : " — ")
                    + "the code this was written about has changed since"
        }
        let body = thread.comments
            .map { "**\($0.author)**\n\n\($0.body)" }
            .joined(separator: "\n\n")
        return body.isEmpty ? header : "\(header)\n\n\(body)"
    }

    // MARK: - Reading the worker back

    /// The dispositions in the pass's output, keyed to the threads it was given.
    ///
    /// Lenient in the same direction as `ReviewFindings`, and for the same
    /// reason — an unreadable answer costs the whole pass — but not lenient
    /// about *which* thread: an entry naming an id that wasn't on the list is
    /// dropped rather than guessed at, because acting on it would post a comment
    /// onto a thread nobody read. A repeated id keeps its first entry, so a
    /// worker that changed its mind mid-answer cannot have a thread both
    /// resolved and argued with.
    package static func dispositions(in output: [String: AnyCodable], threads: [Thread]) -> [Disposition] {
        guard let raw = output[outputKey]?.stringValue,
              let data = raw.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return [] }

        let known = Set(threads.map(\.id))
        var seen = Set<String>()
        return array.compactMap { element -> Disposition? in
            guard let object = element as? [String: Any] else { return nil }
            let id = ((object["thread"] as? String) ?? (object["threadId"] as? String)
                      ?? (object["id"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard known.contains(id), seen.insert(id).inserted else { return nil }
            let reply = ((object["reply"] as? String) ?? (object["body"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Disposition(threadID: id, action: action(from: object, reply: reply), reply: reply)
        }
    }

    /// Which way a disposition goes. Unknown wording reads as `declined`: the
    /// two are not symmetric, since `fixed` resolves a thread and closes the
    /// conversation while `declined` posts the words and leaves it open for the
    /// human. Guessing wrong in the `declined` direction costs an open thread;
    /// guessing wrong in the other direction hides one.
    private static func action(from object: [String: Any], reply: String) -> Action {
        let raw = ((object["action"] as? String) ?? (object["status"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch raw {
        case "fixed", "fix", "fixed-and-resolved", "resolved", "done", "addressed":
            return .fixed
        default:
            return .declined
        }
    }

    /// The dispositions the run will actually act on.
    ///
    /// A `.fixed` claim is dropped whole — reply and all — when the pass
    /// committed nothing. It cannot be true: there is no commit for it to be
    /// true of. Posting its reply anyway would put "fixed in the latest push"
    /// on a thread over a branch that did not move, which is a lie told on the
    /// run's behalf to the person the pull request is for. The thread stays open
    /// and silent, and `outcome` counts it among the ones left for the human.
    ///
    /// A `.declined` entry with nothing to say is dropped for the mirror reason:
    /// there is nothing to post, and resolving is not on the table, so acting on
    /// it would be a no-op recorded as an answer.
    package static func actionable(_ dispositions: [Disposition], committed: Bool) -> [Disposition] {
        dispositions.filter { disposition in
            switch disposition.action {
            case .fixed: return committed
            case .declined: return !disposition.reply.isEmpty
            }
        }
    }

    /// The tally, counted off what the run actually did rather than off what the
    /// worker said it would do — `acted` is the dispositions whose replies
    /// posted and whose resolves took.
    package static func outcome(threads: Int, acted: [Disposition]) -> Outcome {
        guard threads > 0 else { return .nothingToAddress }
        let fixed = acted.filter { $0.action == .fixed }.count
        let answered = acted.filter { $0.action == .declined }.count
        return .addressed(fixed: fixed, answered: answered,
                          left: max(0, threads - fixed - answered))
    }

    // MARK: - What the Notes and the human are told

    /// The line the item's Notes and the run log both get, alongside the pull
    /// request's own note and its checks'. One phrasing for both so the log and
    /// the backlog can't come to disagree about how the threads were left.
    package static func note(for outcome: Outcome) -> String {
        switch outcome {
        case .nothingToAddress:
            return "Pull request had no unresolved review comments"
        case .addressed(let fixed, let answered, let left):
            let tally = "Pull request review comments: \(fixed) fixed, \(answered) answered"
            return left > 0 ? tally + ", \(left) left for the gate" : tally
        case .skipped(let reason):
            return "Pull request review comments not addressed — \(reason)"
        }
    }

    /// The clause appended to the approval-gate notification, so the human being
    /// summoned learns what state the threads are in. Nil when there is nothing
    /// to add — a pull request nobody commented on is not news.
    package static func gateDetail(for outcome: Outcome) -> String? {
        switch outcome {
        case .nothingToAddress:
            return nil
        case .addressed(let fixed, let answered, let left):
            let tally = "PR comments: \(fixed) fixed, \(answered) answered"
            return left > 0 ? tally + ", \(left) open" : tally
        case .skipped:
            return "PR comments not addressed"
        }
    }

    /// The one word a phase line calls a terminal state, so a night's runs can be
    /// counted by grepping for it.
    package static func outcomeName(_ outcome: Outcome) -> String {
        switch outcome {
        case .addressed: return "addressed"
        case .nothingToAddress: return "none"
        case .skipped: return "skipped"
        }
    }

    /// The head of a comment — a bot puts its point first and its boilerplate
    /// after it, which is the opposite of a CI log and why this clips the other
    /// way from `PullRequestChecks.clip`.
    package static func clip(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    // MARK: - Talking to GitHub

    /// The unresolved review threads on the pull request, asked of `gh`. Runs off
    /// the calling actor — it is a subprocess talking to a network.
    package static func list(pullRequest url: String, in projectRoot: URL) async -> Listing {
        guard let repository = repository(fromURL: url) else {
            return .unavailable(reason: "\(url) is not a pull request URL")
        }
        return await Task.detached(priority: .userInitiated) {
            guard let gh = PullRequestPublisher.resolveGH() else {
                return Listing.unavailable(reason: "the GitHub CLI (gh) is not installed")
            }
            let result = PullRequestPublisher.run(gh, [
                "api", "graphql",
                "-f", "query=\(threadsQuery)",
                "-F", "owner=\(repository.owner)",
                "-F", "repo=\(repository.name)",
                "-F", "number=\(repository.number)",
            ], in: projectRoot)
            return listing(exitStatus: result.status, output: result.output)
        }.value
    }

    package static let replyMutation = """
    mutation($thread:ID!,$body:String!){\
    addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$thread,body:$body}){\
    comment{id}}}
    """

    package static let resolveMutation = """
    mutation($thread:ID!){resolveReviewThread(input:{threadId:$thread}){thread{isResolved}}}
    """

    /// Posts a reply on a thread. Nil on success, else why it failed.
    package static func reply(threadID: String, body: String, in projectRoot: URL) async -> String? {
        await mutate(["-f", "query=\(replyMutation)",
                      "-f", "thread=\(threadID)",
                      "-f", "body=\(body)"], in: projectRoot)
    }

    /// Marks a thread resolved. Nil on success, else why it failed.
    package static func resolve(threadID: String, in projectRoot: URL) async -> String? {
        await mutate(["-f", "query=\(resolveMutation)",
                      "-f", "thread=\(threadID)"], in: projectRoot)
    }

    private static func mutate(_ arguments: [String], in projectRoot: URL) async -> String? {
        await Task.detached(priority: .userInitiated) {
            guard let gh = PullRequestPublisher.resolveGH() else {
                return "the GitHub CLI (gh) is not installed"
            }
            let result = PullRequestPublisher.run(gh, ["api", "graphql"] + arguments, in: projectRoot)
            return failure(exitStatus: result.status, output: result.output)
        }.value
    }
}
