import UIKit
import UniformTypeIdentifiers

/// 系统分享入口（Share Extension）。
///
/// 关键约束：iOS 上 **Share Extension 无法用 `extensionContext.open` 唤起宿主
/// App**（官方仅 Today / iMessage 扩展点支持；Share Extension 恒失败且
/// completion 常不回调——旧实现把 `completeRequest` 写在 completion 里，表现
/// 就是「点了发送毫无反应、面板也不收起」）。
///
/// 现行链路（方法与 OpenMinis 同思路，实现为自有代码）：
///   扩展：抽取内容 → 文件**复制**进 App Group 共享目录 → 写 PendingTaskShare
///        → completeRequest（立即收起面板）
///   主 App：深链 / 冷启动 / 前台激活时读收件箱 → 建会话 → 走既有深链派发
///        （P1-4）执行
/// 文件走共享目录实体搬运，绝不下发别的 App 沙盒路径——那种路径主 App 读不到。
final class ShareViewController: UIViewController {

    private let hintLabel: UILabel = {
        let l = UILabel()
        l.text = String(localized: "share_hint")
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabel
        l.numberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let textView: UITextView = {
        let v = UITextView()
        v.font = .systemFont(ofSize: 16)
        v.layer.borderWidth = 1
        v.layer.borderColor = UIColor.separator.cgColor
        v.layer.cornerRadius = 8
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let sendButton: UIButton = {
        let b = UIButton(type: .system)
        b.setTitle(String(localized: "share_send_title"),for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 17,weight: .semibold)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    /// 随任务一起带过去的附件（共享目录内的文件名）。
    private var attachmentNames: [String] = []
    /// 抽取出的正文 / URL（发送前可编辑）。
    private var extractedText: String = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "MiniClaw"
        view.addSubview(hintLabel)
        view.addSubview(textView)
        view.addSubview(sendButton)
        NSLayoutConstraint.activate([
            hintLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor,constant: 16),
            hintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor,constant: 16),
            hintLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor,constant: -16),
            textView.topAnchor.constraint(equalTo: hintLabel.bottomAnchor,constant: 12),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor,constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor,constant: -16),
            textView.heightAnchor.constraint(equalToConstant: 160),
            sendButton.topAnchor.constraint(equalTo: textView.bottomAnchor,constant: 20),
            sendButton.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
        sendButton.addTarget(self,action: #selector(sendTapped),for: .touchUpInside)

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        Task { @MainActor [weak self] in
            guard let self else { return }
            let (text,names) = await Self.extract(items: items)
            self.extractedText = text
            self.attachmentNames = names
            self.textView.text = text
            self.hintLabel.text = names.isEmpty
                ? String(localized: "share_hint")
                : String(format: String(localized: "share_hint_with_files"),names.joined(separator: "、"))
        }
    }

    @objc private func sendTapped() {
        let edited = (textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = edited.isEmpty ? extractedText : edited
        var items: [PendingTaskShare.Item] = []
        if !prompt.isEmpty { items.append(.text(prompt)) }
        items.append(contentsOf: attachmentNames.map { PendingTaskShare.Item.attachment($0) })

        // 无论成功与否都收起：绝不留一个点不动的死界面。
        if !items.isEmpty {
            SharedInbox.save(PendingTaskShare(items: items,timestamp: Date()))
        }
        extensionContext?.completeRequest(returningItems: nil,completionHandler: nil)
    }

    // MARK: - 内容抽取

    /// 抽取分享内容：文本 / 网页 URL 进正文，本地文件与图片复制进共享目录作为附件。
    /// - Returns: (正文, 附件文件名列表)
    static func extract(items: [NSExtensionItem]) async -> (String,[String]) {
        guard SharedInbox.ensureDirectory() else { return ("",[]) }
        var texts: [String] = []
        var names: [String] = []

        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                   let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
                   let url = loaded as? URL {
                    if let n = copyToShared(from: url) { names.append(n) }
                    continue
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier),
                   let url = loaded as? URL {
                    // file:// 是本地文件 → 附件；网页 URL → 正文。
                    if url.isFileURL {
                        if let n = copyToShared(from: url) { names.append(n) }
                    } else {
                        texts.append(url.absoluteString)
                    }
                    continue
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier),
                   let text = loaded as? String {
                    texts.append(text)
                    continue
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                   let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.image.identifier) {
                    if let n = saveImage(loaded) { names.append(n) }
                    continue
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier),
                   let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.data.identifier) {
                    if let url = loaded as? URL {
                        if let n = copyToShared(from: url) { names.append(n) }
                    } else if let data = loaded as? Data,
                              let n = save(data: data,suggestedName: item.attributedTitle?.string) {
                        names.append(n)
                    }
                }
            }
        }
        return (texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),names)
    }

    /// 复制本地文件到共享目录（UUID 前缀防重名冲突）。跨沙盒必须先取得
    /// 安全作用域访问权，否则读不到别的 App / File Provider 提供的文件。
    static func copyToShared(from url: URL) -> String? {
        guard let dir = SharedInbox.fileDirectory else { return nil }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let fileName = "shared-\(UUID().uuidString.prefix(8))_\(url.lastPathComponent)"
        do {
            try FileManager.default.copyItem(at: url,to: dir.appendingPathComponent(fileName))
            return fileName
        } catch {
            NSLog("[ShareExt] copy failed: \(error)")
            return nil
        }
    }

    private static func saveImage(_ loaded: Any) -> String? {
        let image: UIImage?
        if let img = loaded as? UIImage {
            image = img
        } else if let data = loaded as? Data {
            image = UIImage(data: data)
        } else if let url = loaded as? URL,let data = try? Data(contentsOf: url) {
            image = UIImage(data: data)
        } else {
            image = nil
        }
        guard let image,let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        return save(data: data,suggestedName: nil,ext: "jpg")
    }

    private static func save(data: Data,suggestedName: String?,ext: String = "bin") -> String? {
        guard let dir = SharedInbox.fileDirectory else { return nil }
        let base = (suggestedName?.isEmpty == false)
            ? (suggestedName! as NSString).deletingPathExtension : "shared"
        let fileName = "\(base)-\(UUID().uuidString.prefix(8)).\(ext)"
        do {
            try data.write(to: dir.appendingPathComponent(fileName))
            return fileName
        } catch {
            NSLog("[ShareExt] write failed: \(error)")
            return nil
        }
    }
}
