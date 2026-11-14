import SwiftUI

/// Focus mode's RIGHT panel: the existing card models in large type. A single question and a tool
/// permission box and a multi-question form are drawn here big (rows, numbers, the action button);
/// everything else — a typed "Other" answer on a single question (a form's Other box is the panel's
/// small one, inside the big form), a plan box, a Message — reuses the panel's own card
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
            if let card = answer.card, let form = card.form {
                FocusFittedPanel(maxBody: FocusTextFit.rightMaxBody) { fit in bigForm(form, fit: fit) }
            } else if let card = answer.card, card.state.phase == .choosing {
                FocusFittedPanel(maxBody: FocusTextFit.rightMaxBody) { fit in bigQuestion(card.state, fit: fit) }
            } else {
                reusedCard { height in
                    AnswerCardView(answer: answer, bodyHeight: height, onOpen: session.openTerminal)
                }
            }
        case .permission:
            if let card = permission.card, card.plan == nil {
                FocusFittedPanel(maxBody: FocusTextFit.rightMaxBody) { fit in bigPermission(card.state, fit: fit) }
            } else {
                reusedCard { height in
                    PermissionCardView(permission: permission, bodyHeight: height, onOpen: session.openTerminal)
                }
            }
        case .message:
            VStack(alignment: .leading, spacing: 14) {
                reusedCard { height in
                    MessageCardView(message: message, bodyHeight: height, onOpen: session.openTerminal, showsLastMessage: false)
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
                .font(.avenir(size: FocusTextFit.questionSize(for: state.question.displayQuestion, fit: fit),
                              weight: .semibold))
                .foregroundStyle(FocusPalette.ink)
            VStack(spacing: fit.body * 0.35) {
                ForEach(Array(state.question.options.enumerated()), id: \.offset) { position, option in
                    optionRow(
                        number: position + 1,
                        title: option.isOther ? "Other…" : option.label,
                        detail: option.isOther ? "Type your own answer" : option.description,
                        isHighlighted: position == state.highlightedPosition,
                        isChecked: state.isChecked(option),
                        isCheckbox: state.question.isMultiSelect && !option.isOther,
                        fit: fit
                    ) { answer.clickOption(at: position) }
                }
            }
            if let error = state.errorText { errorLine(error, fit: fit) }
            HStack {
                if state.question.isMultiSelect {
                    Text("Space or 1–9 ticks · ↩ submits \(state.checkedIndices.count) picked")
                        .font(.avenir(size: max(12, fit.body * 0.65)))
                        .foregroundStyle(FocusPalette.mute)
                }
                Spacer()
                Button(state.question.isMultiSelect ? "Submit ↩" : "Answer ↩") { answer.pressSend() }
                    .controlSize(.large)
                    .disabled(state.readyChoice == nil)
            }
        }
    }

    // MARK: - Large form

    /// Every question of a multi-question form, big: its own answered state, the options (radio or tick
    /// box), Other, then "N of M answered" and Submit. Clicks go through `FocusSession.clickForm` (the
    /// card model's `clickFormRow`), Submit through the card's `handle(.enter)`; keys: `FocusFormCursor`.
    private func bigForm(_ form: AnswerFormState, fit: FocusTextFit) -> some View {
        let cursor = session.cursor(for: form)
        let count = form.form.questions.count
        return VStack(alignment: .leading, spacing: fit.body * 1.0) {
            ForEach(Array(form.form.questions.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: fit.body * 0.45) {
                    HStack(spacing: 8) {
                        Text("\(index + 1) OF \(count)\(question.header.isEmpty ? "" : " · " + question.header.uppercased())\(question.isMultiSelect ? " · PICK ANY" : "")")
                            .font(.avenir(size: max(11, fit.body * 0.55), weight: .semibold))
                            .kerning(0.8)
                            .foregroundStyle(FocusPalette.mute)
                        if form.choice(for: index) != nil, form.outcomes[index] == .waiting {
                            Text("✓ Answered")
                                .font(.avenir(size: max(11, fit.body * 0.55), weight: .semibold))
                                .foregroundStyle(FocusPalette.ok)
                        }
                        Spacer(minLength: 0)
                        outcomeChip(form.outcomes[index], fit: fit)
                    }
                    Text(QuestionDisplayText.clean(question.question))
                        .font(.avenir(size: fit.body, weight: .semibold))
                        .foregroundStyle(FocusPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    VStack(spacing: fit.body * 0.3) {
                        ForEach(Array(question.options.enumerated()), id: \.offset) { row, option in
                            optionRow(
                                number: row + 1, title: option.label, detail: option.description,
                                isHighlighted: cursor.question == index && cursor.row == row,
                                isChecked: form.isChecked(row: row, of: index),
                                isCheckbox: question.isMultiSelect, isRadio: !question.isMultiSelect, fit: fit
                            ) { session.clickForm(row: row, of: index) }
                        }
                        formOtherRow(form, index: index, cursor: cursor, fit: fit)
                    }
                    .allowsHitTesting(form.isEditable)
                    .opacity(form.isEditable ? 1 : 0.6)
                }
            }
            if let report = form.report { errorLine(report, fit: fit) }
            HStack(spacing: 12) {
                Text("\(form.answeredCount) of \(count) answered")
                    .font(.avenir(size: max(12, fit.body * 0.7), weight: .medium))
                    .foregroundStyle(form.isComplete ? FocusPalette.ok : FocusPalette.mute)
                Text("↑↓ · 1–9 · Space/↩ choose")
                    .font(.avenir(size: max(11, fit.body * 0.55)))
                    .foregroundStyle(FocusPalette.mute)
                Spacer()
                Button("Submit ↩") { answer.handle(.enter) }
                    .controlSize(.large)
                    .disabled(!form.canSubmit)
            }
        }
    }

    /// Other: a big row until it is chosen, then the panel's own (small) text box for typing.
    @ViewBuilder
    private func formOtherRow(_ form: AnswerFormState, index: Int, cursor: FocusFormCursor, fit: FocusTextFit) -> some View {
        let row = form.otherRow(of: index)
        let typing = form.drafts[index].usesOther && form.isEditable
        optionRow(
            number: row + 1, title: "Other…", detail: typing ? "" : "Type your own answer",
            isHighlighted: cursor.question == index && cursor.row == row,
            isChecked: form.isChecked(row: row, of: index), isRadio: true, fit: fit
        ) { session.clickForm(row: row, of: index) }
        if typing {
            if fit.isMeasuring {
                Color.clear.frame(height: AnswerOptionRowView.textHeight)
            } else {
                AnswerOptionRowView(
                    option: .init(index: row + 1, label: "Other (type your own answer)", description: "", isOther: true),
                    isMultiSelect: false, isHighlighted: false, isChecked: true, isTypingHere: true,
                    choiceMarker: nil,
                    typedTextNote: OtherAnswerText.note(for: form.drafts[index].otherText),
                    otherText: Binding(get: { form.drafts[index].otherText }, set: { answer.setFormOtherText($0, of: index) }),
                    onSubmitText: { answer.handle(.enter) },
                    onLeaveText: { answer.releaseFormTextField() }
                )
                .background(RoundedRectangle(cornerRadius: 10).fill(FocusPalette.panel))
            }
        }
    }

    @ViewBuilder
    private func outcomeChip(_ outcome: FormQuestionOutcome, fit: FocusTextFit) -> some View {
        let size = max(11, fit.body * 0.55)
        switch outcome {
        case .waiting: EmptyView()
        case .sending: Text("Sending…").font(.avenir(size: size, weight: .semibold)).foregroundStyle(FocusPalette.mute)
        case .landed: Text("Sent").font(.avenir(size: size, weight: .semibold)).foregroundStyle(FocusPalette.ok)
        case .skipped: Text("Skipped").font(.avenir(size: size, weight: .semibold)).foregroundStyle(WarningTextColor.color)
        case .refused: Text("Refused").font(.avenir(size: size, weight: .semibold)).foregroundStyle(.red)
        case .notSent: Text("Not sent").font(.avenir(size: size, weight: .semibold)).foregroundStyle(.red)
        case .recorded(_, let chose):
            Text(chose == nil ? "Recorded" : "Check it").font(.avenir(size: size, weight: .semibold))
                .foregroundStyle(chose == nil ? FocusPalette.ok : WarningTextColor.color)
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
        isCheckbox: Bool = false, isRadio: Bool = false, fit: FocusTextFit, action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: fit.body * 0.6) {
            Text(isChecked && !isCheckbox && !isRadio ? "✓" : "\(number)")
                .font(.avenirMono(size: fit.body * 0.75, weight: .semibold))
                .foregroundStyle(isHighlighted ? FocusPalette.accent : FocusPalette.mute)
                .frame(width: fit.body * 1.2)
            if isCheckbox || isRadio {
                Image(systemName: isCheckbox ? (isChecked ? "checkmark.square.fill" : "square")
                                             : (isChecked ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: fit.body * 0.95, weight: .medium))
                    .foregroundStyle(isChecked ? FocusPalette.accent : FocusPalette.mute)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + fit.body * 0.3 }
                    .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isChecked)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.avenir(size: fit.body, weight: .semibold))
                    .foregroundStyle(FocusPalette.ink)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.avenir(size: fit.body * FocusTextFit.detailScale))
                        .foregroundStyle(FocusPalette.ink.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
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
