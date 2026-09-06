import UIKit
import UniformTypeIdentifiers
import Combine

/// 系统分享入口（Share Extension）——卡片式界面。
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

    // MARK: - UI 组件（卡片式）

    /// 附件横向滚动区（每张附件一张卡片）。
    private let attachScrollView: UIScrollView = {
        let s = UIScrollView()
        s.showsHorizontalScrollIndicator = false
        s.translatesAutoresizingMaskIntoConstraints = false
        s.isHidden = true
        return s
    }()

    private let attachStack: UIStackView = {
        let s = UIStackView()
        s.axis = .horizontal
        s.spacing = 10
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    private let textView: UITextView = {
        let v = UITextView()
        v.font = .systemFont(ofSize: 16)
        v.layer.borderWidth = 1
        v.layer.borderColor = UIColor.separator.cgColor
        v.layer.cornerRadius = 12
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    /// 输入框占位符（textView 原生不带，用浮层实现）。
    private let placeholderLabel: UILabel = {
        let l = UILabel()
        l.text = String(localized: "share_prompt_placeholder")
        l.font = .systemFont(ofSize: 16)
        l.textColor = .placeholderText
        l.numberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        l.isUserInteractionEnabled = false
        return l
    }()

    private let sendButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = String(localized: "share_send_title")
        config.cornerStyle = .large
        config.baseBackgroundColor = .systemBlue
        config.baseForegroundColor = .white
        let b = UIButton(configuration: config)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let hintLabel: UILabel = {
        let l = UILabel()
        l.text = String(localized: "share_hint")
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabel
        l.numberOfLines = 0
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    /// 随任务一起带过去的附件（共享目录内的文件名）。
    private var attachmentNames: [String] = []
    /// 抽取出的正文 / URL（发送前可编辑）。
    private var extractedText: String = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "MiniClaw"
        textView.delegate = self

        let stack = UIStackView(arrangedSubviews: [attachScrollView,textView,sendButton,hintLabel])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        textView.addSubview(placeholderLabel)
        // 必须先把卡片栈加进滚动视图：跨层级激活约束会抛
        // NSInternalInconsistencyException，扩展进程起不来（表现为分享界面根本
        // 不出现）——卡片式重设计第一版就栽在这里。
        attachScrollView.addSubview(attachStack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor,constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor,constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor,constant: -20),

            attachScrollView.heightAnchor.constraint(equalToConstant: 76),
            attachStack.leadingAnchor.constraint(equalTo: attachScrollView.contentLayoutGuide.leadingAnchor,constant: 4),
            attachStack.trailingAnchor.constraint(equalTo: attachScrollView.contentLayoutGuide.trailingAnchor,constant: -4),
            attachStack.topAnchor.constraint(equalTo: attachScrollView.contentLayoutGuide.topAnchor,constant: 4),
            attachStack.bottomAnchor.constraint(equalTo: attachScrollView.contentLayoutGuide.bottomAnchor,constant: -4),
            attachStack.heightAnchor.constraint(equalToConstant: 68),

            textView.heightAnchor.constraint(equalToConstant: 120),
            placeholderLabel.topAnchor.constraint(equalTo: textView.contentLayoutGuide.topAnchor,constant: 8),
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.contentLayoutGuide.leadingAnchor,constant: 6),
            placeholderLabel.trailingAnchor.constraint(equalTo: textView.contentLayoutGuide.trailingAnchor,constant: -8),

            sendButton.heightAnchor.constraint(equalToConstant: 50),
        ])

        sendButton.addAction(UIAction { [weak self] _ in self?.sendTapped() },for: .touchUpInside)

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        Task { @MainActor [weak self] in
            guard let self else { return }
            let (text,names) = await Self.extract(items: items)
            self.extractedText = text
            self.attachmentNames = names
            self.textView.text = text
            self.refreshPlaceholder()
            self.renderAttachmentCards(names: names)
        }
    }

    // MARK: - 发送

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

    // MARK: - 附件卡片

    /// 每个附件渲染一张卡：类型图标 + 文件名 + 体积。
    private func renderAttachmentCards(names: [String]) {
        guard !names.isEmpty else { return }
        attachScrollView.isHidden = false
        for name in names {
            let card = UIView()
            card.backgroundColor = .secondarySystemBackground
            card.layer.cornerRadius = 12

            let icon = UIImage(systemName: Self.iconName(for: name))
            let iconView = UIImageView(image: icon)
            iconView.tintColor = .systemBlue
            iconView.contentMode = .scaleAspectFit
            iconView.translatesAutoresizingMaskIntoConstraints = false

            let nameView = UILabel()
            nameView.text = Self.displayName(for: name)
            nameView.font = .systemFont(ofSize: 13,weight: .medium)
            nameView.lineBreakMode = .byTruncatingMiddle
            nameView.translatesAutoresizingMaskIntoConstraints = false

            let sizeView = UILabel()
            sizeView.text = Self.fileSizeText(for: name)
            sizeView.font = .systemFont(ofSize: 11)
            sizeView.textColor = .secondaryLabel
            sizeView.translatesAutoresizingMaskIntoConstraints = false

            let v = UIStackView(arrangedSubviews: [nameView,sizeView])
            v.axis = .vertical
            v.spacing = 3
            v.translatesAutoresizingMaskIntoConstraints = false

            card.addSubview(iconView)
            card.addSubview(v)
            NSLayoutConstraint.activate([
                card.widthAnchor.constraint(equalToConstant: 210),
                iconView.leadingAnchor.constraint(equalTo: card.leadingAnchor,constant: 12),
                iconView.centerYAnchor.constraint(equalTo: card.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 26),
                v.leadingAnchor.constraint(equalTo: iconView.trailingAnchor,constant: 10),
                v.centerYAnchor.constraint(equalTo: card.centerYAnchor),
                v.trailingAnchor.constraint(equalTo: card.trailingAnchor,constant: -12),
            ])
            attachStack.addArrangedSubview(card)
        }
    }

    /// 卡片上展示的文件名：剥掉 UUID 防冲突前缀（shared-XXXXXXXX_）。
    private static func displayName(for storedName: String) -> String {
        guard storedName.hasPrefix("shared-"),let idx = storedName.firstIndex(of: "_") else {
            return storedName
        }
        return String(storedName[storedName.index(after: idx)...])
    }

    private static func fileSizeText(for name: String) -> String {
        guard let dir = SharedInbox.fileDirectory else { return "" }
        let attrs = try? FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent(name).path)
        let bytes = (attrs?[.size] as? Int64) ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes,countStyle: .file)
    }

    /// 按扩展名挑 SF Symbol（未识别的回落通用文档图标）。
    private static func iconName(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg","jpeg","png","gif","webp","heic": return "photo.fill"
        case "mov","mp4","m4v","avi","mkv","webm": return "video.fill"
        case "mp3","m4a","wav","aac","ogg","flac": return "waveform"
        case "zip","mpk","tar","gz": return "doc.zipper"
        case "pdf": return "doc.richtext.fill"
        default: return "doc.fill"
        }
    }

    private func refreshPlaceholder() {
        placeholderLabel.isHidden = !(textView.text ?? "").isEmpty
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

extension ShareViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        refreshPlaceholder()
    }
}
