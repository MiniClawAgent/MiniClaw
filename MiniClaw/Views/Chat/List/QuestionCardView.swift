import SwiftUI

/// AI 提问卡片（`ask_user` 的渲染）。
///
/// 设计取舍（唐唐 2026-11-16 定 2A）：卡片长在**消息流里**，不抢占输入框：
/// 不打断正在输入的草稿，历史里也能回看"当时问了什么、我选了什么"。
struct QuestionCardView: View {
    @ObservedObject var block: AssistantBlock
    /// 必须观察 broker：卡片的按钮显隐取决于"当前是否真的有等待中的请求"，
    /// 而请求是在卡片出现之后才登记的（block 先被挂载）。
    @ObservedObject private var broker = AskUserBroker.shared
    let callId: String

    @State private var selected: [String: Set<String>] = [:]
    @State private var custom: [String: String] = [:]
    @State private var submitted = false

    private var request: UserQuestionRequest? {
        UserQuestionRequest.decode(from: block.content)
    }

    private var isPending: Bool {
        request?.state == .pending && !submitted && AskUserBroker.shared.pending[callId] != nil
    }

    var body: some View {
        if let request {
            VStack(alignment: .leading, spacing: 12) {
                header(request)
                if request.state == .pending && !submitted {
                    ForEach(request.questions) { q in
                        questionBlock(q)
                    }
                } else {
                    answerSummary(request)
                }
                if isPending {
                    footer(request)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(isPending ? 0.45 : 0.15), lineWidth: 1)
            )
            .padding(.vertical, 2)
            .onAppear(perform: applyDefaults)
        }
    }

    // MARK: - 头尾

    private func header(_ request: UserQuestionRequest) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "questionmark.bubble.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
            Text(request.questions.first?.header ?? String(localized: "ask_user_title"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            stateBadge(request)
        }
    }

    @ViewBuilder
    private func stateBadge(_ request: UserQuestionRequest) -> some View {
        switch request.state {
        case .pending:
            Text(String(localized: "ask_user_waiting"))
                .font(.caption2)
                .foregroundStyle(Color.accentColor)
        case .answered:
            Label(String(localized: "ask_user_answered"), systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green)
        case .skipped:
            Label(String(localized: "ask_user_skipped"), systemImage: "arrow.uturn.forward.circle")
                .font(.caption2).foregroundStyle(.secondary)
        case .expired:
            Label(String(localized: "ask_user_expired"), systemImage: "clock.badge.exclamationmark")
                .font(.caption2).foregroundStyle(.orange)
        case .cancelled:
            Label(String(localized: "ask_user_cancelled"), systemImage: "xmark.circle")
                .font(.caption2).foregroundStyle(.secondary)
        case .failed:
            Label(String(localized: "ask_user_failed"), systemImage: "exclamationmark.triangle")
                .font(.caption2).foregroundStyle(.red)
        }
    }

    private func footer(_ request: UserQuestionRequest) -> some View {
        HStack {
            Button(String(localized: "ask_user_skip")) {
                submitted = true
                AskUserBroker.shared.submit(callId: callId, answers: [])
            }
            .buttonStyle(.borderless)
            .font(.system(size: 13))

            Spacer()

            Button(String(localized: "ask_user_submit")) {
                submitted = true
                AskUserBroker.shared.submit(callId: callId, answers: collectAnswers(request))
            }
            .buttonStyle(.borderedProminent)
            .font(.system(size: 13, weight: .semibold))
            .disabled(!hasAnySelection(request))
        }
    }

    // MARK: - 问题

    private func questionBlock(_ q: UserQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(q.question)
                .font(.system(size: 15, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            if let detail = q.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let options = q.options, !options.isEmpty {
                VStack(spacing: 6) {
                    ForEach(options) { option in
                        optionRow(q: q, option: option)
                    }
                }
            }
            if q.allowCustom ?? true {
                TextField(String(localized: "ask_user_custom_placeholder"),
                          text: Binding(
                            get: { custom[q.id] ?? "" },
                            set: { custom[q.id] = $0 }
                          ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
            }
        }
    }

    private func optionRow(q: UserQuestion, option: UserQuestionOption) -> some View {
        let isOn = selected[q.id]?.contains(option.label) ?? false
        return Button {
            toggle(q: q, label: option.label)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isOn
                      ? ((q.multiSelect ?? false) ? "checkmark.square.fill" : "largecircle.fill.circle")
                      : ((q.multiSelect ?? false) ? "square" : "circle"))
                    .font(.system(size: 14))
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    if let d = option.description, !d.isEmpty {
                        Text(d)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isOn ? Color.accentColor.opacity(0.12) : Color(uiColor: .tertiarySystemBackground))
            )
        }
        .buttonStyle(.plain)
    }

    private func answerSummary(_ request: UserQuestionRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(request.questions) { q in
                let a = request.answers?.first { $0.id == q.id }
                let text = (a?.selected ?? []).joined(separator: "、")
                let custom = a?.custom ?? ""
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(q.question).font(.system(size: 13)).foregroundStyle(.secondary)
                        Text([text, custom].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 14, weight: .medium))
                    }
                }
            }
        }
    }

    // MARK: - 状态

    private func applyDefaults() {
        guard let request, selected.isEmpty else { return }
        for q in request.questions {
            guard let options = q.options else { continue }
            // 推荐项默认选中：单选取第一个推荐，多选取全部推荐（对齐 DSH 的交互）。
            let recommended = options.filter { $0.label.contains("推荐") || $0.label.lowercased().contains("recommended") }
            if q.multiSelect ?? false {
                if !recommended.isEmpty { selected[q.id] = Set(recommended.map(\.label)) }
            } else if let first = recommended.first {
                selected[q.id] = [first.label]
            }
        }
    }

    private func toggle(q: UserQuestion, label: String) {
        if q.multiSelect ?? false {
            var set = selected[q.id] ?? []
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
            selected[q.id] = set
        } else {
            selected[q.id] = [label]
        }
    }

    private func hasAnySelection(_ request: UserQuestionRequest) -> Bool {
        request.questions.contains { q in
            !(selected[q.id] ?? []).isEmpty || !(custom[q.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func collectAnswers(_ request: UserQuestionRequest) -> [UserQuestionAnswer] {
        request.questions.map { q in
            UserQuestionAnswer(id: q.id,
                               selected: Array(selected[q.id] ?? []),
                               custom: (custom[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }.filter { !$0.selected.isEmpty || !($0.custom ?? "").isEmpty }
    }
}
