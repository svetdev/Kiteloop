import Foundation

/// What one role was sent before it had done anything — the opening context of a
/// run, measured rather than estimated.
///
/// Every autopilot run starts by loading the same three things: the project's
/// CLAUDE.md autonomy rules, the agent's knowledge package, and the schemas of
/// the tools the FIFO bridge offers. That is paid twice per item — once by the
/// worker, once by the reviewer — hundreds of times a week, and until this
/// existed no number said what it came to. Whether it was 3k tokens or 40k was
/// not answerable, which made it the largest unexamined lever on what a night
/// costs. `docs/opening-context.md` decomposes the measured figure by component.
///
/// **This is the first model call, not the first turn span.** A `.turn` span
/// covers a whole prompt leg — up to fifty model calls with every tool result
/// folded into its counters — so the leg's own `TokenUsage` cannot answer this
/// question: a worker leg that reads twenty files reports those files in the
/// same number as the rules it opened with. The CLI states the per-call figure
/// once, on the first `assistant` line of the leg, and that is what is captured
/// here (`StreamEvent.assistantUsage`).
struct OpeningContext: Codable, Sendable, Equatable {
    /// Prompt tokens billed at full price — the uncached remainder only.
    var inputTokens: Int
    /// Prompt tokens written to the cache by this call. On a cold session this
    /// is most of the opening context: it is being cached for the first time.
    var cacheCreationTokens: Int
    /// Prompt tokens the call was served from cache. On a warm session this is
    /// most of the opening context — the same content, already paid for.
    var cacheReadTokens: Int

    init(inputTokens: Int = 0, cacheCreationTokens: Int = 0, cacheReadTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
    }

    /// The three input counters of a call's usage. `outputTokens` is dropped:
    /// what the agent said back is not context it was given.
    init(_ usage: TokenUsage) {
        self.init(
            inputTokens: usage.inputTokens,
            cacheCreationTokens: usage.cacheCreationTokens,
            cacheReadTokens: usage.cacheReadTokens
        )
    }

    /// **How big the opening context is** — everything the first call was sent,
    /// cached or not. The figure to compare against a slimming target, because
    /// it does not move when the cache happens to be warm.
    var promptTokens: Int { inputTokens + cacheCreationTokens + cacheReadTokens }

    /// **What it cost to send at full price** — the uncached remainder plus what
    /// this call wrote to the cache. Kept beside `promptTokens` rather than
    /// instead of it: the two diverge by an order of magnitude between a cold
    /// session and a warm one, and reading either as the other is the mistake
    /// this pair exists to prevent.
    var billedTokens: Int { inputTokens + cacheCreationTokens }

    /// Nothing was counted. Distinguished from nil by callers the same way
    /// `TokenUsage` does: nil is "no call reported it", this is "it reported
    /// zeroes", and neither is a context of zero tokens worth recording.
    var isEmpty: Bool { promptTokens == 0 }

    /// The opening context of each role in one run, taken from the earliest turn
    /// that role recorded one.
    ///
    /// `turns` is expected to be already scoped to the run — this reads whatever
    /// it is given. A role whose turns carry no opening call gets **no entry**
    /// rather than a zero: spans written before this was captured, and every
    /// non-Claude runtime, are in that state, and a 0 there would read as a role
    /// that was sent nothing.
    static func byRole(_ turns: [TraceSpan]) -> [String: OpeningContext] {
        var earliest: [String: TraceSpan] = [:]
        for turn in turns where turn.openingContext != nil {
            let role = turn.metadata[TraceSpan.MetadataKey.role] ?? "unknown"
            if let held = earliest[role], held.startTime <= turn.startTime { continue }
            earliest[role] = turn
        }
        return earliest.compactMapValues(\.openingContext)
    }
}

/// What the opening context of one role costs across a set of runs — the shape
/// the question is actually asked in, since a single run says nothing about
/// whether 60k is normal.
///
/// p50 and p90 rather than a mean: the distribution has a long tail (a resumed
/// session carries the previous item's conversation into its first call), and a
/// mean over that reports a number no run ever had.
struct OpeningContextStats: Sendable, Equatable {
    /// A measured spread, rounded to whole tokens — the unit the figure is
    /// billed in, and finer precision would be false.
    struct Spread: Sendable, Equatable {
        let p50: Int
        let p90: Int
    }

    /// The workflow node — `worker`, `reviewer`, …
    let role: String
    /// Runs that recorded an opening context for this role. The ones that did
    /// not are absent from the sample rather than counted as zero, so a small
    /// number here means "few runs measured", not "few runs happened".
    let runs: Int
    /// How big the opening context was.
    let prompt: Spread
    /// What it cost at full price.
    let billed: Spread

    /// p50/p90 per role over `records`, busiest role first.
    ///
    /// Records carrying no opening context contribute nothing — including every
    /// record written before it was captured, which is why the `runs` count is
    /// reported beside the percentiles rather than left to be inferred from the
    /// number of records the caller passed in.
    static func byRole(_ records: [TaskMetricRecord]) -> [OpeningContextStats] {
        var samples: [String: [OpeningContext]] = [:]
        for record in records {
            for (role, context) in record.openingContext ?? [:] where !context.isEmpty {
                samples[role, default: []].append(context)
            }
        }
        return samples.map { role, contexts in
            OpeningContextStats(
                role: role,
                runs: contexts.count,
                prompt: spread(of: contexts.map(\.promptTokens)),
                billed: spread(of: contexts.map(\.billedTokens))
            )
        }
        .sorted { $0.runs == $1.runs ? $0.role < $1.role : $0.runs > $1.runs }
    }

    /// The same interpolation rule `SizeCalibration` reports its bands with, so
    /// two percentiles in one API answer are not computed two different ways.
    private static func spread(of values: [Int]) -> Spread {
        let sorted = values.map(Double.init).sorted()
        return Spread(
            p50: Int(SizeCalibration.percentile(sorted, 0.50).rounded()),
            p90: Int(SizeCalibration.percentile(sorted, 0.90).rounded())
        )
    }
}
