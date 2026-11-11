import SwiftUI

/// Focus mode's RIGHT panel: the existing card models in large type. A single question and a tool
/// permission box are drawn here big (rows, numbers, the action button); everything else — a
/// multi-question form, a typed "Other" answer, a plan box, a Message — reuses the panel's own card
/// view at its normal size (slice 2 brings those to large type). Every click / send calls the card
/// model (`AnswerCardModel`, `PermissionCardModel`, `MessageCardModel`): no send logic here.
struct FocusAskView: View {
    @ObservedObject var session: FocusSession
    @ObservedObject var answer: AnswerCardModel
    @ObservedObject var permission: PermissionCardModel
    @ObservedObject var message: MessageCardModel

    init(session: FocusSession) {
        self.session = session
        answer = session.model.answer
        permission = session.model.permission
        message = session.model.message
    }

    var body: some View {
        switch session.ask {
        case .answer:
            if let card = answer.card, card.form == nil, card.state.phase == .choosing {
                FocusFittedPanel { fit in bigQuestion(card.state, fit: fit) }
            } else {
                reusedCard { height in
                    AnswerCardView(answer: answer, bodyHeight: height, onOpen: session.openTerminal)
                }
            }
        case .permission:
            if let card = permission.card, card.plan == nil {
                FocusFittedPanel { fit in bigPermission(card.state, fit: fit) }
            } else {
                reusedCard { height in
                    PermissionCardView(permission: permission, bodyHeight: height, onOpen: session.openTerminal)
                }
            }
        case .message:
            VStack(alignment: .leading, spacing: 14) {
                reusedCard { height in
                    MessageCardView(message: message, bodyHeight: height, onOpen: session.openTerminal)
                }
                HStack(spacing: 10) {
                    Button("Park", action: session.park)
                        .help("Set this agent aside: it leaves Needs you")
                    Button("Open terminal ⌘↩", action: session.openTerminal)
                    Spacer()
                }
                .controlSize(.large)
            }
        case .loading:
            placeholder(icon: "hourglass", text: "Reading the agent's question… (a few seconds)")
        case .terminalOnly(let reason):
            placeholder(icon: "terminal", text: reason)
        }
    }

    // MARK: - Large question

    private func bigQuestion(_ state: AnswerCardState, fit: FocusTextFit) -> some View {
        VStack(alignment: .leading, spacing: fit.body * 0.8) {
            Text(state.question.isMultiSelect ? "QUESTION · PICK ANY" : "QUESTION")
                .font(.avenir(size: max(11, fit.body * 0.55), weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(FocusPalette.mute)
            Text(state.question.displayQuestion)
                .font(.avenir(size: fit.question, weight: .semibold))
                .foregroundStyle(FocusPalette.ink)
            VStack(spacing: fit.body * 0.35) {
                ForEach(Array(state.question.options.enumerated()), id: \.offset) { position, option in
                    optionRow(
                        number: position + 1,
                        title: option.isOther ? "Other…" : option.label,
                        detail: option.isOther ? "Type your own answer" : option.description,
                        isHighlighted: position == state.highlightedPosition,
                        isChecked: state.isChecked(option),
                        fit: fit
                    ) { answer.clickOption(at: position) }
                }
            }
            if let error = state.errorText { errorLine(error, fit: fit) }
            HStack {
                Spacer()
                Button(state.question.isMultiSelect ? "Submit ↩" : "Answer ↩") { answer.pressSend() }
                    .controlSize(.large)
                    .disabled(state.readyChoice == nil)
            }
        }
    }

    // MARK: - Large permission

    private func bigPermission(_ state: PermissionCardState, fit: FocusTextFit) -> some View {
        let prompt = state.prompt
        let parts = prompt.detailParts
        return VStack(alignment: .leading, spacing: fit.body * 0.8) {
            Text("\(prompt.tool.uppercased()) NEEDS YOUR OK")
                .font(.avenir(size: max(11, fit.body * 0.55), weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(FocusPalette.mute)
            VStack(alignment: .leading, spacing: 6) {
                Text(parts.headline.isEmpty ? "(no details shown)" : parts.headline)
                    .font(.avenirMono(size: fit.body * 0.8, weight: .medium))
                if let diff = parts.body {
                    Text(diff)
                        .font(.avenirMono(size: fit.body * 0.68))
                        .foregroundStyle(FocusPalette.mute)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(fit.body * 0.6)
            .background(RoundedRectangle(cornerRadius: 10).fill(FocusPalette.panel))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(FocusPalette.accent.opacity(0.35)))
            Text(prompt.title)
                .font(.avenir(size: fit.question, weight: .semibold))
                .foregroundStyle(FocusPalette.ink)
            if let note = state.changedNote { errorLine(note, fit: fit) }
            switch state.phase {
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking the terminal's prompt…")
                }
                .font(.avenir(size: fit.body * 0.75))
                .foregroundStyle(FocusPalette.mute)
            case .unavailable(let reason):
                errorLine(reason, fit: fit)
                Button("Open terminal ⌘↩", action: session.openTerminal).controlSize(.large)
            case .ready:
                VStack(spacing: fit.body * 0.35) {
                    ForEach(Array(state.choices.enumerated()), id: \.offset) { position, choice in
                        let option = prompt.option(for: choice)
                        optionRow(
                            number: option?.index ?? position + 1, title: choice.title, detail: option?.label ?? "",
                            isHighlighted: state.highlighted == choice, isChecked: false, fit: fit
                        ) { permission.clickChoice(choice) }
                    }
                }
                HStack {
                    Spacer()
                    Button("\(state.actionTitle) ↩") { permission.pressSend() }
                        .controlSize(.large)
                        .disabled(!state.canSend)
                }
            }
        }
    }

    // MARK: - Pieces

    private func optionRow(
        number: Int, title: String, detail: String, isHighlighted: Bool, isChecked: Bool,
        fit: FocusTextFit, action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: fit.body * 0.6) {
            Text(isChecked ? "✓" : "\(number)")
                .font(.avenirMono(size: fit.body * 0.75, weight: .semibold))
                .foregroundStyle(isHighlighted ? FocusPalette.accent : FocusPalette.mute)
                .frame(width: fit.body * 1.2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.avenir(size: fit.body, weight: .semibold))
                    .foregroundStyle(FocusPalette.ink)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.avenir(size: fit.body * 0.72))
                        .foregroundStyle(FocusPalette.mute)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, fit.body * 0.7)
        .padding(.vertical, fit.body * 0.5)
        .background(RoundedRectangle(cornerRadius: 12).fill(isHighlighted ? FocusPalette.selected : .clear))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isHighlighted ? FocusPalette.accent.opacity(0.4) : FocusPalette.line))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: isHighlighted)
    }

    private func errorLine(_ text: String, fit: FocusTextFit) -> some View {
        Text(text)
            .font(.avenir(size: fit.body * 0.7, weight: .medium))
            .foregroundStyle(.red)
    }

    private func reusedCard<Card: View>(@ViewBuilder _ card: @escaping (CGFloat) -> Card) -> some View {
        GeometryReader { geometry in
            card(geometry.size.height)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                .background(RoundedRectangle(cornerRadius: 12).fill(FocusPalette.panel))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(FocusPalette.mute)
            Text(text)
                .font(.avenir(size: 20))
                .foregroundStyle(FocusPalette.ink)
                .multilineTextAlignment(.center)
            Button("Open terminal ⌘↩", action: session.openTerminal).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
