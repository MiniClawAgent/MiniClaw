#!/usr/bin/env python3
"""MiniClaw i18n 残留检查脚本（防回潮）

扫描 UI 构造器中的硬编码中文字符串——这些文案不走 L10n.l + xcstrings，
会导致多语言下不翻译。只扫「用户可见」的 UI 文案构造器参数，
不扫注释 / 调试日志 / 给模型的提示词内容（那些不属于 i18n 范畴）。

用法:
  python3 scripts/check-i18n-strings.py           # 检查 MiniClaw/ 全部 Swift 源码
  python3 scripts/check-i18n-strings.py --list    # 仅列出命中（不设退出码）
  python3 scripts/check-i18n-strings.py --strict  # 命中任何一条即退出码 1（供 CI）

判定规则（保守，防误报）:
  - 仅匹配 SwiftUI 文案构造器: Text( Label( Button( NavigationLink( Toggle( Stepper(
    Picker( navigationTitle( .navigationTitle( placeholder: title: header: footer:
  - 匹配参数位置的中文字符串字面量
  - 跳过同一行含 L10n.l( 的调用（已是 i18n 路径）
  - 跳过已声明的白名单（语义上确实是内容/专有名词，需人工确认后加入）
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
TARGET_DIR = os.path.join(ROOT, "MiniClaw")

# UI 文案构造器（参数位置为字符串字面量）
UI_PATTERNS = [
    re.compile(r"\b(?:Text|Label|Button|NavigationLink|Toggle|Stepper|Picker)\s*\(\s*\"([^\"]*[\u4e00-\u9fff][^\"]*)\""),
    re.compile(r"\.navigationTitle\s*\(\s*\"([^\"]*[\u4e00-\u9fff][^\"]*)\""),
    re.compile(r"\b(?:title|placeholder|header|footer|message|prompt)\s*:\s*\"([^\"]*[\u4e00-\u9fff][^\"]*)\""),
]

# 白名单：经确认属于「内容 / 专有名词 / 文件名」而非 UI 翻译文案的，加在这里（附原因）
# 格式: (文件路径后缀, 匹配字符串, 原因)
WHITELIST = [
    ("Models/ChatSession.swift", "新会话", "数据默认值（显示层已有 L10n 兜底）"),
    ("Models/ChatSession.swift", "未配置", "数据默认值（实际显示走 currentModelDisplayName）"),
    ("Views/Home/SessionRowView.swift", "新会话", "显示层兜底的比较常量（与 L10n.l(new_chat_title) 配对）"),
    ("Views/Chat/ChatView.swift", "新会话", "显示层兜底的比较常量（与 L10n.l(new_chat_title) 配对）"),
    ("Views/Settings/AboutSettingsView.swift", "关于MiniClaw.md", "文档文件名（DocumentView filename 参数）"),
    ("Views/Settings/AboutSettingsView.swift", "用户使用协议.md", "文档文件名"),
    ("Views/Settings/AboutSettingsView.swift", "用户隐私政策.md", "文档文件名"),
    ("Services/MirrorManager.swift", "阿里云", "镜像源专有名词"),
    ("Services/MirrorManager.swift", "清华", "镜像源专有名词"),
    ("Services/MirrorManager.swift", "中科大", "镜像源专有名词"),
    ("Services/MirrorManager.swift", "腾讯云", "镜像源专有名词"),
    ("Services/MirrorManager.swift", "华为云", "镜像源专有名词"),
    ("Models/ProviderModels.swift", "千问", "厂商名（功能标识，S6 豁免）"),
    ("Models/ProviderModels.swift", "智谱", "厂商名"),
    ("App/Localization.swift", "中文", "语言选择器的母语名（惯例不翻译）"),
    ("App/Localization.swift", "日本語", "语言选择器的母语名"),
    ("App/Localization.swift", "한국어", "语言选择器的母语名"),
]


def is_whitelisted(rel_path: str, line: str) -> bool:
    for suffix, needle, _ in WHITELIST:
        if rel_path.endswith(suffix) and needle in line:
            return True
    return False


def main() -> int:
    hits = []
    for dirpath, _, files in os.walk(TARGET_DIR):
        if ".git" in dirpath or "Resources" in dirpath:
            continue
        for fn in files:
            if not fn.endswith(".swift"):
                continue
            path = os.path.join(dirpath, fn)
            rel = os.path.relpath(path, ROOT)
            try:
                lines = open(path, encoding="utf-8").read().split("\n")
            except Exception:
                continue
            for i, line in enumerate(lines):
                if "L10n.l(" in line:
                    continue
                if is_whitelisted(rel, line):
                    continue
                for pat in UI_PATTERNS:
                    m = pat.search(line)
                    if m:
                        hits.append((rel, i + 1, m.group(1)[:60], line.strip()[:90]))
                        break

    if not hits:
        print("✅ 未发现 UI 硬编码中文字符串残留（全部走 L10n 路径）")
        return 0

    print(f"⚠️  发现 {len(hits)} 处疑似 UI 硬编码中文（未走 L10n）：")
    for rel, ln, matched, whole in hits:
        print(f"  {rel}:{ln}  「{matched}」\n      {whole}")
    if "--list" in sys.argv:
        return 0
    print("\n处理方式：改用 L10n.l(\"english_semantic_key\") 并在 Localizable.xcstrings 补 4 语言；")
    print("若确认是内容/专有名词/文件名，加入脚本 WHITELIST 并注明原因。")
    return 1 if "--strict" in sys.argv else 0


if __name__ == "__main__":
    sys.exit(main())
