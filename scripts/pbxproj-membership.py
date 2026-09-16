#!/usr/bin/env python3
"""
pbxproj-membership.py — 把新文件登记进 QQPlayer.xcodeproj 的 folder-sync 例外表。

背景：QQPlayer 主 target / QQPlayerMac 用 PBXFileSystemSynchronizedRootGroup（目录自动含），
例外表（membershipExceptions）控制「哪些文件不编 iOS / 哪些才编 Mac」：
  - iOS 例外表（target 2312D60B…）：Mac/ 专属文件排除出 iOS target
  - QQPlayerMac 白名单（target B1A…07）：列出的共享/Mac 文件才编 Mac
共享 Services 新文件只加 Mac 白名单；被 Siri 扩展用到的共享文件再加 siri-extension；
Mac-only 新文件两表（ios-exceptions + mac-whitelist）都加。

用法：
  python3 scripts/pbxproj-membership.py --target ios-exceptions FileA.swift FileB.swift
  python3 scripts/pbxproj-membership.py --target mac-whitelist FileA.swift
  python3 scripts/pbxproj-membership.py --target siri-extension FileC.swift
  # --target 映射：ios-exceptions = 2312D60B（iOS 例外表）、mac-whitelist = B1A…07、
  #               siri-extension = 23C312D9（Siri 扩展的共享文件名单）
  --dry-run / --pbxproj 可选（同 add-test-file.py 风格）

安全设计（同 add-test-file.py）：
  - 每个条目按行 strip 后精确匹配；已存在 → 幂等跳过
  - 字母序插入（比较 strip 后路径；列表内保持有序）
  - 只改指定 target 的 membershipExceptions 块，其它块不动
  - 写回前 plutil -lint 校验，失败回滚
"""
import argparse
import plistlib
import re
import subprocess
import sys
from pathlib import Path

TARGET_BY_KEY = {
    "ios-exceptions": "2312D60B2E6090E2007F756D",   # Exceptions for QQPlayer folder in QQPlayer target
    "mac-whitelist": "B1A000000000000000000007",    # Exceptions for QQPlayer folder in QQPlayerMac target
    "siri-extension": "23C312D92E78015500342F7C",   # Exceptions for QQPlayer folder in SiriIntentsExtension target
    #   （共享 Services/ 文件被 Siri 扩展用到时也要登记这里：扩展只编这张名单里的共享文件）
}


def find_block(lines, target_id, folder="QQPlayer"):
    """定位 target = <target_id> **且 folder = <folder>** 的 exception set 的 membershipExceptions 区间。
    块结构：... /* Exceptions for "QQPlayer" folder in "X" target */ = {
               isa = PBXFileSystemSynchronizedBuildFileExceptionSet;
      membershipExceptions = ( ... );  target = <id> /* ... */;  };
    返回 (list_start, list_end) 行号。

    ⚠️ 同一个 target 可能有**多份** exception set（每个 folder 一份：共享的 QQPlayer 目录一份、
    扩展自有目录一份，两者 target 相同）。只按 target 匹配会插错那一份
    （2026-09-16 实测：给 Siri 扩展登记共享 Services 文件，插进了它自有目录的 Info.plist 名单，
    编译照旧报 `cannot find 'X' in scope`）。故必须同时匹配块头注释里的 folder 名；
    多份同 folder 命中时 fail-closed 报错，不猜。"""
    matches = []
    i = 0
    n = len(lines)
    while i < n:
        if "PBXFileSystemSynchronizedBuildFileExceptionSet" in lines[i]:
            # 收集本块到 "};"
            j = i
            block = []
            while j < n and lines[j].strip() != "};":
                block.append(lines[j])
                j += 1
            # 块头注释在 `isa = PBXFileSystemSynchronizedBuildFileExceptionSet;` 的**前一行**
            # （Xcode 写法：<ID> /* Exceptions for "QQPlayer" folder in "X" target */ = { …）
            header = lines[i - 1] if i > 0 else ""
            if f"target = {target_id}" in "".join(block) and f'"{folder}" folder' in header:
                list_start = list_end = None
                for k, line in enumerate(block):
                    if "membershipExceptions = (" in line:
                        list_start = k + 1
                    elif list_start is not None and line.strip() == ");":
                        list_end = k
                        break
                if list_start is None or list_end is None:
                    raise SystemExit(f"❌ target {target_id} 块内找不到 membershipExceptions 列表")
                matches.append((i + list_start, i + list_end))
            i = j + 1
        else:
            i += 1
    if not matches:
        raise SystemExit(f"❌ 找不到 target {target_id} / folder \"{folder}\" 的 membershipExceptions 块")
    if len(matches) > 1:
        raise SystemExit(f"❌ target {target_id} / folder \"{folder}\" 命中 {len(matches)} 份名单（预期 1 份）：{matches}")
    return matches[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", required=True, choices=sorted(TARGET_BY_KEY))
    ap.add_argument("files", nargs="+")
    ap.add_argument("--pbxproj", default=None)
    ap.add_argument("--folder", default="QQPlayer", help="exception set 所属 folder（默认 QQPlayer；同 target 多份名单时靠它定位）")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    pbx = Path(args.pbxproj or "QQPlayer.xcodeproj/project.pbxproj")
    target_id = TARGET_BY_KEY[args.target]
    lines = pbx.read_text().splitlines(keepends=True)
    list_start, list_end = find_block(lines, target_id, args.folder)

    # 条目：行内容 strip 后即 path（可能带引号如 "Services/AppCoordinator+iCloud.swift"）
    entries = []
    for i in range(list_start, list_end):
        s = lines[i].strip().rstrip(",").strip('"')
        if s and s != "(":
            entries.append((i, s))
    existing = {s for _, s in entries}

    # 收集新增并按字母序插入
    to_add = sorted(set(args.files) - existing)
    if not to_add:
        print("✅ 全部已存在，无需改动")
        return 0
    # 展示用：entries 已经有序，逐个找插入位（稳定：插在第一个 > 新元素的条目前）
    inserts = {}
    for newf in to_add:
        pos = list_start
        for idx, (_, s) in enumerate(entries):
            # 字母序比较用 strip 后文本（python 字符串序与 Xcode 排序基本一致）
            if s > newf:
                pos = entries[idx][0]
                break
        else:
            pos = list_end
        inserts[pos] = inserts.get(pos, []) + [newf]

    if args.dry_run:
        for pos in sorted(inserts):
            for f in sorted(inserts[pos]):
                print(f"  insert @line {pos + 1}: {f}")
        return 0

    # 从后往前插入（行号不失效）
    new_lines = lines[:]
    for pos in sorted(inserts, reverse=True):
        block = "".join(f'\t\t\t\t"{f}",\n' if " " in f or "+" in f else f"\t\t\t\t{f},\n" for f in sorted(inserts[pos]))
        new_lines[pos:pos] = [block]
    pbx.write_text("".join(new_lines))

    # plutil -lint 校验
    r = subprocess.run(["plutil", "-lint", str(pbx)], capture_output=True, text=True)
    if r.returncode != 0:
        # 回滚
        pbx.write_text("".join(lines))
        raise SystemExit(f"❌ plutil -lint 失败，已回滚: {r.stderr.strip()}")
    print(f"✅ 已插入 {len(to_add)} 个条目到 {args.target}（plutil -lint 通过）")
    for f in sorted(to_add):
        print(f"   + {f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
