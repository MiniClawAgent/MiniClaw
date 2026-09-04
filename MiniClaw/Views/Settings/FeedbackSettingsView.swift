import SwiftUI

// MARK: - Feedback View

struct FeedbackView: View {
    @State private var feedbackType: String = "bug"
    @State private var feedbackContent: String = ""
    @State private var includeLogs: Bool = true

    private let feedbackTypes = ["bug", "feature", "improvement", "other"]

    var body: some View {
        Form {
            Section(String(localized: "feedback_type")) {
                Picker(String(localized: "type"), selection: $feedbackType) {
                    Text(String(localized: "bug_report")).tag("bug")
                    Text(String(localized: "feature_suggestion")).tag("feature")
                    Text(String(localized: "usage_improvements")).tag("improvement")
                    Text(String(localized: "others")).tag("other")
                }
            }

            Section(String(localized: "detailed_description")) {
                TextEditor(text: $feedbackContent)
                    .frame(minHeight: 150)
            }

            Section {
                Toggle(String(localized: "include_daily_memory"), isOn: $includeLogs)
            } footer: {
                Text(String(localized: "logs_help_developers_quickly_pinpoint_issues"))
            }

            Section {
                Button(action: {}) {
                    HStack {
                        Spacer()
                        Label(String(localized: "submit_feedback"), systemImage: "paperplane.fill")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(feedbackContent.isEmpty)
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(String(localized: "feedback"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
