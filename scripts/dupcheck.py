#!/usr/bin/env python3
"""源码重合率检查：量化「与外部参考实现的行级重合度」。

用途：结构重构 / 去重期间每批改动后的客观度量。
用法：
    DUPCHECK_REF=/path/to/reference/src python3 scripts/dupcheck.py
    python3 scripts/dupcheck.py --ref /path/to/ref --dirs MiniClawKit,MiniClaw

口径：
- 归一化：去块注释 / 行注释 / 空行，丢弃长度 < 12 的行（滤掉 `}`、`return` 等噪声）；
- 逐行精确匹配：某行归一化文本出现在参考实现的行集合中即计为重合；
- 参考实现的行集合缓存到 /tmp，重复运行秒级（首次约 1 分钟）。
"""
import os, re, sys, glob, pickle, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DIRS = "MiniClawKit,MiniClaw,Shared"
CACHE = "/tmp/dupcheck_ref_cache.pkl"
MIN_LEN = 12


def norm_code(src):
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    out = []
    for line in src.split("\n"):
        s = line.strip()
        if not s or s.startswith("//"):
            continue
        s = re.sub(r"//.*$", "", s).strip()
        if len(s) >= MIN_LEN:
            out.append(s)
    return out


def norm_comments(src):
    return [s for s in (l.strip() for l in src.split("\n"))
            if s.startswith("//") and len(s) >= 8]


def build_ref(ref_dir):
    if os.path.exists(CACHE):
        try:
            code, cmt, cached_dir = pickle.load(open(CACHE, "rb"))
            if cached_dir == ref_dir:
                return code, cmt
        except Exception:
            pass
    t0 = time.time()
    code, cmt = set(), set()
    for f in glob.glob(ref_dir + "/**/*.swift", recursive=True):
        try:
            src = open(f, encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        code.update(norm_code(src))
        cmt.update(norm_comments(src))
    pickle.dump((code, cmt, ref_dir), open(CACHE, "wb"))
    print(f"（参考行集已建缓存：code={len(code)} cmt={len(cmt)}，{time.time()-t0:.0f}s）")
    return code, cmt


def main():
    ref_dir = os.environ.get("DUPCHECK_REF", "")
    if "--ref" in sys.argv:
        ref_dir = sys.argv[sys.argv.index("--ref") + 1]
    if not ref_dir or not os.path.isdir(ref_dir):
        print("请用 --ref 或环境变量 DUPCHECK_REF 指定参考实现源码目录")
        return 1
    dirs = DEFAULT_DIRS.split(",")
    if "--dirs" in sys.argv:
        dirs = sys.argv[sys.argv.index("--dirs") + 1].split(",")

    ref_code, ref_cmt = build_ref(ref_dir)

    rows, tot, dup, cmt_tot, cmt_dup = [], 0, 0, 0, 0
    for d in dirs:
        for f in sorted(glob.glob(os.path.join(ROOT, d) + "/**/*.swift", recursive=True)):
            src = open(f, encoding="utf-8", errors="ignore").read()
            code = norm_code(src)
            if not code:
                continue
            cs = norm_comments(src)
            same = sum(1 for l in set(code) if l in ref_code)
            tot += len(code); dup += same
            cmt_tot += len(cs); cmt_dup += sum(1 for c in cs if c in ref_cmt)
            rows.append((os.path.relpath(f, ROOT), len(code), same, 100.0 * same / len(code)))

    rows.sort(key=lambda r: -r[3])
    print(f"\n{'文件':52} {'有效行':>7} {'重合行':>7} {'重合率':>7}")
    for r in rows[:15]:
        print(f"{r[0]:52} {r[1]:7} {r[2]:7} {r[3]:6.1f}%")
    print(f"\n代码：有效行 {tot}，重合 {dup}，整体重合率 {100.0 * dup / max(tot, 1):.1f}%")
    print(f"注释：{cmt_tot} 行，逐字相同 {cmt_dup}，注释重合率 {100.0 * cmt_dup / max(cmt_tot, 1):.1f}%")
    return 0


if __name__ == "__main__":
    sys.exit(main())
