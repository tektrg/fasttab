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
                VStack(spacing: 14) {
                    FocusFittedPanel(maxBody: FocusTextFit.rightMaxBody) { fit in bigForm(form, fit: fit) }
                    formFooter(form)   // pinned: Submit never scrolls away or sits on the bottom edge
                }
            } else if let card = answer.card {
                FocusFittedPanel(maxBody: FocusTextFit.rightMaxBody) { fit in bigQuestion(card.state, fit: fit) }
            }
        case .permission:
            if let card = permission.card, let plan = card.plan {
                bigPlan(card, plan)
            } else if let card = permission.card {
                FocusFittedPanel(maxBody: FocusTextFit.rightMaxBody) { fit in bigPermission(card.state, fit: fit) }
            }
        case .message:
            VStack(alignment: .leading, spacing: 18) {
                Text("MESSAGE · THIS AGENT IS WAITING FOR YOU")
                    .font(.avenir(size: 12, weight: .semibold))
                    .kerning(0.8)
                    .foregroundStyle(FocusPalette.mute)
                reusedCard { height in
                    MessageCardView(message: message, bodyHeight: height, showsLastMessage: false,
                                    largeTextSize: FocusTextFit.baseBody)
                }
                HStack(spacing: 10) {
                    Button("Park", action: session.park)
                        .help("Set this agent aside: it leaves Needs you")
                    FocusGoToButton(session: session)
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
                    if option.isOther, state.phase == .typingOther {
                        bigTextBox(
                            text: Binding(get: { answer.card?.state.otherText ?? "" }, set: { answer.setOtherText($0) }),
                            note: state.otherTextNote, fit: fit,
                            onSubmit: { answer.handle(.enter) }, onLeave: { answer.handle(.escape) }
                        )
                    }
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
            .padding(.bottom, fit.body * 0.6)
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
                let _ = count
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
        }
    }

    private func formFooter(_ form: AnswerFormState) -> some View {
        HStack(spacing: 12) {
            Text("\(form.answeredCount) of \(form.form.questions.count) answered")
                .font(.avenir(size: 16, weight: .medium))
                .foregroundStyle(form.isComplete ? FocusPalette.ok : FocusPalette.mute)
            Text("↑↓ · 1–9 · Space/↩ choose")
                .font(.avenir(size: 13))
                .foregroundStyle(FocusPalette.mute)
            Spacer()
            Button("Submit ↩") { answer.handle(.enter) }
                .controlSize(.large)
                .disabled(!form.canSubmit)
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
        .overlay(alignment: .top) { Divider().overlay(FocusPalette.line) }
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
            bigTextBox(
                text: Binding(get: { answer.card?.form?.drafts[index].otherText ?? "" }, set: { answer.setFormOtherText($0, of: index) }),
                note: OtherAnswerText.note(for: form.drafts[index].otherText), fit: fit,
                onSubmit: { answer.handle(.enter) }, onLeave: { answer.releaseFormTextField() }
            )
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
                FocusGoToButton(session: session).controlSize(.large)
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
                .padding(.bottom, fit.body * 0.6)
            }
        }
    }

    // MARK: - Large plan

    /// A plan-approval box, big: the plan (Markdown, scrolls) in its box, then — fixed below it — the box's
    /// question, its own rows verbatim, the feedback box when that row is chosen, and the action button.
    /// Every click / send is `PermissionCardModel`'s (`clickPlanOption`, `setFeedbackText`, `pressSend`).
    private func bigPlan(_ card: PermissionCard, _ plan: PlanCardState) -> some View {
        let fit = FocusTextFit.base
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("PLAN")
                        .font(.avenir(size: 13, weight: .semibold))
                        .kerning(0.8)
                        .foregroundStyle(FocusPalette.mute)
                    if let path = plan.prompt.planPath {
                        Text(path)
                            .font(.avenirMono(size: 12))
                            .foregroundStyle(FocusPalette.mute)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                ScrollView {
                    planText(card.planFile)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 8)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(FocusPalette.panel))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(FocusPalette.accent.opacity(0.35)))
            .layoutPriority(0)

            VStack(alignment: .leading, spacing: 12) {
                Text(plan.prompt.title)
                    .font(.avenir(size: fit.question, weight: .semibold))
                    .foregroundStyle(FocusPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = plan.changedNote { errorLine(note, fit: fit) }
                if let warning = card.sentWarning {
                    Text(warning).font(.avenir(size: 15, weight: .medium)).foregroundStyle(WarningTextColor.color)
                }
                switch plan.phase {
                case .checking:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking the terminal's prompt before you answer…")
                    }
                    .font(.avenir(size: 16))
                    .foregroundStyle(FocusPalette.mute)
                case .unavailable(let reason):
                    errorLine(reason, fit: fit)
                    FocusGoToButton(session: session).controlSize(.large)
                case .ready:
                    VStack(spacing: 6) {
                        ForEach(plan.options, id: \.index) { option in
                            optionRow(
                                number: option.index, title: option.label, detail: "",
                                isHighlighted: plan.highlightedIndex == option.index, isChecked: false, fit: fit
                            ) { permission.clickPlanOption(index: option.index) }
                        }
                    }
                    if plan.isTypingFeedback {
                        bigTextBox(
                            text: Binding(get: { permission.card?.plan?.feedbackText ?? "" }, set: { permission.setFeedbackText($0) }),
                            note: plan.isFeedbackTooLong ? PlanCardState.feedbackTooLongNote : PlanCardState.feedbackNote,
                            fit: fit, onSubmit: { permission.pressSend() }, onLeave: { permission.handle(.escape) }
                        )
                    }
                }
                if let confirm = plan.confirmText { errorLine(confirm, fit: fit) }
                HStack {
                    Spacer()
                    if !Self.isUnavailable(plan.phase) {
                        Button("\(plan.actionTitle) ↩") { permission.pressSend() }
                            .controlSize(.large)
                            .disabled(!plan.canSend)
                            .tint(plan.isConfirmingPrivilege ? .red : nil)
                    }
                }
                .padding(.bottom, 12)
            }
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
        }
    }

    private static func isUnavailable(_ phase: PlanCardState.Phase) -> Bool {
        if case .unavailable = phase { return true }
        return false
    }

    @ViewBuilder
    private func planText(_ file: PlanFile) -> some View {
        switch file {
        case .loading:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading the plan…") }
                .font(.avenir(size: 17)).foregroundStyle(FocusPalette.mute)
        case .noPath:
            Text("The terminal does not name the plan file, so it cannot be shown here. You can still answer below.")
                .font(.avenir(size: 17)).foregroundStyle(FocusPalette.mute)
        case .unreadable(let reason):
            Text("The plan cannot be shown here. \(reason) You can still answer below.")
                .font(.avenir(size: 17)).foregroundStyle(FocusPalette.mute)
        case .text(let text, let truncated):
            MarkdownBlocksView(blocks: MarkdownParser.parse(text), bodySize: 18)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .id(text)
            if truncated {
                Text("The plan is longer than \(PlanFileReader.maxBytes / 1024) KB: the rest is not shown.")
                    .font(.avenir(size: 15)).foregroundStyle(FocusPalette.mute)
            }
        }
    }

    /// A typed answer box in large type (Other, plan feedback): the shared `MultiLineAnswerField`
    /// (↩ sends, ⇧↩ line, Esc back to the rows). The hidden measuring copy gets a spacer, never a box.
    @ViewBuilder
    private func bigTextBox(text: Binding<String>, note: String?, fit: FocusTextFit,
                            onSubmit: @escaping () -> Void, onLeave: @escaping () -> Void) -> some View {
        let height = fit.body * 3.4
        VStack(alignment: .leading, spacing: 6) {
            if fit.isMeasuring {
                Color.clear.frame(height: height)
            } else {
                ZStack(alignment: .topLeading) {
                    MultiLineAnswerField(text: text, onSubmit: onSubmit, onLeave: onLeave, fontSize: fit.body * 0.9)
                    if text.wrappedValue.isEmpty {
                        Text("Type your answer   ↩ sends")
                            .font(.avenir(size: fit.body * 0.9))
                            .foregroundStyle(FocusPalette.mute)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: 12).fill(FocusPalette.panel))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(FocusPalette.accent.opacity(0.4)))
            }
            if let note, !note.isEmpty {
                Text(note).font(.avenir(size: max(12, fit.body * 0.6))).foregroundStyle(FocusPalette.mute)
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
            FocusGoToButton(session: session).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "Go to <home> ⌘↩" (`FocusDestination`): pauses Focus mode and switches to the agent. A home that
/// cannot be reached shows a disabled button whose title is the reason ("Runs on Air", "No known home").
struct FocusGoToButton: View {
    @ObservedObject var session: FocusSession

    var body: some View {
        if let destination = session.destination {
            Button(action: session.goToAgent) {
                Label(destination.isEnabled ? "\(destination.buttonTitle)  ⌘↩" : destination.buttonTitle,
                      systemImage: destination.isEnabled ? "arrow.up.forward.app" : "nosign")
            }
            .disabled(!destination.isEnabled)
            .help(destination.reason ?? "Switch to this agent; Focus mode pauses (⌥⇧F resumes)")
        }
    }
}
