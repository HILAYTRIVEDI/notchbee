import NotchpilotCore
import SwiftUI

/// An agent's question: one block per question with selectable options and an optional free-text answer.
struct UserInputCard: View {
    let request: UserInputRequest
    let showsSession: Bool
    let error: String?
    let submit: ([String: UserInputAnswer]) -> Void
    let dismiss: () -> Void

    @State private var draft: UserInputDraft
    @FocusState private var focusedQuestion: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(request: UserInputRequest, showsSession: Bool, error: String?,
         submit: @escaping ([String: UserInputAnswer]) -> Void, dismiss: @escaping () -> Void) {
        self.request = request
        self.showsSession = showsSession
        self.error = error
        self.submit = submit
        self.dismiss = dismiss
        _draft = State(initialValue: UserInputDraft(for: request))
    }

    /// A rough height for sizing the panel before the card has been measured.
    static func estimatedHeight(for request: UserInputRequest) -> CGFloat {
        request.questions.reduce(88) { total, question in
            total + 52 + CGFloat(question.options.count) * 46 + (question.offersCustomAnswer ? 36 : 0)
        }
    }

    private var isComplete: Bool { draft.isComplete(for: request) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(T3.warning)
                Text("Needs input").font(.system(size: T3.small + 0.5, weight: .semibold))
                Spacer(minLength: 4)
                if showsSession {
                    Text(verbatim: request.sessionName).font(.system(size: T3.caption)).foregroundStyle(T3.muted)
                        .lineLimit(1)
                }
            }
            ForEach(request.questions) { question in
                questionBlock(question)
            }
            if let error {
                Text(verbatim: error).font(.system(size: T3.caption)).foregroundStyle(T3.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Dismiss", action: dismiss)
                    .buttonStyle(.bordered).clickableCursor()
                    .help("Skip these questions without answering")
                Button("Submit", action: send)
                    .buttonStyle(.borderedProminent).clickableCursor()
                    .tint(T3.primary)
                    .disabled(!isComplete)
            }
        }
        .padding(10)
        .background(T3.warning.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(T3.warning.opacity(0.30), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Question from \(request.sessionName)")
    }

    private func send() {
        guard isComplete else { return }
        submit(draft.answers(for: request))
    }

    private func questionBlock(_ question: UserInputQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(verbatim: question.header)
                    .font(.system(size: T3.micro, weight: .semibold))
                    .foregroundStyle(T3.muted)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(T3.fillHover, in: Capsule())
                if !question.required {
                    Text("Optional").font(.system(size: T3.micro)).foregroundStyle(T3.faint)
                }
                if question.multiSelect {
                    Text("Select all that apply").font(.system(size: T3.micro)).foregroundStyle(T3.faint)
                }
            }
            Text(verbatim: question.question)
                .font(.system(size: T3.small + 0.5, weight: .medium))
                .foregroundStyle(T3.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                optionRow(option, index: index, in: question)
            }
            if question.offersCustomAnswer {
                FocusedEditor(
                    text: Binding(get: { draft.customText(for: question) },
                                  set: { draft.setCustom($0, for: question) }),
                    placeholder: question.options.isEmpty ? "Your answer" : "Other…", submit: send)
                    .accessibilityLabel(question.options.isEmpty ? "Your answer" : "Other answer")
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focusedQuestion, equals: question.id)
        .onKeyPress(characters: .decimalDigits) { press in
            // 1–9 pick an option of the question that has focus. Digits typed in "Other" never reach here.
            guard let digit = press.characters.first?.wholeNumberValue, digit >= 1,
                  digit <= question.options.count else { return .ignored }
            draft.toggle(question.options[digit - 1], in: question)
            return .handled
        }
    }

    private func optionRow(_ option: UserInputOption, index: Int, in question: UserInputQuestion) -> some View {
        let selected = draft.isSelected(option, in: question)
        let symbol = question.multiSelect
            ? (selected ? "checkmark.square.fill" : "square")
            : (selected ? "largecircle.fill.circle" : "circle")
        return Button {
            focusedQuestion = question.id
            draft.toggle(option, in: question)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? T3.link : T3.faint)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: option.label)
                        .font(.system(size: T3.small + 0.5, weight: .medium))
                        .foregroundStyle(T3.foreground)
                    if !option.description.isEmpty {
                        Text(verbatim: option.description)
                            .font(.system(size: T3.caption))
                            .foregroundStyle(T3.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if index < 9 {
                    Text("\(index + 1)").font(.system(size: T3.micro, weight: .medium, design: .monospaced))
                        .foregroundStyle(T3.faint)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(selected ? T3.primary.opacity(0.18) : T3.fill, in: RoundedRectangle(cornerRadius: T3.radius))
            .overlay(RoundedRectangle(cornerRadius: T3.radius)
                .strokeBorder(selected ? T3.primary.opacity(0.7) : T3.border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: T3.radius))
        }
        .buttonStyle(.plain).clickableCursor()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: selected)
        .accessibilityLabel(option.label)
        .accessibilityHint(option.description)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
