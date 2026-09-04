import Foundation

// MARK: - Markdown Normalization

/// Normalizes common non-standard list markers (e.g. `1)` and `•`) into
/// CommonMark-friendly syntax so list spacing/styles apply consistently.
func splitStreamingTableTail(_ markdown: String) -> (prefix: String,plainSuffix: String) {
    guard markdown.contains("|") else { return (markdown, "") }
    // Only the *last* line is in flight (not yet terminated by `\n`).
    // Earlier rows that have already been terminated stay in `prefix`,
    // so cmark sees the completed rows and can build a table out of
    // them progressively.
    guard !markdown.hasSuffix("\n") else { return (markdown, "") }
    let nsStr = markdown as NSString
    let len = nsStr.length
    let lastNL = nsStr.range(of: "\n", options: .backwards)
    let tailStartIdx: Int
    if lastNL.location == NSNotFound {
        tailStartIdx = 0
    } else {
        tailStartIdx = lastNL.location+lastNL.length
    }
    let tailLen = len-tailStartIdx
    guard tailLen>0 else { return (markdown, "") }
    let tail = nsStr.substring(with: NSRange(location: tailStartIdx,length: tailLen))
    guard tail.contains("|") else { return (markdown, "") }
    let prefix = nsStr.substring(with: NSRange(location: 0,length: tailStartIdx))
    return (prefix,tail)
}

/// [TableTerminator] GitHub-flavored Markdown allows a table to end implicitly
/// when the next line doesn't start with `|`. However the swift-markdown
/// parser swift-cmark uses requires an explicit blank line — without it, a
/// prose paragraph immediately following a table row is greedily consumed as
/// an extra (single-column) row of that table. Symptom in chat: a table
/// "grows a final row" containing a long sentence from the post-table prose,
/// blowing up the column width and producing the visible "table is mostly
/// blank, one extra row of prose" rendering.
///
/// This pass inserts an empty line between a `| ... |` line and the
/// immediately following non-table, non-blank line. We intentionally limit
/// the trigger to lines that *start* with `|` (after optional whitespace)
/// so prose containing inline `|` characters can't accidentally promote a
/// surrounding paragraph to a table.
///
/// Skips fenced code blocks so `|` chars in code aren't affected.
func fixEmphasisPairsForCJK(_ markdown: String) -> String {
    guard markdown.contains("*") else { return markdown }
    var out: [String] = []
    var inFence = false
    var fenceMarkTok = ""
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
        let lineRaw = String(line)
        let trimmedPart = lineRaw.drop(while: { $0 == " " || $0 == "\t" })
        if !inFence, trimmedPart.hasPrefix("```") || trimmedPart.hasPrefix("~~~") {
            inFence = true
            fenceMarkTok = String(trimmedPart.prefix(3))
            out.append(lineRaw)
            continue
        } else if inFence {
            if trimmedPart.hasPrefix(fenceMarkTok),
               trimmedPart.drop(while: { String($0) == String(fenceMarkTok.first!) })
                   .allSatisfy({ $0 == " " || $0 == "\t" }) {
                inFence = false
            }
            out.append(lineRaw)
            continue
        }
        out.append(fixEmphasisPairsInLine(lineRaw))
    }
    return out.joined(separator: "\n")
}

func strictifyStrikethrough(_ markdown: String) -> String {
    // Fast path: no `~~` anywhere → no work to do.
    guard markdown.contains("~~") else { return markdown }
    let ns = markdown as NSString
    let nsLen = ns.length
    var inFence = false
    var fenceMarkTok = ""
    var out = String()
    out.reserveCapacity(markdown.count)
    // Walk line-by-line so we can skip fenced code blocks intact.
    let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
    func isBoundaryChar(_ ch: Character?) -> Bool {
        guard let ch else { return true } // start/end-of-string
        if ch.isWhitespace || ch.isNewline { return true }
        // Treat ASCII / Unicode punctuation as a boundary too, so
        // `see ~~old~~.` and fullwidth-bracketed strikethroughs keep working — cmark itself
        // accepts punctuation flanks for emphasis-style runs.
        if ch.isPunctuation || ch.isSymbol { return true }
        return false
    }
    for (idx,line) in lines.enumerated() {
        let lineRaw = String(line)
        let trimmedPart = lineRaw.drop(while: { $0 == " " || $0 == "\t" })
        // Fence tracking (mirrors insertBlankLineAfterTable's logic).
        if !inFence, (trimmedPart.hasPrefix("```") || trimmedPart.hasPrefix("~~~")) {
            inFence = true
            fenceMarkTok = String(trimmedPart.prefix(3))
            out.append(lineRaw)
            if idx<lines.count-1 { out.append("\n") }
            continue
        } else if inFence {
            if trimmedPart.hasPrefix(fenceMarkTok)
                && trimmedPart.drop(while: { String($0) == String(fenceMarkTok.first!) })
                    .allSatisfy({ $0 == " " || $0 == "\t" }) {
                inFence = false
            }
            out.append(lineRaw)
            if idx<lines.count-1 { out.append("\n") }
            continue
        }
        // Walk the line and escape `~~` pairs lacking whitespace on
        // either side. Inline code spans (`` `…` ``) are left alone so
        // a `~~` inside code stays literal.
        let chars = Array(lineRaw)
        var i = 0
        var lineOutBuf = String()
        lineOutBuf.reserveCapacity(lineRaw.count)
        var inInlineCode = false
        while i<chars.count {
            let ch = chars[i]
            if ch == "`" {
                inInlineCode.toggle()
                lineOutBuf.append(ch)
                i += 1
                continue
            }
            if !inInlineCode, ch == "~", i+1<chars.count, chars[i+1] == "~" {
                let prev: Character? = i>0 ? chars[i-1] : nil
                let next: Character? = i+2<chars.count ? chars[i+2] : nil
                if isBoundaryChar(prev) || isBoundaryChar(next) {
                    // Looks like a real delimiter — leave it alone and
                    // let cmark pair it up.
                    lineOutBuf.append("~~")
                } else {
                    // Mid-word `~~` — escape both tildes.
                    lineOutBuf.append("\\~\\~")
                }
                i += 2
                continue
            }
            lineOutBuf.append(ch)
            i += 1
        }
        out.append(lineOutBuf)
        if idx<lines.count-1 { out.append("\n") }
    }
    _ = nsLen
    return out
}

/// Split a streaming markdown buffer into (markdownPrefix, plainTextSuffix).
///
/// While a markdown row is still being streamed (the buffer doesn't end with
/// `\n`), the trailing line may be a partial table row. If we hand it to
/// cmark on every chunk, the (re-)parsed `.table` AST forces our renderer to
/// rebuild the `TableAttachment` repeatedly — a full `_fillLayoutHole` pass
/// on the off-screen measure text view — which produces the multi-second
/// main-thread hang on iPhone 17 Pro Max + iOS 26.
///
/// Strategy: when the buffer ends mid-line AND that final line looks like a
/// table row (contains `|`), split it off as `plainSuffix`. The caller
/// renders `prefix` through cmark normally and appends `plainSuffix` as a
/// plain attributed string with the body font, bypassing markdown parsing
/// for the in-flight characters. Inline syntax (`*`, `**`, `` ` ``, `_`) in
/// the partial row is intentionally NOT parsed during streaming, which is
/// the only way to avoid the per-chunk text-shaping cost.
///
/// As soon as the row completes (`\n` arrives) or the trailing line stops
/// looking like a table row, this returns `(markdown, "")` and cmark sees
/// the whole buffer.
private enum MarkdownPrepRegex {
    // normalizeMarkdownListSyntax
    static let orderedParen = try! NSRegularExpression(pattern: #"^(\s*)(\d+)\)\s+"#)
    static let bulletGlyph = try! NSRegularExpression(pattern: #"^(\s*)[•·●]\s+"#)

}


// The three regex-based ZWSP fixers that used to live in this file
// (fixCJKEmphasisDelimiters / fixBoldInnerSpacing / fixBoldBoundary) were
// disabled behind REPRO_DIAG_disableZWSP during the 2026-05-16 streaming-hang
// investigation and never re-enabled — the hang was later root-caused to the
// typesetter feedback loop (01939f73/34143a73), not to ZWSP. They are now
// REPLACED by fixEmphasisPairsForCJK below: pair-aware (only rewrites `*` runs
// that would pair up but for punctuation adjacency), context-safe (skips
// fenced/inline code, escapes, link destinations — the old CJK fixer regexed
// straight through code fences), and a single O(n) pass instead of six
// NSRegularExpressions on the streaming hot path.

func insertBlankLineAfterTable(_ markdown: String) -> String {
    var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard lines.count>1 else { return markdown }
    var inFence = false
    var fenceMarkTok = ""
    var result: [String] = []
    result.reserveCapacity(lines.count+4)
    func looksTable(_ s: String) -> Bool {
        let t = s.drop(while: { $0 == " " || $0 == "\t" })
        return t.hasPrefix("|")
    }
    func looksBlank(_ s: String) -> Bool {
        s.allSatisfy { $0 == " " || $0 == "\t" }
    }
    for i in 0..<lines.count {
        let line = lines[i]
        result.append(line)
        let trimmedPart = line.drop(while: { $0 == " " || $0 == "\t" })
        if !inFence {
            if trimmedPart.hasPrefix("```") || trimmedPart.hasPrefix("~~~") {
                inFence = true
                fenceMarkTok = String(trimmedPart.prefix(3))
                continue
            }
        } else {
            if trimmedPart.hasPrefix(fenceMarkTok)
                && trimmedPart.drop(while: { String($0) == String(fenceMarkTok.first!) })
                    .allSatisfy({ $0 == " " || $0 == "\t" }) {
                inFence = false
            }
            continue
        }
        // Check: table row terminated by a non-table, non-blank line on the
        // next index? If so, insert a blank line between them.
        guard looksTable(line),i+1<lines.count else { continue }
        let next = lines[i+1]
        if !looksBlank(next) && !looksTable(next) {
            result.append("")
        }
    }
    return result.joined(separator: "\n")
}


// MARK: - Inline Code Padding

/// Adds thin spaces inside backtick-delimited code spans so that the background
/// color rendered by MarkdownUI extends slightly beyond the code text, giving
/// the appearance of horizontal padding inside the highlight.
func normalizeMarkdownListSyntax(_ markdown: String) -> String {
    let opRegex = MarkdownPrepRegex.orderedParen
    let bgRegex = MarkdownPrepRegex.bulletGlyph

    var inCodeFence = false
    let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
    var normalizedLines: [String] = []
    normalizedLines.reserveCapacity(lines.count)

    for raw in lines {
        var line = String(raw)
        let trimmedPart = line.trimmingCharacters(in: .whitespaces)
        // 2026-08-11 修复:识别 ~~~ 围栏(原只认 ```,~~~ 代码块内的 1)/• 被
        // 当列表改写,代码语义被篡改)。同文件其他预处理均已同时识别两种围栏。
        if trimmedPart.hasPrefix("```") || trimmedPart.hasPrefix("~~~") {
            inCodeFence.toggle()
            normalizedLines.append(line)
            continue
        }
        if inCodeFence {
            normalizedLines.append(line)
            continue
        }

        line = opRegex.stringByReplacingMatches(
            in: line,
            range: NSRange(location: 0,length: (line as NSString).length),
            withTemplate: "$1$2. "
        )
        line = bgRegex.stringByReplacingMatches(
            in: line,
            range: NSRange(location: 0,length: (line as NSString).length),
            withTemplate: "$1- "
        )
        normalizedLines.append(line)
    }

    return normalizedLines.joined(separator: "\n")
}

// MARK: - Compiled Regex Cache
//
// These regexes are referenced on the streaming hot path (prepareMarkdownForRender
// runs on every SwiftUI body re-evaluation, which happens per-token during
// LLM streaming). Compiling NSRegularExpression on each call shows up as
// ~22% CPU in Instruments — caching the compiled instances drops that to
// ~execution-only cost. force_try is safe here: these patterns are static
// literals validated at first use; a regression would be caught immediately.
private func fixEmphasisPairsInLine(_ line: String) -> String {
    guard line.contains("*") else { return line }
    let chars = Array(line)
    let n = chars.count

    // Pass 1 — protected regions: escapes, inline code spans (backtick runs
    // matched by equal length, per CommonMark), and link destinations `](…)`.
    var isProtectedRange = [Bool](repeating: false,count: n)
    var i = 0
    while i<n {
        let c = chars[i]
        if c == "\\", i+1<n {
            isProtectedRange[i] = true
            isProtectedRange[i+1] = true
            i += 2
            continue
        }
        if c == "`" {
            var j = i
            while j<n, chars[j] == "`" { j += 1 }
            let runLen = j-i
            var k = j
            var closeStart = -1
            while k<n {
                if chars[k] == "`" {
                    var m = k
                    while m<n, chars[m] == "`" { m += 1 }
                    if m-k == runLen { closeStart = k; break }
                    k = m
                } else {
                    k += 1
                }
            }
            if closeStart >= 0 {
                for p in i..<(closeStart+runLen) { isProtectedRange[p] = true }
                i = closeStart+runLen
            } else {
                for p in i..<j { isProtectedRange[p] = true }
                i = j
            }
            continue
        }
        if c == "]", i+1<n, chars[i+1] == "(" {
            var depth = 0
            var j = i+1
            var end = -1
            while j<n {
                if chars[j] == "(" { depth += 1 }
                else if chars[j] == ")" { depth -= 1; if depth == 0 { end = j; break } }
                j += 1
            }
            if end>0 {
                for p in (i+1)...end { isProtectedRange[p] = true }
                i = end+1
                continue
            }
        }
        i += 1
    }

    // Pass 2 — collect unprotected `*` delimiter runs with their flanking
    // classification. ZWSP (U+200B) is Cf: neither whitespace nor punctuation,
    // i.e. letter-class — which is exactly why inserting it fixes flanking
    // and why an already-fixed line classifies as strict-OK (idempotency).
    struct Run {
        let start: Int
        let len: Int
        let openStrict: Bool
        let closeStrict: Bool
        let openRelaxed: Bool
        let closeRelaxed: Bool
        let punctAfter: Bool
        let punctBefore: Bool
    }
    func isWS(_ c: Character?) -> Bool { c.map { $0.isWhitespace } ?? true }
    func isPunct(_ c: Character?) -> Bool { c.map { $0.isPunctuation || $0.isSymbol } ?? false }
    var runs: [Run] = []
    i = 0
    while i<n {
        if chars[i] == "*", !isProtectedRange[i] {
            var j = i
            while j<n, chars[j] == "*", !isProtectedRange[j] { j += 1 }
            let prev: Character? = i>0 ? chars[i-1] : nil
            let next: Character? = j<n ? chars[j] : nil
            let nWS = isWS(next),pWS = isWS(prev)
            let nP = isPunct(next),pP = isPunct(prev)
            runs.append(Run(
                start: i,len: j-i,
                openStrict: !nWS && (!nP || pWS || pP),
                closeStrict: !pWS && (!pP || nWS || nP),
                openRelaxed: !nWS,
                closeRelaxed: !pWS,
                punctAfter: nP,
                punctBefore: pP
            ))
            i = j
        } else {
            i += 1
        }
    }
    guard runs.count >= 2 else { return line }

    // Pass 3 — greedy relaxed pairing; queue ZWSP inserts only for pairs
    // whose sole strict failure is punctuation adjacency.
    var insertPositions: [Int] = []
    var openers: [Int] = []
    for (ri,r) in runs.enumerated() {
        if r.closeRelaxed,let oi = openers.last,
           runs[oi].start+runs[oi].len<r.start { // non-empty content
            let o = runs[oi]
            openers.removeLast()
            if !(o.openStrict && r.closeStrict) {
                var pairInserts: [Int] = []
                var fixable = true
                if !o.openStrict {
                    if o.punctAfter { pairInserts.append(o.start+o.len) } else { fixable = false }
                }
                if !r.closeStrict {
                    if r.punctBefore { pairInserts.append(r.start) } else { fixable = false }
                }
                if fixable { insertPositions.append(contentsOf: pairInserts) }
            }
            continue
        }
        if r.openRelaxed { openers.append(ri) }
    }
    guard !insertPositions.isEmpty else { return line }

    var result = chars
    for pos in insertPositions.sorted(by: >) {
        result.insert("\u{200B}", at: pos)
    }
    return String(result)
}

/// Escape `~~` pairs that aren't flanked by
/// whitespace / line boundaries so cmark-gfm doesn't treat them as
/// strikethrough. The model occasionally emits `~~` inside dense text
/// like number ranges or table-like prose where the opening pair
/// matches a closing pair many tokens later, producing the
/// user-visible "everything between two random `~~`s is struck out"
/// glitch.
///
/// Rule (matches the spec contract):
/// - `~~` is treated as a strikethrough delimiter ONLY when both
/// sides see whitespace, start-of-string, end-of-string, or a
/// newline.
/// - Otherwise we escape it as `\~\~` so cmark renders the literal
/// characters.
///
/// We deliberately leave `**bold**`, `*italic*`, and `` `code` ``
/// alone — those are unambiguous and rarely false-positive.
/// Fenced code (```` ``` ```` / `~~~`) is skipped so code samples
/// stay verbatim.
func prepareMarkdownForRender(_ markdown: String) -> String {
    return strictifyStrikethrough(padInlineCode(fixEmphasisPairsForCJK(normalizeMarkdownListSyntax(insertBlankLineAfterTable(markdown)))))
}

// MARK: - CJK Emphasis Pair Fix

/// CommonMark's flanking rules make `**` fail to open when it is followed by
/// punctuation and preceded by a letter, and fail to close when it is preceded
/// by punctuation and followed by a letter. In spaced Western text those
/// configurations are rare; in CJK prose they are everywhere
/// (`建一个**"标题"**提醒`, `**要点：**内容`), so model output constantly
/// renders literal asterisks. This pass:
/// 1. Skips fenced code blocks, inline code spans, `\*` escapes, and link
/// destinations — those regions are never touched.
/// 2. Simulates delimiter pairing per line with RELAXED flanking (only the
/// whitespace conditions) and checks each matched pair against the
/// STRICT CommonMark rules.
/// 3. Only when a pair would match relaxed but fails strict — i.e. the
/// failure is attributable purely to punctuation adjacency — inserts a
/// zero-width space (U+200B, letter-class for cmark, invisible in
/// rendering) between the delimiter and the adjacent punctuation so the
/// strict rule passes.
/// Pairs that already parse are left byte-identical; lone/unpairable runs
/// (`2**8`, `a ** b`) are never rewritten. The pass is idempotent: after the
/// ZWSP insert the pair passes strict flanking and re-runs are no-ops.
func padInlineCode(_ markdown: String) -> String {
    // Padding disabled — let cmark handle inline code as-is to avoid
    // injecting extra whitespace into fenced code blocks or other contexts.
    return markdown
}

