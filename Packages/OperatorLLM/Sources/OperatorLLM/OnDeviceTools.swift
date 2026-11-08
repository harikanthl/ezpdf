//
//  OnDeviceTools.swift
//  OperatorLLM
//
//  Apple's Foundation Models framework HAS a tool-calling protocol (`Tool`, since iOS 26 / macOS 26):
//  a session is created with tools, the model asks for one, the session runs it and continues on its
//  own. docs/BOTS.md §14.8 said the on-device model had none, and that was wrong — what it lacks is a
//  way to be handed a tool described as a JSON-schema STRING, which is how `LLMToolSpec` describes
//  one so a cloud provider can read it. This file is that way: one spec becomes one
//  `DynamicGenerationSchema`, one handler becomes one `Tool`, and the catalog a cloud model is shown
//  reaches the model on the phone unchanged.
//
//  The loop is Apple's, not `AgentLoop`'s: the session calls the tool and carries on inside one
//  `streamResponse`, so the caller sees only text. The handler is the one seam, and it is the SAME
//  closure the cloud path runs — a result is a JSON string either way, a refusal is an answer either
//  way. The rounds budget is Apple's too, which is fine for the phone: a session that loops is
//  cancelled with the task, like everything else in `OnDeviceLLM`.
//
//  What the on-device model still is not: large. Its window is ~4k tokens and every tool's schema
//  rides in the instructions (`includesSchemaInInstructions`), so the catalog is kept to a handful
//  (`BotToolKit`) and a result is clipped before it goes back (`BotToolKit.clip`). A bigger model is
//  a cloud key away; the same code runs on both.
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, iOS 26.0, *)
public enum OnDeviceToolBridge {

    /// The schema for one spec, from the subset of JSON Schema `LLMToolSpec.parametersJSON` uses: an
    /// object of `string` / `integer` / `number` / `boolean` properties, each optionally described,
    /// strings optionally an `enum`, with a `required` list.
    ///
    /// Anything richer THROWS. A tool whose arguments cannot be described faithfully is left out
    /// (`tools(_:execute:)` drops it) rather than offered with a shape the model will fill in wrong —
    /// the on-device model is the one least able to recover from an argument it was never told about.
    public static func schema(for spec: LLMToolSpec) throws -> GenerationSchema {
        try GenerationSchema(root: dynamicSchema(for: spec), dependencies: [])
    }

    static func dynamicSchema(for spec: LLMToolSpec) throws -> DynamicGenerationSchema {
        guard let data = spec.parametersJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.decoding("\(spec.name): parameters are not a JSON object")
        }
        let required = Set((object["required"] as? [String]) ?? [])
        let properties = (object["properties"] as? [String: Any]) ?? [:]
        var out: [DynamicGenerationSchema.Property] = []
        // Sorted so the schema — and with it the instructions the model is shown — is byte-stable
        // between turns, the same discipline the cloud head keeps for its prompt cache.
        for name in properties.keys.sorted() {
            guard let property = properties[name] as? [String: Any],
                  let type = property["type"] as? String else {
                throw LLMError.decoding("\(spec.name).\(name): property has no type")
            }
            let description = property["description"] as? String
            let schema: DynamicGenerationSchema
            switch type {
            case "string":
                if let choices = property["enum"] as? [String], !choices.isEmpty {
                    schema = DynamicGenerationSchema(name: "\(spec.name)_\(name)", description: description,
                                                     anyOf: choices)
                } else {
                    schema = DynamicGenerationSchema(type: String.self)
                }
            case "integer": schema = DynamicGenerationSchema(type: Int.self)
            case "number":  schema = DynamicGenerationSchema(type: Double.self)
            case "boolean": schema = DynamicGenerationSchema(type: Bool.self)
            default:
                throw LLMError.decoding("\(spec.name).\(name): unsupported type \(type)")
            }
            out.append(DynamicGenerationSchema.Property(name: name, description: description, schema: schema,
                                                        isOptional: !required.contains(name)))
        }
        return DynamicGenerationSchema(name: spec.name, description: spec.description, properties: out)
    }

    /// The specs as tools a `LanguageModelSession` can run. `execute` is the handler every call goes
    /// to — the same one the cloud loop uses — and its string comes back to the model as the tool's
    /// output. A spec whose schema cannot be expressed is dropped, not approximated.
    public static func tools(_ specs: [LLMToolSpec],
                             execute: @escaping @Sendable (LLMToolCall) async -> String) -> [any Tool] {
        specs.compactMap { spec in
            guard let schema = try? schema(for: spec) else { return nil }
            return OnDeviceTool(name: spec.name, description: spec.description,
                                parameters: schema, execute: execute)
        }
    }

    /// The names that made it through, for a test or a log line.
    public static func expressible(_ specs: [LLMToolSpec]) -> [String] {
        specs.filter { (try? schema(for: $0)) != nil }.map(\.name)
    }
}

/// One tool the on-device session can call. Arguments arrive as `GeneratedContent` (already
/// validated against the schema by the framework) and leave as the JSON string `LLMToolCall` carries,
/// so a handler reads them with the same `string(_:)` / `int(_:)` it uses for a cloud call.
@available(macOS 26.0, iOS 26.0, *)
struct OnDeviceTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    let execute: @Sendable (LLMToolCall) async -> String

    func call(arguments: GeneratedContent) async throws -> String {
        // An id of our own: the framework has no call id to give, and a handler that keys on it
        // (`toolResult(_:_:)`) still needs one that is unique within the turn.
        let call = LLMToolCall(id: "ondevice_\(UUID().uuidString.prefix(8))",
                               name: name, argumentsJSON: arguments.jsonString)
        return await execute(call)
    }
}
#endif
