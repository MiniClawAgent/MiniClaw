import SwiftUI
import SwiftData

struct SearchView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChatSession.updatedAt, order: .reverse) private var sessions: [ChatSession]

    @State private var searchText: String = ""
    @State private var searchResults: [ChatSession] = []

    var body: some View {
        List {
            if searchText.isEmpty {
                Section(L10n.tr("最近会话")) {
                    ForEach(sessions.prefix(10)) { session in
                        SessionRowView(session: session)
                    }
                }
            } else if searchResults.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ForEach(searchResults) { session in
                    SessionRowView(session: session)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(Text(L10n.tr("搜索")))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: L10n.tr("搜索会话..."))
        .onChange(of: searchText) { _, newValue in
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
