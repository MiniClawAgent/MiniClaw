import Foundation
import SwiftData

/// 会话产物层：负责读取会话的附件 / 文件（只读）。
final class ArtifactStore {
    let store: SessionStore

    init(store: SessionStore) {
        self.store = store
    }

    /// 列出某会话所有消息中引用的附件路径。
    func list(ref: String?) -> String {
        guard let ref, let uuid = UUID(uuidString: ref), let s = store.session(id: uuid) else {
            return fail("artifacts 需要有效的会话 id")
        }
        var items: [[String: Any]] = []
        for m in s.messages {
            for att in m.attachments {
                items.append([
                    "messageId": m.id.uuidString,
                    "role": m.roleRaw,
                    "path": att
                ])
            }
        }
        return prettyJSON([
            "id": ref,
            "artifactCount": items.count,
            "artifacts": items
        ])
    }
}
