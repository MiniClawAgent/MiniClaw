import SwiftUI

struct SearchView: View {
    @Environment(\.dismiss) private var dismiss
    /// 会话列表：来自 SessionManager 内存态（启动全量加载,变更即时落盘）。
    private var sessions: [ChatSession] { SessionManager.shared.sessions }

    @State private var searchText: String = ""
    @State private var searchResults: [ChatSession] = []

    var body: some View {
        List {
            if searchText.isEmpty {
                Section(String(localized: "recent_sessions")) {
                    ForEach(sessions.prefix(10)) { session in
                        SessionRowView(session: session)
                    }
                }
            } else if searchResults.isEmpty {
                EmptyStateView.search(text: searchText)
            } else {
                ForEach(searchResults) { session in
                    SessionRowView(session: session)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(Text(String(localized: "search")))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: String(localized: "search_sessions"))
        .onChange(of: searchText) { newValue in
            if newValue.isEmpty {
                searchResults = []
            } else {
                searchResults = sessions.filter { session in
                    session.title.localizedCaseInsensitiveContains(newValue) ||
                    session.messages.contains { $0.content.localizedCaseInsensitiveContains(newValue) }
                }
            }
        }
    }
}
