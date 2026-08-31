import Foundation
import zlib

/// 纯 Swift 解压 zip（iOS 无 Archive/Process，用 zlib 的 inflate 自行解压）。
/// 仅支持 Store(0) 与 Deflate(8) 两种常见压缩方法，覆盖绝大多数 `.zip`/`.mpk` 包。
///
/// 抽自 `SkillManager`：内置插件同步（`FileSystemManager.syncBundledPlugins`）与
/// 用户导入（`SkillManager.importSkillFile`/`updateSkill`）共用同一解压实现，避免重复。
enum ZipArchive {
    /// 把目录打包为 zip/mpk（Store 方式，不压缩）。
    ///
    /// 为什么用 Store 而非 Deflate：iOS 侧打包只是为了让用户把插件分享出去，
    /// 体积不是瓶颈（图片本身已压缩）；Store 不需要压缩状态机，把封包出错面
    /// 压到最小（inflate 死循环的教训：能不引状态机就不引）。
    /// **不写目录条目**——与内置包/导入包同口径（目录条目会让部分解压实现把
    /// 后续同名文件写入判为已存在）。
    static func create(at zipURL: URL, from directory: URL, entryPrefix: String = "") throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            throw ZipArchiveError.invalidArchive
        }

        struct Item { let name: String; let data: Data; let mtime: Date }
        var items: [Item] = []
        let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            if values.isDirectory == true { continue }
            let relative = url.path.replacingOccurrences(of: directory.path + "/", with: "")
            let name = entryPrefix.isEmpty ? relative : entryPrefix + "/" + relative
            items.append(Item(
                name: name,
                data: try Data(contentsOf: url),
                mtime: values.contentModificationDate ?? Date()
            ))
        }
        guard !items.isEmpty else { throw ZipArchiveError.invalidArchive }

        var body = Data()
        var central = Data()
        var offsets: [UInt32] = []
        for item in items {
            guard let nameData = item.name.data(using: .utf8) else { throw ZipArchiveError.invalidArchive }
            let crc = item.data.withUnsafeBytes { buf -> UInt32 in
                let base = buf.baseAddress?.assumingMemoryBound(to: Bytef.self)
                return UInt32(zlib.crc32(0, base, uInt(item.data.count)))
            }
            let (dosTime, dosDate) = Self.dosDateTime(item.mtime)
            let localOffset = UInt32(body.count)

            var local = Data()
            local.append(uint32: 0x04034b50)          // local file header signature
            local.append(uint16: 20)                  // version needed
            local.append(uint16: 0x0800)              // flags: UTF-8 名称
            local.append(uint16: 0)                   // method: store
            local.append(uint16: dosTime)
            local.append(uint16: dosDate)
            local.append(uint32: crc)
            local.append(uint32: UInt32(item.data.count))
            local.append(uint32: UInt32(item.data.count))
            local.append(uint16: UInt16(nameData.count))
            local.append(uint16: 0)                   // extra len
            local.append(nameData)
            local.append(item.data)
            body.append(local)

            var c = Data()
            c.append(uint32: 0x02014b50)              // central directory signature
            c.append(uint16: 20)                      // version made by
            c.append(uint16: 20)                      // version needed
            c.append(uint16: 0x0800)
            c.append(uint16: 0)                       // method
            c.append(uint16: dosTime)
            c.append(uint16: dosDate)
            c.append(uint32: crc)
            c.append(uint32: UInt32(item.data.count))
            c.append(uint32: UInt32(item.data.count))
            c.append(uint16: UInt16(nameData.count))
            c.append(uint16: 0)                       // extra
            c.append(uint16: 0)                       // comment
            c.append(uint16: 0)                       // disk number
            c.append(uint16: 0)                       // internal attrs
            c.append(uint32: 0)                       // external attrs
            c.append(uint32: localOffset)
            c.append(nameData)
            central.append(c)
            offsets.append(localOffset)
        }

        var out = Data()
        out.append(body)
        let cdOffset = UInt32(out.count)
        out.append(central)
        out.append(uint32: 0x06054b50)                // EOCD
        out.append(uint16: 0)                         // disk number
        out.append(uint16: 0)                         // disk with cd
        out.append(uint16: UInt16(items.count))
        out.append(uint16: UInt16(items.count))
        out.append(uint32: UInt32(central.count))
        out.append(uint32: cdOffset)
        out.append(uint16: 0)                         // comment len
        try out.write(to: zipURL)
    }

    /// DOS 时间戳（zip 格式要求）：时间 = 时<<11 | 分<<5 | 秒/2；日期 = (年-1980)<<9 | 月<<5 | 日。
    private static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, c.year ?? 1980)
        let time = UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2))
        let day = UInt16(((year - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
        return (time, day)
    }

    /// 解压 zip/mpk 到目标目录（目标目录会被逐级创建）。
    /// - 压缩大小必须读自**中央目录记录**（offset+20），而非本地文件头——本地头的
    ///   压缩大小在流式打包（data descriptor）时为 0，从那里读会解压出 0 字节的空文件。
    static func extract(at zipURL: URL, into destination: URL) throws {
        let data = try Data(contentsOf: zipURL)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let entries = try parseZipEntries(data)
        for entry in entries {
            // 目录条目：zip 中央目录中会以 name 以 "/" 结尾、长度为 0 的条目表示。
            // 这类条目必须直接创建目录，不能当作空文件写入，否则后续同名文件写入会报"已存在"。
            if entry.name.hasSuffix("/") {
                let dirComps = entry.name.split(separator: "/").map(String.init)
                    .filter { !$0.isEmpty && $0 != ".." }
                guard !dirComps.isEmpty else { continue }
                let outURL = destination.appendingPathComponent(dirComps.joined(separator: "/"))
                try FileManager.default.createDirectory(
                    at: outURL,
                    withIntermediateDirectories: true
                )
                continue
            }

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
            let sig = data.littleEndianUInt32(at: i)
            if sig == 0x06054b50 {
                eocd = i
                break
            }
        }
        guard eocd >= 0 else { throw ZipArchiveError.invalidArchive }
        // 读中央目录偏移
        let cdOffset = data.littleEndianUInt32(at: eocd + 16)
        offset = Int(cdOffset)

        var result: [(name: String, method: Int, data: Data)] = []
        while offset + 4 <= data.count {
            let sig = data.littleEndianUInt32(at: offset)
            guard sig == cdSig else { break }
            let method = data.littleEndianUInt16(at: offset + 10)
            let nameLen = data.littleEndianUInt16(at: offset + 28)
            let extraLen = data.littleEndianUInt16(at: offset + 30)
            let commentLen = data.littleEndianUInt16(at: offset + 32)
            // 中央目录记录的压缩大小（offset+20）与本地头偏移（offset+42）才是可靠值
            let compSize = data.littleEndianUInt32(at: offset + 20)
            let localHeaderOffset = data.littleEndianUInt32(at: offset + 42)
            let nameStart = offset + 46
            guard nameStart + Int(nameLen) <= data.count else { break }
            let nameData = data.subdata(in: nameStart..<nameStart + Int(nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? ""
            // 定位本地头部以确定压缩数据的起始位置（仍来自本地头）
            let lhNameLen = data.littleEndianUInt16(at: Int(localHeaderOffset) + 26)
            let lhExtraLen = data.littleEndianUInt16(at: Int(localHeaderOffset) + 28)
            let dataStart = Int(localHeaderOffset) + 30 + Int(lhNameLen) + Int(lhExtraLen)
            guard dataStart + Int(compSize) <= data.count else { break }
            let compData = data.subdata(in: dataStart..<dataStart + Int(compSize))
            result.append((name: name, method: Int(method), data: compData))
            offset = nameStart + Int(nameLen) + Int(extraLen) + Int(commentLen)
        }
        return result
    }
}

extension Data {
    /// 安全读取小端 UInt16：用 copyBytes 到栈上对齐变量，避免未对齐 raw pointer load。
    fileprivate func littleEndianUInt16(at offset: Int) -> UInt16 {
        var value: UInt16 = 0
        let range = offset..<(offset + 2)
        guard range.upperBound <= self.count else { return 0 }
        withUnsafeMutablePointer(to: &value) { ptr in
            self.copyBytes(to: UnsafeMutableBufferPointer(start: ptr, count: 2), from: range)
        }
        return value.littleEndian
    }

    /// 安全读取小端 UInt32：用 copyBytes 到栈上对齐变量，避免未对齐 raw pointer load。
    fileprivate func littleEndianUInt32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        let range = offset..<(offset + 4)
        guard range.upperBound <= self.count else { return 0 }
        withUnsafeMutablePointer(to: &value) { ptr in
            self.copyBytes(to: UnsafeMutableBufferPointer(start: ptr, count: 4), from: range)
        }
        return value.littleEndian
    }

    /// 追加小端 UInt16（zip 封包用）。
    fileprivate mutating func append(uint16 value: UInt16) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 2))
    }

    /// 追加小端 UInt32（zip 封包用）。
    fileprivate mutating func append(uint32 value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }
}

enum ZipArchiveError: Error {
    case invalidArchive
    case unsupportedMethod
}

/// 用 zlib 的 `inflate` 解压 DEFLATE 数据流（zip 的标准压缩方法）。
///
/// **防死循环保证（治本修复 2026-08-27）**：旧实现内层循环仅以
/// `result != Z_OK || avail_in == 0` 为退出条件，而 `result` 被刻意排除 Z_BUF_ERROR——
/// 当 deflate 流已结束但输入未耗尽、或流损坏使 zlib 停止消耗时，`avail_in` 永不归零、
/// `result` 保持 Z_OK → 循环无限自旋（100% CPU）。真机上该自旋落在主线程导入/
/// 启动同步路径，Watchdog 报 MAIN THREAD BLOCKED 直至杀进程。
/// 新实现以下列两条保证终止：
/// 1. `next_in` 仅设置一次，此后交由 zlib 自行推进（杜绝指针重复指向导致的错位）；
/// 2. 每轮调用必须有进展（消耗输入 **或** 产出输出），否则判定流损坏直接抛错——
///    因此每轮迭代至多消耗全部剩余输入或填满输出块，循环步数有上界，不可能空转。
private enum ZipInflate {
    static func inflateData(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }

        var strm = z_stream()
        let initResult = inflateInit2_(&strm, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else { throw ZipArchiveError.invalidArchive }
        defer { inflateEnd(&strm) }

        let chunk = 64 * 1024
        let outBuf = UnsafeMutableRawBufferPointer.allocate(
            byteCount: chunk,
            alignment: MemoryLayout<UInt8>.alignment
        )
        defer { outBuf.deallocate() }
        let outBase = outBuf.bindMemory(to: Bytef.self).baseAddress!

        var out = Data()
        var input = [UInt8](data)
        // 独占访问要求：input 的可变字节访问期间不得再读它本身，count 先行取出。
        let totalIn = input.count

        try input.withUnsafeMutableBytes { (inRaw: UnsafeMutableRawBufferPointer) throws in
            // next_in 只设一次，之后由 zlib 自行推进 next_in/avail_in；
            // 中途手动重指会与 zlib 内部推进叠加错位（旧实现的外层循环即在犯此错）。
            strm.next_in = inRaw.bindMemory(to: Bytef.self).baseAddress
            strm.avail_in = uInt(totalIn)

            var finished = false
            while !finished {
                strm.next_out = outBase
                strm.avail_out = uInt(chunk)
                let preAvailIn = strm.avail_in
                let r = inflate(&strm, Z_NO_FLUSH)
                let produced = chunk - Int(strm.avail_out)
                let consumed = Int(preAvailIn) - Int(strm.avail_in)

                if produced > 0 {
                    out.append(outBase, count: produced)
                }

                switch r {
                case Z_STREAM_END:
                    finished = true
                case Z_OK, Z_BUF_ERROR:
                    // 防死循环铁律：本轮既无输入消耗也无输出产出 → 流损坏，
                    // 宁愿报错也绝不空转。
                    guard consumed > 0 || produced > 0 else {
                        throw ZipArchiveError.invalidArchive
                    }
                default:
                    throw ZipArchiveError.invalidArchive
                }
            }
        }
        return out
    }
}
