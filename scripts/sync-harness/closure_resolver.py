#!/usr/bin/env python3
"""closure_resolver.py — 本地 harness 编译集「依赖闭包」解析器

为什么存在：`scripts/run-local-sync-tests.sh` 用 swiftc 直编生产源码跑断言，而
生产源码的编译集**不能手工维护**——手工清单必然逐批腐烂（血例：2026-09-21 E 拆分
批之后清单只收 Sync/ 的 42/68 个文件，且引用了清单外的类型 ⇒ harness 在基线上就编
不过，而它又不在 CI 里，红了没人知道）。

本脚本把编译集改成**自动发现 + 自动补闭包**：
  1. 起点：`QQPlayer/Sync/*.swift` 全收（减去黑名单）+ `scripts/sync-harness/` 三个夹具
  2. 迭代：`swiftc -typecheck` 报错 → 在候选池里定位提供者文件 → 全部候选一起加入
     （同名歧义不猜）→ 重编 → 直到编译通过。支持两类缺口：
       • `cannot find '<X>' in scope`            → 找 X 的**顶层声明**文件
       • `... has no member '<M>'`（接收者 T）   → 找 `extension T` 且出现 M 的文件
  3. 落点：编译通过（覆盖 = 起点 + 闭包）；或无法推进 → exit 2 点名（符号 + 来源文件 + 处置指引）

四条硬约束：
  - **不静默降级**：任何无法定位的符号都 exit 2，点名符号 + 出错文件 + 候选路径
  - **不悄悄漏文件**：起点文件若编不进命令行，必须**显式**进黑名单（本脚本只报错，不自动剔除）
  - **桩优先**：候选文件若与夹具桩声明同名（会 `invalid redeclaration`），跳过并记明原因；
    自动补入的文件若自己也编不动（真 GRDB 依赖），**回退**并记明（再看下一轮怎么收敛）
  - **黑名单自带守卫**：① 路径存在 ② 顶层声明仍在其他生产文件里被引用（防黑名单腐烂）

缓存：按「候选池 + 夹具 + 黑名单 + 本脚本」内容哈希缓存解析结果（`--refresh` 强制重算）。
用法：closure_resolver.py --root <repo> --build-dir <dir> [--blacklist <file>] [--refresh] [--verbose]
输出：stdout = 最终编译集（相对 root 的路径，一文件一行，生产在前、夹具在后）
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import re
import subprocess
import sys

# ── 编译集口径 ────────────────────────────────────────────────────────────────
START_GLOBS = ("QQPlayer/Sync/*.swift",)
POOL_GLOBS = (
    "QQPlayer/Sync/*.swift",
    "QQPlayer/Services/*.swift",
    "QQPlayer/Models/*.swift",
    "QQPlayer/Helpers/*.swift",
)
PRODUCTION_GLOBS = ("QQPlayer/**/*.swift",)
FIXTURES = (
    "scripts/sync-harness/Stubs.swift",
    "scripts/sync-harness/HarnessSupport.swift",
    "scripts/sync-harness/main.swift",
)
DEFAULT_BLACKLIST = "scripts/sync-harness/blacklist.txt"
SWIFT_VERSION = "5"
MAX_ROUNDS = 40

# ── 声明提取 ─────────────────────────────────────────────────────────────────
# 顶层声明（行首零缩进）：符号定位与「与桩重名」判定都用它——嵌套类型不能跨文件
# 满足裸名引用，所以只有顶层声明才算「这个文件提供了符号 X」。
_TOP_DECL_RE = re.compile(
    r"(?m)^(?:@[A-Za-z_]\w*(?:\([^)\n]*\))?[ \t]+)*"
    r"(?:(?:public|internal|private|fileprivate|open|final|static|nonisolated|indirect|mutating)[ \t]+)*"
    r"(?:class|struct|enum|protocol|actor|typealias|func|let|var)[ \t]+([A-Za-z_]\w*)"
)

# ── 错误解析 ─────────────────────────────────────────────────────────────────
_ERROR_RE = re.compile(r"(?m)^([^ \t\n][^\n]*?):(\d+):(\d+): error: ([^\n]*)$")
_CANNOT_FIND_RE = re.compile(r"cannot find (?:type )?'([^']+)' in scope")
_NOMEMBER_RE = re.compile(r"(?:value of type|type) '([A-Za-z_][\w.]*)' has no member '([A-Za-z_]\w*)'")
_REDECL_RE = re.compile(r"invalid redeclaration of '([^']+)'")


def warn(msg: str) -> None:
    print(msg, file=sys.stderr)


def die(msg: str, code: int = 2) -> None:
    print(msg, file=sys.stderr)
    sys.exit(code)


def read_text(root: str, rel: str) -> str:
    with open(os.path.join(root, rel), "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()


def rel_swift_files(root: str, patterns) -> list[str]:
    found: set[str] = set()
    for pattern in patterns:
        for path in glob.glob(os.path.join(root, pattern), recursive=True):
            found.add(os.path.relpath(path, root))
    return sorted(found)


def top_level_names(text: str) -> set[str]:
    return {m.group(1) for m in _TOP_DECL_RE.finditer(text)}


def load_blacklist(root: str, path: str) -> list[str]:
    abs_path = os.path.join(root, path)
    if not os.path.isfile(abs_path):
        die(f"❌ 找不到黑名单文件：{path}")
    entries: list[str] = []
    with open(abs_path, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.split("#", 1)[0].strip()
            if line:
                entries.append(line.rstrip("/"))
    if len(set(entries)) != len(entries):
        die(f"❌ 黑名单 {path} 有重复条目")
    return entries


def guard_blacklist(root: str, blacklist: list[str]) -> None:
    """黑名单两道守卫：① 路径存在 ② 顶层声明仍在其他生产文件里被引用。"""
    if not blacklist:
        return
    blacklist_set = set(blacklist)
    production = rel_swift_files(root, PRODUCTION_GLOBS)
    corpus = {p: read_text(root, p) for p in production if p not in blacklist_set}

    for entry in blacklist:
        if not os.path.isfile(os.path.join(root, entry)):
            die(
                f"❌ 黑名单守卫①失败：{entry} 不存在。\n"
                f"   → 路径写错或文件已改名；请修正 {DEFAULT_BLACKLIST}（不许留悬空条目）。"
            )
        names = top_level_names(read_text(root, entry))
        if not names:
            die(f"❌ 黑名单守卫①失败：{entry} 里提取不到任何顶层声明（文件被改写？）")
        referenced = []
        for name in sorted(names):
            word = re.compile(rf"(?<![A-Za-z0-9_]){re.escape(name)}(?![A-Za-z0-9_])")
            if any(word.search(text) for text in corpus.values()):
                referenced.append(name)
        if not referenced:
            die(
                f"❌ 黑名单守卫②失败：{entry} 声明的符号 {sorted(names)} 在其他生产文件里**零引用**。\n"
                f"   → 该文件已没人用（或已被别处取代）⇒ 黑名单在腐烂：请从 {DEFAULT_BLACKLIST} 删掉这一行。"
            )


def closure_cache_key(root: str, pool: list[str], blacklist_path: str, blacklist: list[str]) -> str:
    digest = hashlib.sha256()
    digest.update(b"closure-resolver-v3\0")
    digest.update(f"swift-{SWIFT_VERSION}\0".encode())
    for rel in sorted(pool + list(FIXTURES)):
        digest.update(rel.encode())
        digest.update(b"\0")
        with open(os.path.join(root, rel), "rb") as fh:
            digest.update(hashlib.sha256(fh.read()).digest())
        digest.update(b"\0")
    with open(os.path.join(root, blacklist_path), "rb") as fh:
        digest.update(hashlib.sha256(fh.read()).digest())
    with open(os.path.abspath(__file__), "rb") as fh:
        digest.update(hashlib.sha256(fh.read()).digest())
    digest.update("\0".join(blacklist).encode())
    return digest.hexdigest()


def run_typecheck(root: str, build_dir: str, files: list[str]) -> tuple[int, str]:
    cmd = [
        "swiftc", "-swift-version", SWIFT_VERSION,
        "-I", build_dir, "-L", build_dir, "-lGRDB",
        "-typecheck",
    ] + files
    proc = subprocess.run(cmd, cwd=root, capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


def error_entries(output: str) -> list[tuple[str, str]]:
    """→ [(出错文件, 错误消息)]，顺序 = swiftc 输出顺序。"""
    return [(m.group(1), m.group(4)) for m in _ERROR_RE.finditer(output)]


def extension_of(text: str, type_name: str) -> bool:
    base = type_name.rsplit(".", 1)[-1]
    return re.search(rf"(?m)^[ \t]*(?:public |internal |private |fileprivate |)?extension[ \t]+{re.escape(base)}\b", text) is not None


def main() -> int:
    parser = argparse.ArgumentParser(description="解析本地 harness 的 swiftc 编译闭包")
    parser.add_argument("--root", default=".", help="仓库根（worktree 根）")
    parser.add_argument("--build-dir", required=True, help="GRDB 桩模块所在目录（同时放缓存）")
    parser.add_argument("--blacklist", default=DEFAULT_BLACKLIST, help="黑名单文件（相对 root）")
    parser.add_argument("--refresh", action="store_true", help="强制重算闭包（忽略缓存）")
    parser.add_argument("--verbose", action="store_true", help="打印每轮解析细节")
    args = parser.parse_args()

    root = os.path.abspath(args.root)
    build_dir = os.path.abspath(args.build_dir)
    os.makedirs(build_dir, exist_ok=True)

    blacklist = load_blacklist(root, args.blacklist)
    guard_blacklist(root, blacklist)
    warn(f"✅ 黑名单守卫通过（{len(blacklist)} 条：路径存在 + 仍被引用）")

    blacklist_set = set(blacklist)
    pool = [p for p in rel_swift_files(root, POOL_GLOBS) if p not in blacklist_set]
    start = [p for p in rel_swift_files(root, START_GLOBS) if p not in blacklist_set]

    cache_path = os.path.join(build_dir, "closure-cache.json")
    key = closure_cache_key(root, pool, args.blacklist, blacklist)
    if not args.refresh and os.path.isfile(cache_path):
        try:
            with open(cache_path, "r", encoding="utf-8") as fh:
                cached = json.load(fh)
        except (OSError, ValueError):
            cached = {}
        paths = cached.get("closure") or []
        if cached.get("key") == key and paths and all(os.path.isfile(os.path.join(root, p)) for p in paths):
            warn(f"▶︎ 使用缓存闭包（{len(paths)} 个文件）；--refresh 可强制重算")
            print("\n".join(paths))
            return 0

    stub_names: set[str] = set()
    for rel in FIXTURES:
        stub_names |= top_level_names(read_text(root, rel))

    pool_text = {rel: read_text(root, rel) for rel in pool}
    decl_index: dict[str, list[str]] = {}
    for rel, text in pool_text.items():
        for name in top_level_names(text):
            decl_index.setdefault(name, []).append(rel)

    start_set = set(start)
    fixture_list = list(FIXTURES)
    active: list[str] = list(start) + fixture_list
    auto_added: set[str] = set()
    tried: set[tuple] = set()
    dead_ends: dict[str, list[str]] = {}

    def candidates_for(kind: str, subject) -> list[str]:
        if kind == "sym":
            return [p for p in decl_index.get(subject, []) if p not in active]
        type_name, member = subject
        word = re.compile(rf"(?<![A-Za-z0-9_]){re.escape(member)}(?![A-Za-z0-9_])")
        return [p for p in pool
                if p not in active and extension_of(pool_text[p], type_name) and word.search(pool_text[p])]

    for round_no in range(1, MAX_ROUNDS + 1):
        code, output = run_typecheck(root, build_dir, active)
        if code == 0:
            warn(f"✅ 闭包收敛：{len(active)} 个文件"
                 f"（生产 {len(active) - len(fixture_list)} + 夹具 {len(fixture_list)}），迭代 {round_no} 轮")
            with open(cache_path, "w", encoding="utf-8") as fh:
                json.dump({"key": key, "closure": active}, fh)
            print("\n".join(active))
            return 0

        entries = error_entries(output)
        redecls = sorted({m.group(1) for _, msg in entries for m in [_REDECL_RE.search(msg)] if m})
        if redecls:
            die(
                "❌ 检测到重复符号声明（桩 vs 生产重名）：" + ", ".join(redecls) + "\n"
                "   → harness 桩（scripts/sync-harness/Stubs.swift）与生产文件同时声明了这些符号。\n"
                "   → 处置二选一：① 该生产文件加入 scripts/sync-harness/blacklist.txt（由桩替代）；\n"
                "                  ② 从夹具里删掉桩、改用生产实现（仅当它真能命令行编译）。"
            )

        needs: dict[tuple, set[str]] = {}
        non_symbol: list[tuple[str, str]] = []
        for src, msg in entries:
            found = _CANNOT_FIND_RE.search(msg)
            if found:
                needs.setdefault(("sym", found.group(1)), set()).add(src)
                continue
            member = _NOMEMBER_RE.search(msg)
            if member:
                needs.setdefault(("member", (member.group(1), member.group(2))), set()).add(src)
                continue
            non_symbol.append((src, msg))

        # 自动补入的文件若自己也编不动 → 回退（不静默留在集合里当假绿来源）
        retracted: list[str] = []
        for src, _ in non_symbol:
            if src in auto_added and src not in dead_ends:
                dead_ends[src] = [m for s, m in entries if s == src]
                retracted.append(src)
        if retracted:
            for src in retracted:
                if src in active:
                    active.remove(src)
                auto_added.discard(src)
            warn(f"▶︎ 第 {round_no} 轮：回退 {len(retracted)} 个自动补入但编不动的文件"
                 f"（{'、'.join(sorted(retracted))}）——它们需要真 GRDB，不能进命令行 harness")
            continue

        if not needs:
            detail = "\n".join(f"     {src}: {msg}" for src, msg in non_symbol[:15]) \
                or "     （swiftc 未给出可解析的 error 行）"
            die(
                "❌ 闭包解析无法推进：剩余错误不是「符号/成员找不到」，无法靠补文件解决。\n"
                f"   第 {round_no} 轮错误（前 15 条）：\n{detail}\n"
                "   → 多为「类型已有但缺成员 / 缺一致性 / 桩形态不对」：请核对黑名单与桩是否与生产同形。"
            )

        added: list[str] = []
        skipped: list[str] = []
        for need in sorted(needs, key=lambda k: (k[0], str(k[1]))):
            if need in tried:
                continue
            tried.add(need)
            kind, subject = need
            label = subject if kind == "sym" else f"{subject[0]}.{subject[1]}"
            for cand in candidates_for(kind, subject):
                if cand in dead_ends:
                    continue
                if top_level_names(pool_text[cand]) & stub_names:
                    skipped.append(f"{label}（{cand} 与 harness 桩同名，不能同时编入）")
                    continue
                if cand not in added:
                    added.append(cand)
                    if args.verbose:
                        warn(f"    ↳ {label} → 加入 {cand}")

        if added:
            for cand in added:
                if cand not in start_set:
                    auto_added.add(cand)
                active.append(cand)
            warn(f"▶︎ 第 {round_no} 轮：缺口 {len(needs)} 个 → 补入 {len(added)} 个文件"
                 f"（{'、'.join(sorted(added))}）")
            continue

        # 无解：给可执行的处置指引
        blacklist_set_now = set(blacklist)
        lines: list[str] = []
        for need in sorted(needs, key=lambda k: (k[0], str(k[1]))):
            kind, subject = need
            label = subject if kind == "sym" else f"{subject[0]}.{subject[1]}"
            origins = "、".join(sorted(needs[need]))
            if kind == "sym":
                found_cands = sorted(decl_index.get(subject, []))
                outside = [] if found_cands else [
                    p for p in rel_swift_files(root, PRODUCTION_GLOBS)
                    if re.search(rf"(?m)^[ \t]*(?:class|struct|enum|protocol|actor|typealias)[ \t]+"
                                 rf"{re.escape(subject)}\b", read_text(root, p))
                ]
            else:
                type_name, member = subject
                word = re.compile(rf"(?<![A-Za-z0-9_]){re.escape(member)}(?![A-Za-z0-9_])")
                found_cands = [p for p in rel_swift_files(root, PRODUCTION_GLOBS)
                               if extension_of(read_text(root, p), type_name) and word.search(read_text(root, p))]
                outside = []
            if found_cands and all((c in blacklist_set_now) or (c in dead_ends) or
                                   (top_level_names(pool_text[c]) & stub_names if c in pool_text else False)
                                   for c in found_cands):
                hint = f"  ← 提供者 {found_cands} 已在黑名单/编不动/与桩同名"
            elif outside:
                hint = f"  ← 候选池外存在提供者 {sorted(set(outside))}（需扩池或补桩）"
            else:
                hint = "  ← 找不到提供者（需补桩或扩池）"
            lines.append(f"     • {label}（出错文件：{origins}）{hint}")
        if skipped:
            lines.append("   因与桩同名而跳过的候选：")
            lines.extend(f"     • {item}" for item in skipped)
        if dead_ends:
            lines.append("   已知编不动的文件（须留在黑名单或补桩）：")
            for src, msgs in sorted(dead_ends.items()):
                lines.append(f"     • {src} → {msgs[0] if msgs else '（无错误详情）'}")
        die(
            f"❌ 闭包解析失败：第 {round_no} 轮仍有无法定位的缺口，且没有新文件可加。\n"
            "   未解析缺口：\n" + "\n".join(lines) + "\n"
            "   → 若缺口来自「起点文件」（QQPlayer/Sync/*.swift）而该文件本身编不进命令行：\n"
            f"     把它显式写进 {DEFAULT_BLACKLIST}（不许靠静默剔除），并在 Stubs.swift 补同形替身；\n"
            "   → 若该缺口应由桩提供：把它加进 scripts/sync-harness/Stubs.swift；\n"
            "   → 若提供者在候选池内：确认它没被黑名单拦掉、且与夹具桩不同名。"
        )

    die(f"❌ 闭包解析未在 {MAX_ROUNDS} 轮内收敛（疑似循环依赖或桩缺口），请人工核对。")
    return 2


if __name__ == "__main__":
    sys.exit(main())
