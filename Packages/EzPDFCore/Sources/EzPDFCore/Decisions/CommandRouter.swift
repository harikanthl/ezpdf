//
//  CommandRouter.swift
//  ezpdf (from ezRecord's Agents/CommandRouter.swift)
//
//  Instant commands in the assistant: "compress it", "make this searchable", "undo that", "make it
//  fillable", "send it to my Kindle". One decision-model request (a few hundred ms) picks the tool and fills
//  its arguments; the assistant's language model, which takes seconds, only runs when the request is
//  anything else or the router isn't sure.
//
//  After TypeSafe's function-calling cookbook: one Choice over the tools (plus "something else"), and for every
//  argument with a closed set of values, a "stated?" Noul and the value itself (a Choice for enums, a Noul for
//  booleans), all asked at once; only the chosen tool's answers are used. Free text, numbers and page ranges are
//  never filled here, so an instant command can't name words, pages or files. The questions come from the
//  tools' own schemas, so they stay in step as tools change.
//

import Foundation

@MainActor
public struct CommandRouter {
    /// Everyday whole-document actions with simple arguments, where being instant matters, and the values
    /// each may take here (a tool's other values, like deleting, always go through the language model).
    static let instant: [(tool: String, only: [String: [String]])] = [
        ("improve_pdf", ["action": ["compress", "compress_strong", "make_searchable", "flatten"]]),
        ("manage_document", ["action": ["undo_last_edit", "redo_last_edit"]]),
        ("make_fillable", [:]),
        ("send_to_kindle", [:]),
        ("export_file", [:]),
    ]
    /// How sure the router must be of the tool, and of each argument it fills.
    static let toolThreshold = 0.85
    static let argumentThreshold = 0.7

    public struct Route: Sendable {
        public var tool: String
        public var title: String
        /// Closed-value arguments as JSON-ready strings and booleans (no `id`: the open document is used).
        public var argumentsJSON: String
        /// The least certain judgment in the route.
        public var confidence: Double
    }

    let toolbox: AssistantToolbox
    /// Answers questions about a state: the decision model, or canned answers in tests.
    let ask: (Any, [String: DecisionClient.Question]) async throws -> [String: DecisionClient.Answer]

    public init(toolbox: AssistantToolbox, client: DecisionClient) {
        self.toolbox = toolbox
        self.ask = { try await client.ask(state: $0, questions: $1) }
    }

    init(toolbox: AssistantToolbox, ask: @escaping (Any, [String: DecisionClient.Question]) async throws -> [String: DecisionClient.Answer]) {
        self.toolbox = toolbox
        self.ask = ask
    }

    /// The tool and arguments `request` asks for, or nil to let the language model handle it.
    public func route(_ request: String) async -> Route? {
        let candidates = Self.instant.compactMap { entry in toolbox.spec(named: entry.tool).map { (spec: $0, only: entry.only) } }
        guard !candidates.isEmpty else { return nil }
        var questions: [String: DecisionClient.Question] = [
            "__tool__": .choice("What is the person asking the PDF app's assistant to do in `request`?",
                                candidates.map { ($0.spec.name, "\($0.spec.title): \($0.spec.description)") } + [
                                    ("other", "Anything else: a question, a reply to something the assistant said, several different steps at once, deleting, or details these actions can't express (particular words, pages, names, places on the page, passwords)."),
                                ]),
        ]
        var arguments: [String: [(name: String, schema: [String: Any], values: [String]?)]] = [:]
        for c in candidates {
            let args = closedArguments(of: c.spec.name, only: c.only)
            arguments[c.spec.name] = args
            for a in args {
                let description = a.schema["description"] as? String ?? a.name
                questions["\(c.spec.name).\(a.name)?"] = .noul("Does `request` say anything about this setting of “\(c.spec.title)”: \(description)?")
                if let values = a.values {
                    questions["\(c.spec.name).\(a.name)"] = .choice("Which value does `request` want for this setting of “\(c.spec.title)”: \(description)?",
                                                                    values.map { ($0, $0.replacingOccurrences(of: "_", with: " ")) })
                } else {
                    questions["\(c.spec.name).\(a.name)"] = .noul("Does `request` want this setting of “\(c.spec.title)” on: \(description)?")
                }
            }
        }
        let state: [String: Any] = ["request": request, "context": "ezpdf, a PDF app, with a document open."]
        guard let answers = try? await ask(state, questions),
              let pick = answers["__tool__"], let name = pick.choice, name != "other",
              pick.value >= Self.toolThreshold, let chosen = candidates.first(where: { $0.spec.name == name })
        else { return nil }

        var out: [String: Any] = [:]
        var confidence = pick.value
        let required = Set(requiredArguments(of: name))
        for a in arguments[name] ?? [] {
            guard let stated = answers["\(name).\(a.name)?"], let value = answers["\(name).\(a.name)"] else { return nil }
            // Unsure whether it was even mentioned: not instant.
            guard stated.value <= 1 - Self.argumentThreshold || stated.value >= Self.argumentThreshold else { return nil }
            guard stated.value >= Self.argumentThreshold else {
                if required.contains(a.name) { return nil }      // a required setting nobody stated: ask the model
                continue
            }
            if a.values != nil {
                guard let choice = value.choice, value.value >= Self.argumentThreshold else { return nil }
                out[a.name] = choice
                confidence = min(confidence, value.value)
            } else {
                guard value.value <= 1 - Self.argumentThreshold || value.value >= Self.argumentThreshold else { return nil }
                out[a.name] = value.value >= 0.5
                confidence = min(confidence, max(value.value, 1 - value.value))
            }
        }
        // Every required argument must be filled here (apart from the document, which is the open one).
        guard required.subtracting(["id"]).isSubset(of: Set(out.keys)) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]) else { return nil }
        return Route(tool: name, title: chosen.spec.title, argumentsJSON: String(decoding: data, as: UTF8.self), confidence: confidence)
    }

    /// Arguments with a closed set of values (enums, narrowed by `only`, and booleans), sorted by name.
    func closedArguments(of tool: String, only: [String: [String]]) -> [(name: String, schema: [String: Any], values: [String]?)] {
        guard let schema = toolbox.schema(of: tool), let props = schema["properties"] as? [String: Any] else { return [] }
        return props.compactMap { name, value -> (name: String, schema: [String: Any], values: [String]?)? in
            guard name != "id", let p = value as? [String: Any] else { return nil }
            if let values = p["enum"] as? [String] {
                let allowed = only[name].map { list in values.filter(list.contains) } ?? values
                return allowed.isEmpty ? nil : (name, p, allowed)
            }
            return p["type"] as? String == "boolean" ? (name, p, nil) : nil
        }
        .sorted { $0.name < $1.name }
    }

    func requiredArguments(of tool: String) -> [String] {
        (toolbox.schema(of: tool)?["required"] as? [String]) ?? []
    }
}
