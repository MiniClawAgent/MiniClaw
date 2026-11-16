import SwiftUI

/// AI 提问卡片（`ask_user` 的渲染）。
///
/// 2026-11-16 唐唐定的四条规则：
/// 1. 卡片放在**消息流里**（不抢占输入框）；
/// 2. 用户不回答 → 5 分钟超时按"跳过"处理（超时在 AskUserBroker）；
/// 3. **一次一题**，带「第 n / N 题」进度；
/// 4. 答完收成**一行小字**，点击展开详情；操作只有「跳过」（无"放弃全部"）。
struct QuestionCardView: View {
    @ObservedObject var block: AssistantBlock
    @ObservedObject private var broker = AskUserBroker.shared
    let callId: String

    /// 当前题号（一次一题）。
    @State private var index = 0
    @State private var selected: [String: Set<String>] = [:]
    @State private var custom: [String: String] = [:]
    @State private var submitted = false
    /// 答完后的展开态（默认收起成一行）。
    @State private var expanded = false

    private var request: UserQuestionRequest? {
        UserQuestionRequest.decode(from: block.content)
    }

    var body: some View {
        if let request {
            if request.state == .pending && !submitted {
                activeCard(request)
            } else {
                resultLine(request)
            }
        }
    }

    // MARK: - 答题中

    private func activeCard(_ request: UserQuestionRequest) -> some View {
        let total = max(1, request.questions.count)
        let q = request.questions[min(index, total - 1)]
        return VStack(alignment: .leading, spacing: 12) {
            header(request, index: index, total: total)
            questionBlock(q)
            footer(request, isLast: index >= total - 1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
        )
        .padding(.vertical, 2)
        .onAppear(perform: applyDefaults)
    }

    private func header(_ request: UserQuestionRequest, index: Int, total: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "questionmark.bubble.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
            Text(request.questions[min(index, request.questions.count - 1)].header
                 ?? String(localized: "ask_user_title"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(index + 1) / \(total)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

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
                          text: Binding(get: { custom[q.id] ?? "" },
                                        set: { custom[q.id] = $0 }))
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

    private func footer(_ request: UserQuestionRequest, isLast: Bool) -> some View {
        HStack {
            // 唯一的否定动作：跳过（最后一题跳过 = 提交）。
            Button(String(localized: "ask_user_skip")) {
                advance(request)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 13))

            Spacer()

            Button(isLast ? String(localized: "ask_user_submit") : String(localized: "ask_user_next")) {
                advance(request)
            }
            .buttonStyle(.borderedProminent)
            .font(.system(size: 13, weight: .semibold))
            .disabled(!hasAnswer(request, at: index))
        }
    }

    // MARK: - 答完

    private func resultLine(_ request: UserQuestionRequest) -> some View {
        let answered = request.questions.filter { q in
            guard let a = request.answers?.first(where: { $0.id == q.id }) else { return false }
            return !a.selected.isEmpty || !(a.custom?.isEmpty ?? true)
        }.count
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            notifyLayoutChanged()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                    Text(String(format: String(localized: "ask_user_result_line"),
                                answered, request.questions.count))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(request.questions) { q in
                        let a = request.answers?.first { $0.id == q.id }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(q.question)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Text(answerText(a))
                                .font(.system(size: 13))
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemBackground).opacity(0.6))
        )
    }

    private func answerText(_ a: UserQuestionAnswer?) -> String {
        guard let a else { return String(localized: "ask_user_skipped") }
        let parts = [a.selected.joined(separator: "、"), a.custom ?? ""].filter { !$0.isEmpty }
        return parts.isEmpty ? String(localized: "ask_user_skipped") : parts.joined(separator: " · ")
    }

    // MARK: - 状态

    private func applyDefaults() {
        guard let request, selected.isEmpty else { return }
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

    private func toggle(q: UserQuestion, label: String) {
        if q.multiSelect ?? false {
            var set = selected[q.id] ?? []
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
            selected[q.id] = set
        } else {
            selected[q.id] = [label]
        }
    }

    private func hasAnswer(_ request: UserQuestionRequest, at index: Int) -> Bool {
        guard index < request.questions.count else { return false }
        let q = request.questions[index]
        return !(selected[q.id] ?? []).isEmpty
            || !(custom[q.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 跳过或作答后的推进：非最后一题翻页，最后一题提交。
    private func advance(_ request: UserQuestionRequest) {
        if index < request.questions.count - 1 {
            withAnimation(.easeInOut(duration: 0.15)) { index += 1 }
        } else {
            submitted = true
            broker.submit(callId: callId, answers: collectAnswers(request))
            notifyLayoutChanged()
        }
    }

    /// 形态变了 ⇒ 该行高度要重测（否则收起后仍占着展开时的高度）。
    private func notifyLayoutChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .chatQuestionCardLayoutChanged,
                                           object: block.id.uuidString)
        }
    }

    /// 提交时**包含跳过的题**（空数组），模型才能知道哪题被跳过。
    private func collectAnswers(_ request: UserQuestionRequest) -> [UserQuestionAnswer] {
        request.questions.map { q in
            UserQuestionAnswer(
                id: q.id,
                selected: Array(selected[q.id] ?? []),
                custom: (custom[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
