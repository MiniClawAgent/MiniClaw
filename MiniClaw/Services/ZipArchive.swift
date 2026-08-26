import Foundation
import zlib

/// 纯 Swift 解压 zip（iOS 无 Archive/Process，用 zlib 的 inflate 自行解压）。
/// 仅支持 Store(0) 与 Deflate(8) 两种常见压缩方法，覆盖绝大多数 `.zip`/`.mpk` 包。
///
/// 抽自 `SkillManager`：内置插件同步（`FileSystemManager.syncBundledPlugins`）与
/// 用户导入（`SkillManager.importSkillFile`/`updateSkill`）共用同一解压实现，避免重复。
enum ZipArchive {
    /// 解压 zip/mpk 到目标目录（目标目录会被逐级创建）。
    /// - 压缩大小必须读自**中央目录记录**（offset+20），而非本地文件头——本地头的
    ///   压缩大小在流式打包（data descriptor）时为 0，从那里读会解压出 0 字节的空文件。
    static func extract(at zipURL: URL, into destination: URL) throws {
        let data = try Data(contentsOf: zipURL)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let entries = try parseZipEntries(data)
        for entry in entries {
            // 防路径穿越：仅取相对成分
            let comps = entry.name.split(separator: "/").map(String.init)
                .filter { !$0.isEmpty && $0 != ".." }
            guard !comps.isEmpty else { continue }
            let outURL = destination.appendingPathComponent(comps.joined(separator: "/"))
            try FileManager.default.createDirectory(
                at: outURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            switch entry.method {
            case 0: // store
                try entry.data.write(to: outURL)
            case 8: // deflate
                let inflated = try ZipInflate.inflateData(entry.data)
                try inflated.write(to: outURL)
            default:
                throw ZipArchiveError.unsupportedMethod
            }
        }
    }

    /// 解析 zip 中央目录，返回各条目（名称、压缩方法、解压后数据）。
    private static func parseZipEntries(_ data: Data) throws -> [(name: String, method: Int, data: Data)] {
        let cdSig = UInt32(littleEndian: 0x02014b50)
        guard data.count >= 4 else { throw ZipArchiveError.invalidArchive }
        var offset = 0
        // 定位 End Of Central Directory（从尾部回溯）
        var eocd = -1
        let minEOCD = 22
        for i in stride(from: data.count - minEOCD, through: 0, by: -1) {
            let sig = data.withUnsafeBytes { $0.load(fromByteOffset: i, as: UInt32.self) }.littleEndian
            if sig == 0x06054b50 {
                eocd = i
                break
            }
        }
        guard eocd >= 0 else { throw ZipArchiveError.invalidArchive }
        // 读中央目录偏移
        let cdOffset = data.withUnsafeBytes { $0.load(fromByteOffset: eocd + 16, as: UInt32.self) }.littleEndian
        offset = Int(cdOffset)

        var result: [(name: String, method: Int, data: Data)] = []
        while offset + 4 <= data.count {
            let sig = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }.littleEndian
            guard sig == cdSig else { break }
            let method = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 10, as: UInt16.self) }.littleEndian
            let nameLen = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 28, as: UInt16.self) }.littleEndian
            let extraLen = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 30, as: UInt16.self) }.littleEndian
            let commentLen = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 32, as: UInt16.self) }.littleEndian
            // 中央目录记录的压缩大小（offset+20）与本地头偏移（offset+42）才是可靠值
            let compSize = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 20, as: UInt32.self) }.littleEndian
            let localHeaderOffset = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 42, as: UInt32.self) }.littleEndian
            let nameStart = offset + 46
            guard nameStart + Int(nameLen) <= data.count else { break }
            let nameData = data.subdata(in: nameStart..<nameStart + Int(nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? ""
            // 定位本地头部以确定压缩数据的起始位置（仍来自本地头）
            let lhNameLen = data.withUnsafeBytes { $0.load(fromByteOffset: Int(localHeaderOffset) + 26, as: UInt16.self) }.littleEndian
            let lhExtraLen = data.withUnsafeBytes { $0.load(fromByteOffset: Int(localHeaderOffset) + 28, as: UInt16.self) }.littleEndian
            let dataStart = Int(localHeaderOffset) + 30 + Int(lhNameLen) + Int(lhExtraLen)
            guard dataStart + Int(compSize) <= data.count else { break }
            let compData = data.subdata(in: dataStart..<dataStart + Int(compSize))
            result.append((name: name, method: Int(method), data: compData))
            offset = nameStart + Int(nameLen) + Int(extraLen) + Int(commentLen)
        }
        return result
    }
}

enum ZipArchiveError: Error {
    case invalidArchive
    case unsupportedMethod
}

/// 用 zlib 的 `inflate` 解压 DEFLATE 数据流（zip 的标准压缩方法）。
private enum ZipInflate {
    static func inflateData(_ data: Data) throws -> Data {
        var out = Data()
        var strm = z_stream()
        let initResult = inflateInit2_(&strm, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else { throw ZipArchiveError.invalidArchive }

        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        var result: Int32 = Z_OK

        var input = [UInt8](data)
        var inputLeft = input.count
        while inputLeft > 0 {
            let consumed = input.count - inputLeft
            let total = input.count
            let inputCopy = input
            withExtendedLifetime(inputCopy) {
                input.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) in
                    let base = ptr.baseAddress?.assumingMemoryBound(to: Bytef.self)
                    strm.next_in = base?.advanced(by: consumed)
                    strm.avail_in = UInt32(min(inputLeft, Int(Int32.max)))
                    // 输出缓冲指针与 inflate 调用必须在同一闭包内(避免悬垂指针)。
                    while strm.avail_in > 0 {
                        var produced = 0
                        buffer.withUnsafeMutableBytes { (outPtr: UnsafeMutableRawBufferPointer) in
                            strm.next_out = outPtr.bindMemory(to: Bytef.self).baseAddress
                            strm.avail_out = UInt32(chunk)
                            let r = inflate(&strm, Z_NO_FLUSH)
                            if r != Z_OK && r != Z_STREAM_END && r != Z_BUF_ERROR {
                                result = r
                            }
                            produced = chunk - Int(strm.avail_out)
                        }
                        // 闭包外 append:避免与 buffer 独占访问重叠。
                        if produced > 0 {
                            out.append(buffer, count: produced)
                        }
                        if result != Z_OK || strm.avail_in == 0 { break }
                    }
                }
            }
            inputLeft = total - Int(strm.avail_in)
            if result != Z_OK && result != Z_STREAM_END { break }
        }

        inflateEnd(&strm)
        guard result == Z_OK || result == Z_STREAM_END else { throw ZipArchiveError.invalidArchive }
        return out
    }
}
