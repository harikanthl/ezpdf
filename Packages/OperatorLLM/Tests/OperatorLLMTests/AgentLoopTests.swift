import Foundation
import Testing
@testable import OperatorLLM

/// The loop that turns a chat into an agent (docs/BOTS.md §14.9), driven against a scripted model so
/// every rule is checked without a network.
@MainActor
@Suite struct AgentLoopTests {

    /// A model that replies with whatever the script says, one entry per round.
    private struct Script {
        var rounds: [[LLMStreamEvent]]
        var seen: [[LLMMessage]] = []
        var toolsSeen: [[LLMToolSpec]] = []
    }

    private final class Box { var script: Script; init(_ s: Script) { script = s } }

    private func brain(_ box: Box) -> AgentLoop.Round {
        { messages, tools in
            box.script.seen.append(messages)
            box.script.toolsSeen.append(tools)
            let events = box.script.rounds.isEmpty ? [] : box.script.rounds.removeFirst()
            return AsyncThrowingStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    private let readDoc = LLMToolSpec(name: "read_document", description: "Read a file.",
                                      parametersJSON: #"{"type":"object","properties":{"filename":{"type":"string"}}}"#)

    // MARK: The common case

    @Test func aModelThatJustAnswersMakesOneRoundAndNoCalls() async throws {
        let box = Box(Script(rounds: [[.text("Your uplink is 26 Mbps.")]]))
        var said = ""
        let outcome = try await AgentLoop.run(
            messages: [LLMMessage(.user, "how fast is my link?")], tools: [readDoc],
            round: brain(box), execute: { _ in "{}" }, onText: { said += $0 })
        #expect(outcome.rounds == 1)
        #expect(outcome.called.isEmpty)
        #expect(!outcome.hitBudget)
        #expect(said == "Your uplink is 26 Mbps.")
        #expect(outcome.appended.isEmpty, "nothing to append when nothing was looked up")
    }

    // MARK: Steering

    @Test func aNoteTypedMidRunReachesTheNextStep() async throws {
        let call = LLMToolCall(id: "call_1", name: "read_document", argumentsJSON: #"{"filename":"a.md"}"#)
        let box = Box(Script(rounds: [[.toolCalls([call])], [.text("Done, shorter.")]]))
        var notes = ["make it shorter"]
        let outcome = try await AgentLoop.run(
            messages: [LLMMessage(.user, "edit it")], tools: [readDoc], round: brain(box),
            executeOutput: { _ in LLMToolOutput("{}") },
            steer: { defer { notes = [] }; return notes })
        // Read before the first round, so the first request already carries it.
        #expect(box.script.seen[0].last?.content == "make it shorter")
        #expect(outcome.appended.contains { $0.role == .user && $0.content == "make it shorter" })
        #expect(outcome.rounds == 2)
    }

    @Test func aNoteDuringTheAnswerGetsOneMoreRound() async throws {
        let box = Box(Script(rounds: [[.text("Here it is.")], [.text("Made it blue.")]]))
        var calls = 0
        var notes: [String] = []
        let outcome = try await AgentLoop.run(
            messages: [LLMMessage(.user, "style it")], tools: [readDoc], round: brain(box),
            executeOutput: { _ in LLMToolOutput("{}") },
            steer: {
                calls += 1
                // Nothing before round 1; the note lands while the model answers.
                if calls == 2 { notes = ["use blue instead"] }
                defer { notes = [] }
                return notes
            })
        #expect(outcome.rounds == 2)
        #expect(box.script.seen[1].suffix(2).map(\.content) == ["Here it is.", "use blue instead"])
        #expect(!outcome.hitBudget)
    }

    // MARK: The loop

    @Test func aToolCallIsRunAndItsResultGoesBackForASecondRound() async throws {
        let call = LLMToolCall(id: "call_1", name: "read_document",
                               argumentsJSON: #"{"filename":"network-report.md"}"#)
        let box = Box(Script(rounds: [[.text("Let me look."), .toolCalls([call])],
                                      [.text("RPM 340: bufferbloat.")]]))
        var ran: [String] = []
        let outcome = try await AgentLoop.run(
            messages: [LLMMessage(.user, "what did it say?")], tools: [readDoc],
            round: brain(box),
            execute: { ran.append($0.string("filename") ?? ""); return #"{"body":"RPM 340"}"# })
        #expect(outcome.rounds == 2)
        #expect(outcome.called == ["read_document"])
        #expect(ran == ["network-report.md"])

        // ‼️ THE ASSISTANT'S ASK GOES BACK TOO, not just the result: a provider rejects a `tool`
        // message answering a call it cannot see.
        let second = box.script.seen[1]
        #expect(second.count == 3)
        #expect(second[1].role == .assistant)
        #expect(second[1].toolCalls == [call])
        #expect(second[2].role == .tool)
        #expect(second[2].toolCallID == "call_1")
        #expect(second[2].content == #"{"body":"RPM 340"}"#)
        // …and the caller gets both back to persist.
        #expect(outcome.appended.count == 2)
    }

    @Test func severalCallsInOneRoundAllRunInOrder() async throws {
        let calls = [LLMToolCall(id: "a", name: "read_document", argumentsJSON: #"{"filename":"1.md"}"#),
                     LLMToolCall(id: "b", name: "read_document", argumentsJSON: #"{"filename":"2.md"}"#)]
        let box = Box(Script(rounds: [[.toolCalls(calls)], [.text("Both say the same thing.")]]))
        var ran: [String] = []
        let outcome = try await AgentLoop.run(
            messages: [LLMMessage(.user, "compare them")], tools: [readDoc],
            round: brain(box), execute: { ran.append($0.string("filename") ?? ""); return "{}" })
        #expect(ran == ["1.md", "2.md"])
        #expect(outcome.called == ["read_document", "read_document"])
    }

    // MARK: Parallel-safe scheduling (docs/OSS_LIFT_2026-09.md L1/L2)

    /// Two reads the classifier allows run together: the slow first call finishes AFTER the fast
    /// second one, and the results still come back in call order, in one block.
    @Test func parallelSafeCallsOverlapAndResultsKeepCallOrder() async throws {
        let calls = [LLMToolCall(id: "slow", name: "read_document", argumentsJSON: #"{"filename":"slow.md"}"#),
                     LLMToolCall(id: "fast", name: "read_document", argumentsJSON: #"{"filename":"fast.md"}"#)]
        let box = Box(Script(rounds: [[.toolCalls(calls)], [.text("done")]]))
        var finished: [String] = []
        let outcome = try await AgentLoop.run(
            messages: [LLMMessage(.user, "compare")], tools: [readDoc],
            round: brain(box),
            execute: { call in
                let name = call.string("filename") ?? ""
                if name == "slow.md" { try? await Task.sleep(for: .milliseconds(120)) }
                finished.append(name)
                return #"{"file":"\#(name)"}"#
            },
            parallelSafe: { _ in true })
        #expect(finished == ["fast.md", "slow.md"], "the fast one completed first, so they overlapped")
        // The transcript the model sees is in the order it asked, whatever ran when.
        let second = box.script.seen[1]
        #expect(second[2].toolCallID == "slow")
        #expect(second[2].content == #"{"file":"slow.md"}"#)
        #expect(second[3].toolCallID == "fast")
        #expect(outcome.called == ["read_document", "read_document"])
    }

    /// The default classifier refuses everything, so nothing overlaps and the old order holds.
    @Test func withoutAClassifierCallsRunOneAfterAnother() async throws {
        let calls = [LLMToolCall(id: "slow", name: "read_document", argumentsJSON: #"{"filename":"slow.md"}"#),
                     LLMToolCall(id: "fast", name: "read_document", argumentsJSON: #"{"filename":"fast.md"}"#)]
        let box = Box(Script(rounds: [[.toolCalls(calls)], [.text("done")]]))
        var finished: [String] = []
        _ = try await AgentLoop.run(
            messages: [LLMMessage(.user, "compare")], tools: [readDoc],
            round: brain(box),
            execute: { call in
                let name = call.string("filename") ?? ""
                if name == "slow.md" { try? await Task.sleep(for: .milliseconds(60)) }
                finished.append(name)
                return "{}"
            })
        #expect(finished == ["slow.md", "fast.md"])
    }

    /// A card-raising tool in the same turn as reads runs after them, in order; nothing is dropped.
    @Test func unsafeCallsRunSequentiallyAfterTheSafeOnes() async throws {
        let calls = [LLMToolCall(id: "1", name: "ask_question", argumentsJSON: "{}"),
                     LLMToolCall(id: "2", name: "read_document", argumentsJSON: #"{"filename":"a.md"}"#),
                     LLMToolCall(id: "3", name: "run_job", argumentsJSON: "{}")]
        let box = Box(Script(rounds: [[.toolCalls(calls)], [.text("done")]]))
        var order: [String] = []
        let outcome = try await AgentLoop.run(
            messages: [LLMMessage(.user, "go")], tools: [readDoc],
            round: brain(box),
            execute: { order.append($0.name); return #"{"ok":true}"# },
            parallelSafe: { $0.name == "read_document" })
        #expect(order == ["read_document", "ask_question", "run_job"])
        let second = box.script.seen[1]
        #expect(second.dropFirst(2).map(\.toolCallID) == ["1", "2", "3"])
        #expect(outcome.appended.count == 4)
    }

    // MARK: Usage

    @Test func usageIsSummedAcrossRoundsIncludingTheCacheSplit() async throws {
        let call = LLMToolCall(id: "c", name: "read_document", argumentsJSON: "{}")
        let first = Usage(promptTokens: 100, completionTokens: 10, totalTokens: 1110,
                          cacheReadTokens: 1000, cacheWriteTokens: 0)
        let second = Usage(promptTokens: 50, completionTokens: 30, totalTokens: 1180,
                           cacheReadTokens: 1100, cacheWriteTokens: 0)
        let box = Box(Script(rounds: [[.toolCalls([call]), .usage(first)],
                                      [.text("answer"), .usage(second)]]))
        let outcome = try await AgentLoop.run(
            messages: [LLMMessage(.user, "q")], tools: [readDoc],
            round: brain(box), execute: { _ in "{}" })
        let usage = try #require(outcome.usage)
        #expect(usage.promptTokens == 150)
        #expect(usage.completionTokens == 40)
        #expect(usage.cacheReadTokens == 2100)
    }

    @Test func aRouteThatReportsNoUsageLeavesItNil() async throws {
        let box = Box(Script(rounds: [[.text("answer")]]))
        let outcome = try await AgentLoop.run(
            messages: [LLMMessage(.user, "q")], tools: [readDoc],
            round: brain(box), execute: { _ in "{}" })
        #expect(outcome.usage == nil)
    }

    // MARK: The budget

    /// A model that will not stop asking is stopped, and the LAST call goes out with no tools so it
    /// has to answer. A loop that merely stops leaves a spinner and no words.
    @Test func aRunawayHitsTheBudgetAndTheGraceCallHasNoTools() async throws {
        // A model that asks for a tool for as long as one is on offer — the failure the budget is
        // for. It answers only when the grace call arrives with an empty tool list, which is the
        // whole mechanism: not "stop", but "stop asking and say something".
        let call = LLMToolCall(id: "x", name: "read_document", argumentsJSON: "{}")
        var offered: [[LLMToolSpec]] = []
        let runaway: AgentLoop.Round = { _, tools in
            offered.append(tools)
            return AsyncThrowingStream { continuation in
                continuation.yield(tools.isEmpty ? .text("Fine: 26 Mbps.") : .toolCalls([call]))
                continuation.finish()
            }
        }
        var said = ""
        let outcome = try await AgentLoop.run(
            messages: [LLMMessage(.user, "go")], tools: [readDoc], maxRounds: 3,
            round: runaway, execute: { _ in "{}" }, onText: { said += $0 })
        #expect(outcome.hitBudget)
        #expect(outcome.rounds == 4, "three rounds plus the grace call")
        #expect(outcome.called.count == 3)
        #expect(offered.count == 4)
        #expect(offered.last?.isEmpty == true, "the grace call offers no tools")
        #expect(said == "Fine: 26 Mbps.", "the person gets words, not a spinner")
    }

    @Test func aBudgetOfZeroIsStillOneRound() async throws {
        let box = Box(Script(rounds: [[.text("hi")]]))
        let outcome = try await AgentLoop.run(messages: [], tools: [], maxRounds: 0,
                                              round: brain(box), execute: { _ in "{}" })
        #expect(outcome.rounds == 1)
    }

    // MARK: What the caller sees while it works

    @Test func theCallerIsToldBeforeEachToolRuns() async throws {
        let call = LLMToolCall(id: "1", name: "read_document", argumentsJSON: #"{"filename":"a.md"}"#)
        let box = Box(Script(rounds: [[.toolCalls([call])], [.text("done")]]))
        var announced: [String] = []
        _ = try await AgentLoop.run(messages: [], tools: [readDoc], round: brain(box),
                                    execute: { _ in "{}" },
                                    onToolCall: { announced.append($0.name) })
        #expect(announced == ["read_document"])
    }

    @Test func anErrorFromTheModelPropagates() async {
        let failing: AgentLoop.Round = { _, _ in
            AsyncThrowingStream { $0.finish(throwing: LLMError.rateLimited(retryAfter: 3)) }
        }
        await #expect(throws: LLMError.self) {
            try await AgentLoop.run(messages: [], tools: [], round: failing, execute: { _ in "{}" })
        }
    }
}
