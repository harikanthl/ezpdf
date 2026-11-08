//
//  AgentLoop.swift
//  OperatorLLM
//
//  THE LOOP — lifted in shape from Hermes Agent's `agent/conversation_loop.py` (NousResearch, read
//  2026-09-04), which is four lines of idea under thirty files of phases:
//
//  ```python
//  while api_call_count < self.max_iterations and self.iteration_budget.remaining > 0 \
//          or self._budget_grace_call:
//      response = client.chat.completions.create(...)
//      if response.tool_calls:
//          for tc in response.tool_calls:
//              messages.append(tool_result_message(handle_function_call(...)))
//  ```
//
//  That is the whole difference between a chat and an agent: a chat sends once and renders what comes
//  back; an agent sends, and when the answer is "call this first", it calls it, appends the result as
//  a `tool` message, and sends again. Everything else Hermes has — 28 toolsets, plugins, subagents —
//  is breadth hung off this.
//
//  THREE THINGS TAKEN DELIBERATELY, each of which is a bug if you skip it:
//
//    • **The assistant's tool-call turn goes back into the transcript.** Not just the results. A
//      provider rejects `tool` messages that answer a call it cannot see, and the model loses the
//      thread of what it asked.
//    • **A bounded budget, and a GRACE CALL when it runs out.** Hermes allows one final call past the
//      budget; ours makes that call with NO tools attached, so the model cannot ask for a thirteenth
//      thing and must answer with what it has. A loop that simply stops leaves the person with a
//      spinner and no words.
//    • **Every result is a string, always.** Hermes: "all handlers return a JSON string". A handler
//      that throws, or refuses, or finds nothing still answers — the model reads the refusal and
//      moves on, where a missing result stalls the turn.
//
//  ‼️ NOT TAKEN: Hermes's `max_iterations` default of 500. That is right for a terminal agent working
//  unattended for an hour and wrong for someone holding a phone: the cap here is small, and the loop
//  is a conversation's assistant, not a background worker. Long autonomous work is what a SESSION is
//  for, and reaching for one is a card the person taps.
//
//  `@MainActor` because every caller is: the model that drives it, the stores its tools read, and the
//  view that renders the text. The awaits inside are network and file I/O that suspend rather than
//  block, which is exactly what the actor is for.
//

import Foundation

@MainActor
public enum AgentLoop {

    /// One round trip to the model. Given the transcript so far and the tools on offer, it streams
    /// back text, tool calls, or both. The caller supplies this so the loop stays testable without a
    /// network and works against any client.
    public typealias Round = ([LLMMessage], [LLMToolSpec]) -> AsyncThrowingStream<LLMStreamEvent, Error>

    /// Run one tool and return its result as a string the model will read. Never throws: a refusal is
    /// an answer (see the header).
    public typealias Execute = (LLMToolCall) async -> String
    /// Like `Execute`, for tools that can hand back images too (rendered frames). The images ride the
    /// tool's result message; each client puts them where its API allows.
    public typealias ExecuteOutput = (LLMToolCall) async -> LLMToolOutput
    /// Whether a call may run alongside the others the model made in the same turn
    /// (docs/OSS_LIFT_2026-09.md L1/L2). Reads are; anything that puts a card up, sends, or writes
    /// is not. FAIL-CLOSED: the default says no to everything, and a caller opts tools in by name.
    /// A call the classifier refuses still runs, in order, the regular way.
    public typealias ParallelSafe = (LLMToolCall) -> Bool

    /// What happened, for the caller's own bookkeeping and for tests.
    public struct Outcome: Sendable, Equatable {
        /// How many round trips were made, including the grace call.
        public var rounds: Int
        /// Every tool the model actually called, in order.
        public var called: [String]
        /// True when the budget ran out and the grace call was what produced the answer.
        public var hitBudget: Bool
        /// The transcript the loop grew — the assistant's tool-call turns and the results. Appending
        /// this to a persisted history is what lets a later turn see what was looked up.
        public var appended: [LLMMessage]
        /// Token spend summed over every round, on routes that report it. Cache reads are the part
        /// of the prompt that was served at the discount.
        public var usage: Usage?
    }

    /// The default budget: enough for a model to look something up, look at a second thing because
    /// the first pointed at it, and then answer. Past that it is usually looping, and a person
    /// watching a chat bubble has been waiting too long already.
    public static let defaultMaxRounds = 4
    /// How many parallel-safe calls run at once. ToolRush's tested bound; past it the wins flatten
    /// and a phone's radio is the limit anyway.
    public static let maxParallel = 4

    /// Drive the loop until the model answers in prose, or the budget runs out.
    ///
    /// - Parameters:
    ///   - onText: every token, as it arrives, so a caller renders while the model talks.
    ///   - onToolCall: fires before each tool runs, for a "looking at network-report.md…" line. The
    ///     person should never watch a silent spinner while three tools run.
    @discardableResult
    public static func run(messages: [LLMMessage],
                           tools: [LLMToolSpec],
                           maxRounds: Int = defaultMaxRounds,
                           round: Round,
                           execute: @escaping Execute,
                           parallelSafe: ParallelSafe = { _ in false },
                           onText: (String) -> Void = { _ in },
                           onToolCall: (LLMToolCall) -> Void = { _ in }) async throws -> Outcome {
        try await run(messages: messages, tools: tools, maxRounds: maxRounds, round: round,
                      executeOutput: { LLMToolOutput(await execute($0)) },
                      parallelSafe: parallelSafe, onText: onText, onToolCall: onToolCall)
    }

    /// The loop with tools that may return images. `outOfBudget` is checked before each round past the
    /// first: when it says yes (a time or tool-call budget the caller keeps), the loop goes straight to
    /// the grace call, as if the rounds had run out.
    ///
    /// `steer` is read before every round: what the person typed while the loop worked ("make it shorter"),
    /// added as user messages so the next step follows it without starting over. If notes arrive while the model
    /// was answering, it gets one more round to take them in rather than finishing on the old request.
    @discardableResult
    public static func run(messages: [LLMMessage],
                           tools: [LLMToolSpec],
                           maxRounds: Int = defaultMaxRounds,
                           round: Round,
                           executeOutput: @escaping ExecuteOutput,
                           parallelSafe: ParallelSafe = { _ in false },
                           outOfBudget: () -> Bool = { false },
                           steer: () -> [String] = { [] },
                           onText: (String) -> Void = { _ in },
                           onToolCall: (LLMToolCall) -> Void = { _ in },
                           onAppended: (LLMMessage) -> Void = { _ in }) async throws -> Outcome {
        let execute = executeOutput
        var transcript = messages
        // Every message the loop adds also goes to `onAppended` as it happens, so a caller whose run
        // fails part way (network, provider error) still knows which tool calls already ran.
        var appended: [LLMMessage] = [] {
            didSet { if appended.count > oldValue.count { for m in appended[oldValue.count...] { onAppended(m) } } }
        }
        var called: [String] = []
        var rounds = 0
        var spent: Usage?
        // What the person typed mid-run, as user turns. True when there was something.
        func takeSteering() -> Bool {
            let notes = steer().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            for note in notes {
                let message = LLMMessage(.user, note)
                transcript.append(message)
                appended.append(message)
            }
            return !notes.isEmpty
        }

        while rounds < max(1, maxRounds), rounds == 0 || !outOfBudget() {
            // A cancelled stream ends quietly rather than throwing; don't take that as an answer.
            try Task.checkCancellation()
            rounds += 1
            _ = takeSteering()
            let turn = try await one(round(transcript, tools), onText: onText)
            try Task.checkCancellation()
            spent = add(spent, turn.usage)
            // No calls ⇒ it answered. The common case, and the one a plain chat has always taken. Unless the
            // person added something while it answered: then the answer stands and the loop goes round again.
            guard !turn.calls.isEmpty else {
                if rounds < max(1, maxRounds) {
                    let answer = LLMMessage(.assistant, turn.text)
                    let notes = steer().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    if !notes.isEmpty {
                        transcript.append(answer)
                        appended.append(answer)
                        for note in notes {
                            let message = LLMMessage(.user, note)
                            transcript.append(message)
                            appended.append(message)
                        }
                        continue
                    }
                }
                return Outcome(rounds: rounds, called: called, hitBudget: false, appended: appended,
                               usage: spent)
            }
            let ask = LLMMessage(.assistant, turn.text, toolCalls: turn.calls)
            transcript.append(ask)
            appended.append(ask)
            for call in turn.calls {
                onToolCall(call)
                called.append(call.name)
            }
            // ALL THE RESULTS, IN CALL ORDER, IN ONE BLOCK. The order is what the model asked for
            // and what the provider matches ids against; splitting them across turns teaches the
            // model to stop asking for several things at once.
            let results = await results(for: turn.calls, execute: execute, parallelSafe: parallelSafe)
            for (call, result) in zip(turn.calls, results) {
                let message = LLMMessage.toolResult(call.id, result.text, images: result.images)
                transcript.append(message)
                appended.append(message)
            }
        }

        // THE GRACE CALL. The budget is spent, so this one goes out with no tools: the model has
        // everything it fetched and must now say something. Its text streams like any other.
        try Task.checkCancellation()
        let last = try await one(round(transcript, []), onText: onText)
        spent = add(spent, last.usage)
        return Outcome(rounds: rounds + 1, called: called, hitBudget: true, appended: appended,
                       usage: spent)
    }

    /// Run one turn's calls. The parallel-safe ones run together, at most `maxParallel` at a time;
    /// the rest run one after another, in order, after them. Results come back in call order
    /// whatever ran when. A tool's result is never dropped: `execute` answers every call.
    private static func results(for calls: [LLMToolCall], execute: @escaping ExecuteOutput,
                                parallelSafe: ParallelSafe) async -> [LLMToolOutput] {
        var results = [LLMToolOutput?](repeating: nil, count: calls.count)
        let safe = calls.indices.filter { parallelSafe(calls[$0]) }
        let serial = calls.indices.filter { !parallelSafe(calls[$0]) }
        // Windows of `maxParallel`: each window's tasks start together and are awaited in order.
        // `Task` rather than a task group so `execute`, which the caller isolated to this actor,
        // is called from the actor it belongs to.
        var start = 0
        while start < safe.count {
            let window = Array(safe[start..<min(start + maxParallel, safe.count)])
            let tasks = window.map { index in
                Task { @MainActor in await execute(calls[index]) }
            }
            for (index, task) in zip(window, tasks) { results[index] = await task.value }
            start += maxParallel
        }
        for index in serial { results[index] = await execute(calls[index]) }
        return results.map { $0 ?? LLMToolOutput("") }
    }

    private static func add(_ total: Usage?, _ next: Usage?) -> Usage? {
        guard let next else { return total }
        guard let total else { return next }
        return Usage(promptTokens: total.promptTokens + next.promptTokens,
                     completionTokens: total.completionTokens + next.completionTokens,
                     totalTokens: total.totalTokens + next.totalTokens,
                     cacheReadTokens: total.cacheReadTokens + next.cacheReadTokens,
                     cacheWriteTokens: total.cacheWriteTokens + next.cacheWriteTokens)
    }

    private struct Turn {
        var text = ""
        var calls: [LLMToolCall] = []
        var usage: Usage?
    }

    /// Drain one round into its text, its calls, and its cost.
    private static func one(_ stream: AsyncThrowingStream<LLMStreamEvent, Error>,
                            onText: (String) -> Void) async throws -> Turn {
        var turn = Turn()
        for try await event in stream {
            switch event {
            case let .text(delta):
                turn.text += delta
                onText(delta)
            case let .toolCalls(list):
                turn.calls = list
            case let .usage(usage):
                turn.usage = usage
            }
        }
        return turn
    }
}
