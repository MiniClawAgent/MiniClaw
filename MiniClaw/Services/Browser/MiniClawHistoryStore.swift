import Foundation
import SwiftUI
import os.log

struct BrowserHistoryEntry: Identifiable,Codable {
    public let id: UUID
    public let url: String
    public let title: String
    public let timestamp: Date

    init(url: String,title: String,timestamp: Date = Date()) {
        self.id = UUID()
        self.url = url
        self.title = title
        self.timestamp = timestamp
    }

    public var domain: String {
        URL(string: url).flatMap(\.host) ?? url
    }
}

@MainActor
final class MiniClawHistoryStore: ObservableObject {
    public static let shared = MiniClawHistoryStore()

    @Published private(set) var entries: [BrowserHistoryEntry] = []

    private static let retentionDays = 7

    private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,in: .userDomainMask).first!
            .appendingPathComponent("MiniClaw", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,withIntermediateDirectories: true)
        return dir.appendingPathComponent("browser_history.json")
    }

    private init() {
        load()
    }

    public func record(url: String,title: String) {
        guard !url.isEmpty, url != "about:blank" else { return }

        if let last = entries.first,last.url == url { return }

        let entry = BrowserHistoryEntry(url: url,title: title)
        entries.insert(entry,at: 0)
        prune()
        save()
    }

    public func clearAll() {
        entries.removeAll()
        save()
        logger.info("Browser history cleared")
    }

    public var groupedByDay: [(date: Date,entries: [BrowserHistoryEntry])] {
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day,value: -Self.retentionDays,to: Date()) ?? Date()
        let recent = entries.filter { $0.timestamp >= cutoff }
        let grouped = Dictionary(grouping: recent) { entry in
            calendar.startOfDay(for: entry.timestamp)
        }
        return grouped.sorted { $0.key>$1.key }
            .map { (date: $0.key,entries: $0.value.sorted { $0.timestamp>$1.timestamp }) }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: Self.storeURL,options: .atomic)
        } catch {
            logger.error("Failed to save browser history: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: Self.storeURL.path) else { return }
        do {
            let data = try Data(contentsOf: Self.storeURL)
            let decoder = JSONDecoder()
            entries = try decoder.decode([BrowserHistoryEntry].self,from: data)
            let before = entries.count
            prune()
            if entries.count != before { save() }
            logger.info("Loaded \(self.entries.count) history entries")
        } catch {
            logger.error("Failed to load browser history: \(error.localizedDescription)")
        }
    }

    private func prune() {
        let cutoff = Calendar.current.date(byAdding: .day,value: -Self.retentionDays,to: Date()) ?? Date()
        entries.removeAll { $0.timestamp<cutoff }
    }
}

private let logger = AppLogger(category: "BrowserHistory")
