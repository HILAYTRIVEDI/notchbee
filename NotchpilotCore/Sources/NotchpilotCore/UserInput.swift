import Foundation

/// One selectable answer to a question an agent asked.
public struct UserInputOption: Sendable, Equatable, Hashable {
    public let label: String
    public let description: String
    public let value: String?

    public init(label: String, description: String = "", value: String? = nil) {
        self.label = label
        self.description = description
        self.value = value
    }

    /// What is sent back to the agent: the explicit value when the provider gave one, otherwise the label.
    public var answerValue: String { value ?? label }
}

public struct UserInputQuestion: Identifiable, Sendable, Equatable {
    public let id: String
    public let header: String
    public let question: String
    public let options: [UserInputOption]
    public let multiSelect: Bool
    public let allowCustomAnswer: Bool
    public let initialAnswer: String?
    public let required: Bool

    public init(
        id: String, header: String, question: String, options: [UserInputOption] = [],
        multiSelect: Bool = false, allowCustomAnswer: Bool = false, initialAnswer: String? = nil,
        required: Bool = true
    ) {
        self.id = id
        self.header = header
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
        self.allowCustomAnswer = allowCustomAnswer
        self.initialAnswer = initialAnswer
        self.required = required
    }

    /// A question with no options can only be answered in free text.
    public var offersCustomAnswer: Bool { allowCustomAnswer || options.isEmpty }
}

public struct UserInputRequest: Identifiable, Sendable, Equatable {
    public let id: String
    public let threadId: String
    public let sessionName: String
    public let questions: [UserInputQuestion]

    public init(id: String, threadId: String, sessionName: String, questions: [UserInputQuestion]) {
        self.id = id
        self.threadId = threadId
        self.sessionName = sessionName
        self.questions = questions
    }
}

/// A value in the `answers` object of `runtime-request.respond`: a string for single-select and
/// free-text questions, an array of strings for multi-select ones.
public enum UserInputAnswer: Sendable, Equatable, Encodable {
    case single(String)
    case multiple([String])

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .single(let value): try container.encode(value)
        case .multiple(let values): try container.encode(values)
        }
    }
}

/// The in-progress answers to one request. UI-free so the rules are testable.
public struct UserInputDraft: Sendable, Equatable {
    public private(set) var selected: [String: [String]] = [:]
    public private(set) var custom: [String: String] = [:]

    public init(for request: UserInputRequest) {
        for question in request.questions {
            guard let initial = question.initialAnswer, !initial.isEmpty else { continue }
            if let option = question.options.first(where: { $0.answerValue == initial || $0.label == initial }) {
                selected[question.id] = [option.answerValue]
            } else if question.offersCustomAnswer {
                custom[question.id] = initial
            }
        }
    }

    public func isSelected(_ option: UserInputOption, in question: UserInputQuestion) -> Bool {
        selected[question.id]?.contains(option.answerValue) == true
    }

    public func customText(for question: UserInputQuestion) -> String { custom[question.id] ?? "" }

    /// Single-select replaces the choice, and a choice replaces typed text. Multi-select toggles.
    public mutating func toggle(_ option: UserInputOption, in question: UserInputQuestion) {
        let value = option.answerValue
        if question.multiSelect {
            var values = selected[question.id] ?? []
            if let index = values.firstIndex(of: value) { values.remove(at: index) } else { values.append(value) }
            selected[question.id] = values.isEmpty ? nil : values
        } else {
            selected[question.id] = selected[question.id] == [value] ? nil : [value]
            if selected[question.id] != nil { custom[question.id] = nil }
        }
    }

    /// Typing replaces a single-select choice. A multi-select keeps its choices and adds the text.
    public mutating func setCustom(_ text: String, for question: UserInputQuestion) {
        custom[question.id] = text.isEmpty ? nil : text
        if !question.multiSelect, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selected[question.id] = nil
        }
    }

    public func answer(for question: UserInputQuestion) -> UserInputAnswer? {
        let typed = customText(for: question).trimmingCharacters(in: .whitespacesAndNewlines)
        var values = selected[question.id] ?? []
        if !typed.isEmpty, question.offersCustomAnswer { values.append(typed) }
        guard !values.isEmpty else { return nil }
        return question.multiSelect ? .multiple(values) : .single(values[0])
    }

    public func isComplete(for request: UserInputRequest) -> Bool {
        request.questions.allSatisfy { !$0.required || answer(for: $0) != nil }
    }

    /// The `answers` payload, keyed by question id. Unanswered optional questions are left out.
    public func answers(for request: UserInputRequest) -> [String: UserInputAnswer] {
        Dictionary(request.questions.compactMap { question in
            answer(for: question).map { (question.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }
}
