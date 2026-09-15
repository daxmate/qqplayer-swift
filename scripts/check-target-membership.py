#!/usr/bin/env python3
"""
check-target-membership.py — Xcode 工程「文件 → target 成员」一致性守卫。

为什么存在（2026-09-15 事故）：QQPlayer 主 target 与 QQPlayerMac 都靠
`PBXFileSystemSynchronizedRootGroup`（目录自动含），两份例外表决定归属：
  - iOS 例外表（target 2312D60B…）：列出的文件**不编 iOS**（Mac 专属）
  - QQPlayerMac 白名单（target B1A…07）：列出的文件**才编 Mac**（白名单制）
新增一个共享文件却忘了登记 Mac 白名单 → 只有**干净全量编译**才会暴露
（增量编译 + 本机缓存会让它一路绿；Xcode 里则表现为「Cannot find 'X' in scope」）。
人记不住，所以由本脚本拦。

三道检查：
  A. 名单完整性：两份名单里的路径必须真实存在于磁盘（改名/删除后的陈旧条目即红）；
     名单内不得重复。
  B. Mac 自有文件：`QQPlayer/Mac/**/*.swift` 必须全在 Mac 白名单。
  C. 归属决策门（只看**新增**文件）：若文件所在**顶层目录是混合目录**（该目录里
     既有 Mac 成员、又有非成员 = 归属靠人决定的目录），新文件必须三选一表态：
       ① 在 Mac 白名单（两端都编） ② 在 iOS 例外表（Mac 专属）
       ③ 文件头 40 行内有 `// target: ios-only` 标记（只编 iOS）
     否则红——并打印修法命令。用途：把「这个文件编不编 Mac」这个决定**摆在提交时**，
     而不是等 Xcode 报错或线上才发现。

用法：
  python3 scripts/check-target-membership.py                # 全量检查（A + B）
  python3 scripts/check-target-membership.py --staged       # A + B + C（按暂存区新增文件）
  python3 scripts/check-target-membership.py --base HEAD~1  # A + B + C（按相对某提交的新增文件）
  python3 scripts/check-target-membership.py --files Foo.swift  # A + B + C（把给定路径当新增文件；测试用）
  SKIP_MEMBERSHIP_CHECK=1 <commit>   # 逃生阀（CI 仍兜底）

退出码：0 通过｜1 有违规｜2 环境/解析失败（fail-closed：名单读不出来不算通过）。
"""
import argparse
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PBXPROJ = ROOT / "QQPlayer.xcodeproj" / "project.pbxproj"

TARGET_IOS = "2312D60B2E6090E2007F756D"      # iOS 例外表（列出的不编 iOS）
TARGET_MAC = "B1A000000000000000000007"      # QQPlayerMac 白名单（列出的才编 Mac）
IOS_ONLY_MARKER = "// target: ios-only"
MAC_BASELINE_DIR = "QQPlayer/Mac"            # Mac 自有目录（必须全在 Mac 白名单）


def fail_env(msg):
    print(f"❌ 环境/解析失败：{msg}", file=sys.stderr)
    sys.exit(2)


def canonical(entry):
    """名单条目 → 规范路径（去空白、去尾逗号、去 Xcode 给特殊字符加的引号）。"""
    item = entry.strip().rstrip(",").strip()
    if len(item) >= 2 and item.startswith('"') and item.endswith('"'):
        item = item[1:-1]
    return item


def exception_sets(text):
    """解析工程里**每一份** PBXFileSystemSynchronizedBuildFileExceptionSet → [(target_id, 条目列表)]。

    ⚠️ 必须按块切分：一个 `membershipExceptions = (` 到它**紧邻**的 `target = <id>`
    才算一层；用跨块的懒惰正则会把后面几层的条目全吞进来（写过两版都踩了）。
    """
    sets = []
    for part in text.split("isa = PBXFileSystemSynchronizedBuildFileExceptionSet;")[1:]:
        match = re.search(r"membershipExceptions = \((.*?)\);", part, re.S)
        if match is None:
            continue
        target = re.search(r"target = (\w+)", part[match.end():])
        if target is None:
            continue
        entries = [canonical(line) for line in match.group(1).split("\n") if line.strip()]
        sets.append((target.group(1), entries))
    return sets


def read_membership(target_id):
    """返回该 target 例外表的条目列表（保序，已规范）。"""
    if not PBXPROJ.exists():
        fail_env(f"找不到 {PBXPROJ}")
    for tid, entries in exception_sets(PBXPROJ.read_text(encoding="utf-8")):
        if tid == target_id:
            return entries
    fail_env(f"找不到 target {target_id} 的 membershipExceptions（工程结构变了？）")


def all_source_files():
    """仓库相对路径的 .swift 列表（用于报错信息，人读友好）。"""
    return [str(p.relative_to(ROOT)) for p in (ROOT / "QQPlayer").rglob("*.swift")]


def pbx_path(repo_relative):
    """仓库相对路径 → 名单条目形态（相对 QQPlayer/）。⚠️ 两边基准不同最容易写错。"""
    return repo_relative[len("QQPlayer/"):] if repo_relative.startswith("QQPlayer/") else repo_relative


def added_files(base, staged, explicit):
    if explicit:
        return list(explicit)
    if staged:
        cmd = ["git", "diff", "--cached", "--name-only", "--diff-filter=A"]
    elif base:
        cmd = ["git", "diff", "--name-only", "--diff-filter=A", base, "HEAD"]
    else:
        return []
    result = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        fail_env(f"git 查询失败：{' '.join(cmd)}\n{result.stderr.strip()}")
    return [line for line in result.stdout.split("\n") if line.strip()]


def mixed_top_dirs(mac, ios):
    """顶层目录里「既有 Mac 成员又有非成员」的集合（归属靠人决定的目录）。"""
    seen = {}
    for path in all_source_files():
        rel = pbx_path(path)
        top = rel.split("/")[0] if "/" in rel else "(根)"
        seen.setdefault(top, {"mac": False, "other": False})
        if rel in mac:
            seen[top]["mac"] = True
        else:
            seen[top]["other"] = True
    return {top for top, flags in seen.items() if flags["mac"] and flags["other"]}


def top_dir_of(path):
    rel = pbx_path(path)
    return rel.split("/")[0] if "/" in rel else "(根)"


def has_ios_only_marker(path):
    try:
        head = (ROOT / path).read_text(encoding="utf-8").split("\n")[:40]
    except OSError:
        return False
    return any(line.strip().startswith(IOS_ONLY_MARKER) for line in head)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default=None, help="相对该提交算新增文件（默认只查 A+B）")
    parser.add_argument("--staged", action="store_true", help="按暂存区新增文件做 C 检查")
    parser.add_argument("--files", nargs="*", default=None, help="把给定路径当新增文件（测试用）")
    args = parser.parse_args()

    mac_list = read_membership(TARGET_MAC)
    ios_list = read_membership(TARGET_IOS)
    mac, ios = set(mac_list), set(ios_list)
    violations = []

    # ---- A. 名单完整性 ----
    for name, entries in (("Mac 白名单", mac_list), ("iOS 例外表", ios_list)):
        dupes = {item for item in entries if entries.count(item) > 1}
        if dupes:
            violations.append(f"{name}有重复条目：{sorted(dupes)}")
        for item in entries:
            if not (ROOT / "QQPlayer" / item).exists():
                violations.append(f"{name}里的 `{item}` 在磁盘上不存在（改名/删除后的陈旧条目）")

    # ---- B. Mac 自有目录必须在白名单 ----
    for path in all_source_files():
        if path.startswith(MAC_BASELINE_DIR + "/") and pbx_path(path) not in mac:
            violations.append(
                f"{path} 在 {MAC_BASELINE_DIR}/ 下但不在 Mac 白名单（Mac 目标编不到它）"
            )

    # ---- C. 新增文件的归属决策门 ----
    mixed = mixed_top_dirs(mac, ios)
    new_files = [f for f in added_files(args.base, args.staged, args.files)
                 if f.startswith("QQPlayer/") and f.endswith(".swift")]
    for path in new_files:
        top = top_dir_of(path)
        if top not in mixed:
            continue          # 目录本身已表态（全 Mac / 全 iOS 专用）
        if pbx_path(path) in mac or pbx_path(path) in ios or has_ios_only_marker(path):
            continue
        violations.append(
            f"新增文件 {path} 没有 target 归属（所在目录 `{top}` 是混合目录，归属必须显式决定）\n"
            f"      · 两端都编 → python3 scripts/pbxproj-membership.py --target mac-whitelist {pbx_path(path)}\n"
            f"      · 只编 iOS → 在文件头加一行 `{IOS_ONLY_MARKER}`\n"
            f"      · Mac 专属 → 两张名单都加（--target mac-whitelist 与 --target ios-exceptions）"
        )

    if violations:
        print("❌ target 成员归属检查未通过：")
        for item in violations:
            print(f"   · {item}")
        print("\n（逃生阀：SKIP_MEMBERSHIP_CHECK=1，CI 仍会兜底）")
        sys.exit(1)

    tail = f"，新增文件 {len(new_files)} 个已表态" if new_files else ""
    print(f"✅ target 成员归属一致（Mac 白名单 {len(mac)} 条 / iOS 例外表 {len(ios)} 条{tail}）")


if __name__ == "__main__":
    main()
