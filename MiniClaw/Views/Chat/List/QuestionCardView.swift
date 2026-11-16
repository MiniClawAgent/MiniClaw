import SwiftUI

/// AI 提问的**授权式弹窗**（不占会话流高度）。
///
/// 2026-11-16 唐唐定的形态：
/// - 提问不内嵌在消息流里，用居中弹窗（类似系统授权框）；
/// - 会话里只保留一条 `ask_user` 工具指示器；
/// - 一次一题、右上角进度；操作只有「跳过」；答完弹窗消失；
/// - 5 分钟不答由 broker 超时按跳过处理。
struct AskUserDialog: View {
    @ObservedObject private var broker = AskUserBroker.shared

    let callId: String
    let request: UserQuestionRequest

    @State private var index = 0
    @State private var selected: [String: Set<String>] = [:]
    @State private var custom: [String: String] = [:]

    private var total: Int { max(1, request.questions.count) }
    private var current: UserQuestion { request.questions[min(index, total - 1)] }
    private var isLast: Bool { index >= total - 1 }

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { }   // 点遮罩不关闭：必须显式跳过或提交

            VStack(alignment: .leading, spacing: 14) {
                header
                questionBlock
                footer
            }
            .padding(18)
            .frame(maxWidth: 420)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
            .padding(.horizontal, 24)
        }
        .onAppear(perform: applyDefaults)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.bubble.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
            Text(current.header ?? String(localized: "ask_user_title"))
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Text("\(index + 1) / \(total)")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var questionBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(current.question)
                .font(.system(size: 15, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)

            if let detail = current.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let options = current.options, !options.isEmpty {
                VStack(spacing: 6) {
                    ForEach(options) { option in
                        optionRow(option)
                    }
                }
            }

            if current.allowCustom ?? true {
                TextField(String(localized: "ask_user_custom_placeholder"),
                          text: Binding(get: { custom[current.id] ?? "" },
                                        set: { custom[current.id] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
            }
        }
    }

    private func optionRow(_ option: UserQuestionOption) -> some View {
        let isOn = selected[current.id]?.contains(option.label) ?? false
        return Button {
            toggle(option.label)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isOn
                      ? ((current.multiSelect ?? false) ? "checkmark.square.fill" : "largecircle.fill.circle")
                      : ((current.multiSelect ?? false) ? "square" : "circle"))
                    .font(.system(size: 14))
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                    if let d = option.description, !d.isEmpty {
                        Text(d)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isOn ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "ask_user_timeout_hint"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            HStack {
                Button(String(localized: "ask_user_skip")) { advance() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 14))
                Spacer()
                Button(isLast ? String(localized: "ask_user_submit")
                              : String(localized: "ask_user_next")) { advance() }
                    .buttonStyle(.borderedProminent)
                    .font(.system(size: 14, weight: .semibold))
                    .disabled(!hasAnswer)
            }
        }
    }

    private var hasAnswer: Bool {
        !(selected[current.id] ?? []).isEmpty
            || !(custom[current.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func applyDefaults() {
        guard selected.isEmpty else { return }
        for q in request.questions {
            guard let options = q.options else { continue }
            let recommended = options.filter {
                $0.label.contains("推荐") || $0.label.lowercased().contains("recommended")
            }
            if q.multiSelect ?? false {
                if !recommended.isEmpty { selected[q.id] = Set(recommended.map(\.label)) }
            } else if let first = recommended.first {
                selected[q.id] = [first.label]
            }
        }
    }

    private func toggle(_ label: String) {
        if current.multiSelect ?? false {
            var set = selected[current.id] ?? []
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
            selected[current.id] = set
        } else {
            selected[current.id] = [label]
        }
    }

    private func advance() {
        if !isLast {
            withAnimation(.easeInOut(duration: 0.15)) { index += 1 }
            return
        }
        broker.submit(callId: callId, answers: collectAnswers())
    }

    private func collectAnswers() -> [UserQuestionAnswer] {
        request.questions.map { q in
            UserQuestionAnswer(
                id: q.id,
                selected: Array(selected[q.id] ?? []),
                custom: (custom[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}

/// 工具详情里的 `ask_user` 记录：只列「问题 → 回答」，不展示原始 JSON。
struct AskUserSummarySheet: View {
    let content: String

    private var request: UserQuestionRequest? {
        UserQuestionRequest.decode(from: content)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let request {
                        ForEach(Array(request.questions.enumerated()), id: \.element.id) { idx, q in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(idx + 1). \(q.question)")
                                    .font(.system(size: 15, weight: .medium))
                                    .fixedSize(horizontal: false, vertical: true)

                                let answer = answerText(request, q)
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: answer.skipped
                                          ? "arrow.turn.down.right" : "checkmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(answer.skipped ? Color.secondary : Color.green)
                                    Text(answer.text)
                                        .font(.system(size: 14))
                                        .foregroundStyle(answer.skipped ? Color.secondary : Color.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(uiColor: .secondarySystemBackground))
                            )
                        }
                    } else {
                        Text(String(localized: "ask_user_title"))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            .navigationTitle(String(localized: "ask_user_title"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func answerText(_ request: UserQuestionRequest,
                            _ q: UserQuestion) -> (text: String, skipped: Bool) {
        guard let a = request.answers?.first(where: { $0.id == q.id }),
              !a.selected.isEmpty || !(a.custom?.isEmpty ?? true) else {
            return (String(localized: "ask_user_skipped"), true)
        }
        var parts = a.selected
        if let c = a.custom, !c.isEmpty { parts.append(c) }
        return (parts.joined(separator: " · "), false)
    }
}
