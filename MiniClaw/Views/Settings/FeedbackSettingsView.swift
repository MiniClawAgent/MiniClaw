import SwiftUI

// MARK: - Feedback View

struct FeedbackView: View {
    @State private var feedbackType: String = "bug"
    @State private var feedbackContent: String = ""
    @State private var includeLogs: Bool = true

    private let feedbackTypes = ["bug", "feature", "improvement", "other"]

    var body: some View {
        Form {
            Section(L10n.l("feedback_type")) {
                Picker(L10n.l("type"), selection: $feedbackType) {
                    Text(L10n.l("bug_report")).tag("bug")
                    Text(L10n.l("feature_suggestion")).tag("feature")
                    Text(L10n.l("usage_improvements")).tag("improvement")
                    Text(L10n.l("others")).tag("other")
                }
            }

            Section(L10n.l("detailed_description")) {
                TextEditor(text: $feedbackContent)
                    .frame(minHeight: 150)
            }

            Section {
                Toggle(L10n.l("include_daily_memory"), isOn: $includeLogs)
            } footer: {
                Text(L10n.l("logs_help_developers_quickly_pinpoint_issues"))
            }

            Section {
                Button(action: {}) {
                    HStack {
                        Spacer()
                        Label(L10n.l("submit_feedback"), systemImage: "paperplane.fill")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(feedbackContent.isEmpty)
            }
        }
        .navigationTitle(L10n.l("feedback"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
