import Foundation

struct EnvVariable: Identifiable, Codable {
    var id: UUID = UUID()
    var key: String
    var value: String
    var isSecret: Bool = false
}

/// 环境变量引用展开（spec 12.2 安全设计：机密仅通过环境变量引用 `$VAR`，
/// 避免把 API Key / Token 明文粘贴进命令或配置）。
/// - 支持 `$VAR` 与 `${VAR}` 两种写法；
/// - `$VAR` 的变量名由「字母/下划线开头 + 字母/数字/下划线」组成；
/// - 未定义的变量保持原样（不吞掉、不报错），便于命令里含普通 `$`。
enum EnvVarStore {
    /// 用给定（或当前）环境变量表展开字符串中的 `$VAR` / `${VAR}` 引用。
    static func expand(_ input: String, using vars: [EnvVariable]? = nil) -> String {
        guard input.contains("$") else { return input }
        let table = vars ?? SettingsStore.shared.settings.envvars
        guard !table.isEmpty else { return input }

        var lookup: [String: String] = [:]
        for v in table where !v.key.isEmpty { lookup[v.key] = v.value }
        guard !lookup.isEmpty else { return input }

        let chars = Array(input)
        var result = ""
        result.reserveCapacity(input.count)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "$", i + 1 < chars.count {
                // ${VAR}
                if chars[i + 1] == "{",
                   let closeOffset = chars[(i + 2)...].firstIndex(of: "}") {
                    let name = String(chars[(i + 2)..<closeOffset])
                    if let val = lookup[name] {
                        result += val
                        i = closeOffset + 1
                        continue
                    }
                }
                // $VAR
                let next = chars[i + 1]
                if next.isLetter || next == "_" {
                    var j = i + 1
                    while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" {
                        j += 1
                    }
                    let name = String(chars[(i + 1)..<j])
                    if let val = lookup[name] {
                        result += val
                        i = j
                        continue
                    }
                }
            }
            result.append(c)
            i += 1
        }
        return result
    }

    /// 是否包含至少一个「可展开」的已定义变量引用（用于 UI 提示 / 契约说明）。
    static func containsReference(_ input: String, using vars: [EnvVariable]? = nil) -> Bool {
        expand(input, using: vars) != input
    }

    /// 当前已配置的环境变量表（key -> value），用于**真实注入进程环境**
    /// （而非字符串替换）。iSH 子进程（/bin/sh 及其后续 fork 的整条进程树）将
    /// 通过 getenv / os.environ / process.env 等读取到这些值。
    /// 参数版从传入快照构造（后台线程用，2026-08-13 竞争修复）。
    static func environmentDictionary(using vars: [EnvVariable]) -> [String: String] {
        var dict: [String: String] = [:]
        for v in vars where !v.key.isEmpty {
            dict[v.key] = v.value
        }
        return dict
    }

    /// 主线程便捷入口：直接读 SettingsStore（仅主线程调用）。
    static var environmentDictionary: [String: String] {
        environmentDictionary(using: SettingsStore.shared.settings.envvars)
    }
}

/// 同步配置
