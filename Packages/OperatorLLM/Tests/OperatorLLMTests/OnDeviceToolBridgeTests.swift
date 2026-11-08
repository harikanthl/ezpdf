import Foundation
import Testing
@testable import OperatorLLM

#if canImport(FoundationModels)
import FoundationModels

/// A cloud tool spec becomes an on-device `Tool` (docs/BOTS.md §14.10). Schema construction needs
/// the framework but not the model, so these run wherever Foundation Models links.
@Suite struct OnDeviceToolBridgeTests {

    // The four shapes `BotToolKit` actually emits, restated here because this package cannot see it.
    static let readDocument = LLMToolSpec(
        name: "read_document", description: "Read one file.",
        parametersJSON: """
        {"type":"object","properties":{"filename":{"type":"string","description":"The file's exact name"}},\
        "required":["filename"],"additionalProperties":false}
        """)
    static let readLog = LLMToolSpec(
        name: "read_worker_log", description: "Read the log.",
        parametersJSON: """
        {"type":"object","properties":{"limit":{"type":"integer","description":"How many"}},\
        "additionalProperties":false}
        """)
    static let runJob = LLMToolSpec(
        name: "run_job", description: "Offer a job.",
        parametersJSON: """
        {"type":"object","properties":{"job":{"type":"string","enum":["Network check","Health check"],\
        "description":"Which"},"when":{"type":"string","description":"Optional time"}},\
        "required":["job"],"additionalProperties":false}
        """)
    static let recall = LLMToolSpec.noArguments("recall", "Search the thread.")

    @available(macOS 26.0, iOS 26.0, *)
    @Test func everyBotToolShapeIsExpressible() {
        let specs = [Self.readDocument, Self.readLog, Self.runJob, Self.recall]
        #expect(OnDeviceToolBridge.expressible(specs) == specs.map(\.name))
        #expect(OnDeviceToolBridge.tools(specs) { _ in "{}" }.map(\.name) == specs.map(\.name))
    }

    @available(macOS 26.0, iOS 26.0, *)
    @Test func aShapeTheBridgeCannotDescribeIsDroppedNotApproximated() {
        let nested = LLMToolSpec(
            name: "nested", description: "Has an object argument.",
            parametersJSON: """
            {"type":"object","properties":{"filter":{"type":"object","properties":{}}},"required":["filter"]}
            """)
        #expect(throws: (any Error).self) { try OnDeviceToolBridge.schema(for: nested) }
        #expect(OnDeviceToolBridge.expressible([Self.readDocument, nested]) == ["read_document"])
    }

    @available(macOS 26.0, iOS 26.0, *)
    @Test func brokenJSONThrowsRatherThanYieldingAnEmptyTool() {
        let broken = LLMToolSpec(name: "broken", description: "", parametersJSON: "{not json")
        #expect(throws: (any Error).self) { try OnDeviceToolBridge.schema(for: broken) }
    }

    /// The handler sees the same `LLMToolCall` a cloud call would carry: the tool's name and the
    /// arguments as JSON, readable through `string(_:)`.
    @available(macOS 26.0, iOS 26.0, *)
    @Test func aCallReachesTheHandlerAsAnLLMToolCall() async throws {
        let tools = OnDeviceToolBridge.tools([Self.readDocument]) { call in
            "{\"got\":\"\(call.name):\(call.string("filename") ?? "-")\"}"
        }
        let tool = try #require(tools.first as? OnDeviceTool)
        let arguments = try GeneratedContent(json: "{\"filename\":\"report.md\"}")
        let out = try await tool.call(arguments: arguments)
        #expect(out == "{\"got\":\"read_document:report.md\"}")
    }
}
#endif
