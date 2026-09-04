import SwiftUI
import UniformTypeIdentifiers

// MARK: - 智能体服务商列表

struct ProviderSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showAdd: Bool = false
    @State private var showImportFile: Bool = false

    /// 按兼容格式分类的固定顺序
    private let categoryOrder = ["openai_compatible", "anthropic_compatible", "google_gemini"]

    var body: some View {
        List {
            ForEach(categoryOrder, id: \.self) { category in
                let items = appState.providers.filter { $0.providerType.compatFormat == category }
                if !items.isEmpty {
                    Section(String(localized: String.LocalizationValue(category))) {
                        ForEach(items) { p in
                            NavigationLink {
                                ProviderDetailView(providerId: p.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(p.label.isEmpty ? p.providerType.defaultLabel : p.label)
                                        .font(.body)
                                        .fontWeight(.medium)
                                    HStack(spacing: 6) {
                                        Image(systemName: p.keyAdded ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                                            .foregroundStyle(p.keyAdded ? .green : .orange)
                                        Text(p.keyAdded ? String(localized: "key_added") : String(localized: "key_not_added"))
                                        Text("·")
                                            .foregroundStyle(.tertiary)
                                        Text(String(localized: "model_label_space") + "\(p.models.count)")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { indexSet in
                            indexSet.forEach { idx in
                                let target = items[idx]
                                appState.removeProvider(id: target.id)
                            }
                        }
                    }
                }
            }

            if appState.providers.isEmpty {
                Section {
                    Text(String(localized: "no_providers_yet"))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(String(localized: "providers"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showAdd = true
                    } label: {
                        Label(String(localized: "add_provider_button"), systemImage: "plus")
                    }
                    Button {
                        showImportFile = true
                    } label: {
                        Label(String(localized: "import_provider"), systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddProviderView()
        }
        .fileImporter(isPresented: $showImportFile, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result,
               let url = urls.first,
               let p = decodeProviderFile(url) {
                appState.updateProviders { $0.append(p) }
            }
        }
    }
}
