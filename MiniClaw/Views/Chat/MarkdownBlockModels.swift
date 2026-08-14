

// MARK: - Media Type

enum MediaType: Codable { case image, video, audio, code, pdf, office, html, file }

// MARK: - Table Column Alignment

/// Markdown 表格列对齐方式（由分隔行 `:---:` / `---:` / `:---` 决定）。
enum ColumnAlignment: Codable {
    case leading, center, trailing
}

// MARK: - Markdown Block Types

enum MarkdownBlock: Codable {
    case heading(level: Int, content: String, id: Int)
    case bulletList(items: [String], indent: Int, id: Int)
    case orderedList(items: [String], indent: Int, start: Int, id: Int)
    case taskList(items: [(isCompleted: Bool, content: String)], indent: Int, id: Int)
    case blockquote(content: String, id: Int)
    case table(headers: [String], rows: [[String]], alignments: [ColumnAlignment], id: Int)
    case thematicBreak(id: Int)
    case text(content: String, id: Int)
    case codeBlock(language: String, content: String, id: Int)
    case image(alt: String, url: String, id: Int)
    case video(alt: String, url: String, id: Int)
    case audio(alt: String, url: String, id: Int)
    case file(alt: String, url: String, fileType: MediaType, id: Int)

    // MARK: Codable（持久化缓存用；taskList 的元组转 TaskItem 结构编解码）
    private enum Kind: String, Codable {
        case heading, bulletList, orderedList, taskList, blockquote, table,
             thematicBreak, text, codeBlock, image, video, audio, file
    }
    private struct TaskItem: Codable {
        let isCompleted: Bool
        let content: String
    }
    private enum CodingKeys: String, CodingKey {
        case kind, level, content, items, indent, start, headers, rows, alignments,
             language, alt, url, fileType, id
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .heading(let lv, let ct, let id):
            try c.encode(Kind.heading, forKey: .kind)
            try c.encode(lv, forKey: .level); try c.encode(ct, forKey: .content); try c.encode(id, forKey: .id)
        case .bulletList(let items, let indent, let id):
            try c.encode(Kind.bulletList, forKey: .kind)
            try c.encode(items, forKey: .items); try c.encode(indent, forKey: .indent); try c.encode(id, forKey: .id)
        case .orderedList(let items, let indent, let start, let id):
            try c.encode(Kind.orderedList, forKey: .kind)
            try c.encode(items, forKey: .items); try c.encode(indent, forKey: .indent)
            try c.encode(start, forKey: .start); try c.encode(id, forKey: .id)
        case .taskList(let items, let indent, let id):
            try c.encode(Kind.taskList, forKey: .kind)
            try c.encode(items.map { TaskItem(isCompleted: $0.isCompleted, content: $0.content) }, forKey: .items)
            try c.encode(indent, forKey: .indent); try c.encode(id, forKey: .id)
        case .blockquote(let ct, let id):
            try c.encode(Kind.blockquote, forKey: .kind)
            try c.encode(ct, forKey: .content); try c.encode(id, forKey: .id)
        case .table(let headers, let rows, let alignments, let id):
            try c.encode(Kind.table, forKey: .kind)
            try c.encode(headers, forKey: .headers); try c.encode(rows, forKey: .rows)
            try c.encode(alignments, forKey: .alignments); try c.encode(id, forKey: .id)
        case .thematicBreak(let id):
            try c.encode(Kind.thematicBreak, forKey: .kind)
            try c.encode(id, forKey: .id)
        case .text(let ct, let id):
            try c.encode(Kind.text, forKey: .kind)
            try c.encode(ct, forKey: .content); try c.encode(id, forKey: .id)
        case .codeBlock(let lang, let ct, let id):
            try c.encode(Kind.codeBlock, forKey: .kind)
            try c.encode(lang, forKey: .language); try c.encode(ct, forKey: .content); try c.encode(id, forKey: .id)
        case .image(let alt, let url, let id):
            try c.encode(Kind.image, forKey: .kind)
            try c.encode(alt, forKey: .alt); try c.encode(url, forKey: .url); try c.encode(id, forKey: .id)
        case .video(let alt, let url, let id):
            try c.encode(Kind.video, forKey: .kind)
            try c.encode(alt, forKey: .alt); try c.encode(url, forKey: .url); try c.encode(id, forKey: .id)
        case .audio(let alt, let url, let id):
            try c.encode(Kind.audio, forKey: .kind)
            try c.encode(alt, forKey: .alt); try c.encode(url, forKey: .url); try c.encode(id, forKey: .id)
        case .file(let alt, let url, let fileType, let id):
            try c.encode(Kind.file, forKey: .kind)
            try c.encode(alt, forKey: .alt); try c.encode(url, forKey: .url)
            try c.encode(fileType, forKey: .fileType); try c.encode(id, forKey: .id)
        }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .heading:
            self = .heading(level: try c.decode(Int.self, forKey: .level),
                            content: try c.decode(String.self, forKey: .content),
                            id: try c.decode(Int.self, forKey: .id))
        case .bulletList:
            self = .bulletList(items: try c.decode([String].self, forKey: .items),
                               indent: try c.decode(Int.self, forKey: .indent),
                               id: try c.decode(Int.self, forKey: .id))
        case .orderedList:
            let oItems = try c.decode([String].self, forKey: .items)
            let oIndent = try c.decode(Int.self, forKey: .indent)
            let oStart = try c.decodeIfPresent(Int.self, forKey: .start) ?? 1
            let oID = try c.decode(Int.self, forKey: .id)
            self = .orderedList(items: oItems, indent: oIndent, start: oStart, id: oID)
        case .taskList:
            let items = try c.decode([TaskItem].self, forKey: .items)
            self = .taskList(items: items.map { (isCompleted: $0.isCompleted, content: $0.content) },
                             indent: try c.decodeIfPresent(Int.self, forKey: .indent) ?? 0,
                             id: try c.decode(Int.self, forKey: .id))
        case .blockquote:
            self = .blockquote(content: try c.decode(String.self, forKey: .content),
                               id: try c.decode(Int.self, forKey: .id))
        case .table:
            self = .table(headers: try c.decode([String].self, forKey: .headers),
                          rows: try c.decode([[String]].self, forKey: .rows),
                          alignments: try c.decode([ColumnAlignment].self, forKey: .alignments),
                          id: try c.decode(Int.self, forKey: .id))
        case .thematicBreak:
            self = .thematicBreak(id: try c.decode(Int.self, forKey: .id))
        case .text:
            self = .text(content: try c.decode(String.self, forKey: .content),
                         id: try c.decode(Int.self, forKey: .id))
        case .codeBlock:
            self = .codeBlock(language: try c.decode(String.self, forKey: .language),
                              content: try c.decode(String.self, forKey: .content),
                              id: try c.decode(Int.self, forKey: .id))
        case .image:
            self = .image(alt: try c.decode(String.self, forKey: .alt),
                          url: try c.decode(String.self, forKey: .url),
                          id: try c.decode(Int.self, forKey: .id))
        case .video:
            self = .video(alt: try c.decode(String.self, forKey: .alt),
                          url: try c.decode(String.self, forKey: .url),
                          id: try c.decode(Int.self, forKey: .id))
        case .audio:
            self = .audio(alt: try c.decode(String.self, forKey: .alt),
                          url: try c.decode(String.self, forKey: .url),
                          id: try c.decode(Int.self, forKey: .id))
        case .file:
            self = .file(alt: try c.decode(String.self, forKey: .alt),
                         url: try c.decode(String.self, forKey: .url),
                         fileType: try c.decode(MediaType.self, forKey: .fileType),
                         id: try c.decode(Int.self, forKey: .id))
        }
    }

    var id: Int {
        switch self {
        case .heading(_, _, let id): return id
        case .bulletList(_, _, let id): return id
        case .orderedList(_, _, _, let id): return id
        case .taskList(_, _, let id): return id
        case .blockquote(_, let id): return id
        case .table(_, _, _, let id): return id
        case .thematicBreak(let id): return id
        case .text(_, let id): return id
        case .codeBlock(_, _, let id): return id
        case .image(_, _, let id): return id
        case .video(_, _, let id): return id
        case .audio(_, _, let id): return id
        case .file(_, _, _, let id): return id
        }
    }
}

