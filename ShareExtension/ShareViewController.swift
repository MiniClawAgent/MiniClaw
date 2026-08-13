import UIKit

/// P1-1 阶段1：Share Extension 入口。
/// 从系统分享面板接收文本 / URL / 文件，拼成 prompt，经 `miniclaw://task?prompt=`
/// 深链唤起主 App 直接执行（深链派发逻辑见 P1-4，无需本扩展感知主 App 内部）。
/// 本 target 为独立模块，仅依赖 UIKit，不引入主 App 代码（扩展不可链接主 App）。
final class ShareViewController: UIViewController {

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
        b.setTitle(String(localized: "share_send_title"), for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let hintLabel: UILabel = {
        let l = UILabel()
        l.text = String(localized: "share_hint")
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabel
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private var payload: String = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "MiniClaw"
        view.addSubview(hintLabel)
        view.addSubview(textView)
        view.addSubview(sendButton)
        NSLayoutConstraint.activate([
            hintLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            hintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            hintLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textView.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textView.heightAnchor.constraint(equalToConstant: 160),
            sendButton.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 20),
            sendButton.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        extractPayload { [weak self] text in
            self?.payload = text
            self?.textView.text = text
        }
    }

    @objc private func sendTapped() {
        let text = (textView.text?.trimmingCharacters(in: .whitespacesAndNewlines)).map { $0.isEmpty ? payload : $0 } ?? payload
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "miniclaw://task?prompt=\(encoded)") else {
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }
        // 唤起主 App 处理深链（P1-4）。open 完成后结束扩展。
        extensionContext?.open(url) { [weak self] _ in
            // @Sendable 闭包内不能直接访问 main-actor 隔离属性,切回主线程执行。
            Task { @MainActor in
                self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            }
        }
    }

    /// 从 NSExtensionItem 抽取文本 / URL / 文件名，合并为 prompt 草稿。
    private func extractPayload(completion: @escaping (String) -> Void) {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { completion(""); return }
        var result = ""
        // loadItem 回调可能并发进入,result 写入加锁保护(Swift 6 并发预检)。
        let lock = NSLock()
        let group = DispatchGroup()
        for item in items {
            for att in item.attachments ?? [] {
                let handlers: [(String, @Sendable (Any?) -> String?)] = [
                    ("public.plain-text", { $0 as? String }),
                    ("public.url", { ($0 as? URL)?.absoluteString }),
                    ("public.file-url", { ($0 as? URL)?.lastPathComponent })
                ]
                for (type, map) in handlers {
                    if att.hasItemConformingToTypeIdentifier(type) {
                        group.enter()
                        att.loadItem(forTypeIdentifier: type, options: nil) { data, _ in
                            if let s = map(data) {
                                lock.lock()
                                result += (type == "public.file-url" ? String(localized: "share_file_prefix") : "") + s + "\n"
                                lock.unlock()
                            }
                            group.leave()
                        }
                    }
                }
            }
        }
        group.notify(queue: .main) {
            completion(result.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
