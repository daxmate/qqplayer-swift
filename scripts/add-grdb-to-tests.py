#!/usr/bin/env python3
"""add-grdb-to-tests.py — 把 GRDB 框架链接进 QQPlayerTests target（一次性工具）。

⚠️ 已废弃（审计 2026-09-12 ⚰️ 死代码）：目的已达成，无再执行场景。
   QQPlayerTests 已具备 GRDB 依赖：
     - project.pbxproj:1008  QQPlayerTests packageProductDependencies 含 23C312EB… /* GRDB */
     - QQPlayerTests Frameworks phase 同样已加好
   对本仓库再跑一次是幂等空操作（若重复执行可能产生重复条目，请勿执行）。
   按子代理守则 §6（不得删文件）本批次**只登记不删除**，等待 maintainer 清理。
   清理前请先确认全仓无引用：
     grep -rn "add-grdb-to-tests" . --exclude-dir=.git --exclude-dir=build
   （README 的 scripts/ 清单已标注本文件为遗留工具；如删除本文件请一并删该行。）

QQPlayerTests 需要直接 `import GRDB`（内存库跑聚合查询测试），
但该 target 没有 package 依赖。本脚本做 3 处最小修改：
  1. PBXBuildFile 新增 GRDB in Frameworks 条目（复用 SiriIntentsExtension 的 product 23C312EB）
  2. QQPlayerTests Frameworks phase 加该 build file
  3. QQPlayerTests target 加 packageProductDependencies
写回前 plutil -lint 校验，失败则回滚。
"""
import re
import subprocess
import sys
import uuid
from pathlib import Path

PBXPROJ = Path("QQPlayer.xcodeproj/project.pbxproj")
GRDB_PRODUCT = "23C312EB2E7806AB00342F7C /* GRDB */"
TEST_FRAMEWORKS_PHASE = "EA89D66C6B3FB7A8E12FC173"
TEST_TARGET = "AC4D23167CDF8A94F2CA6D89"


def gen_id(lines):
    used = set()
    for line in lines:
        for m in re.finditer(r"\b([0-9A-F]{24})\b", line):
            used.add(m.group(1))
    while True:
        c = uuid.uuid4().hex[:24].upper()
        if c not in used:
            return c


def main():
    original = PBXPROJ.read_text()
    lines = original.splitlines(keepends=True)

    # 幂等：QQPlayerTests target 已带 packageProductDependencies 则跳过
    target_block = original.split("/* End PBXNativeTarget section */")[0]
    test_target_idx = target_block.find(f"{TEST_TARGET} /* QQPlayerTests */")
    if test_target_idx != -1 and "packageProductDependencies" in target_block[test_target_idx:]:
        print("✅ QQPlayerTests 已含 GRDB package dependency，跳过")
        return
    if test_target_idx == -1:
        print("❌ 找不到 QQPlayerTests target")
        sys.exit(1)

    new_id = gen_id(lines)
    buildfile = f"\t\t{new_id} /* GRDB in Frameworks */ = {{isa = PBXBuildFile; productRef = {GRDB_PRODUCT}; }};\n"

    # 1) PBXBuildFile section
    end_idx = None
    for i, line in enumerate(lines):
        if "/* End PBXBuildFile section */" in line:
            end_idx = i
            break
    assert end_idx is not None, "找不到 End PBXBuildFile section"
    lines.insert(end_idx, buildfile)

    # 2) QQPlayerTests Frameworks phase files
    phase_idx = None
    for i, line in enumerate(lines):
        if f"{TEST_FRAMEWORKS_PHASE} /* Frameworks */ = {{" in line:
            phase_idx = i
            break
    assert phase_idx is not None, "找不到 QQPlayerTests Frameworks phase"
    # 在 phase 的 files 列表第一项（Foundation）前插入
    for i in range(phase_idx, phase_idx + 10):
        if "Foundation.framework in Frameworks */," in lines[i]:
            lines.insert(i, f"\t\t\t\t{new_id} /* GRDB in Frameworks */,\n")
            break
    else:
        raise AssertionError("找不到 Foundation.framework in Frameworks 锚点")

    # 3) QQPlayerTests target packageProductDependencies
    target_idx = None
    for i, line in enumerate(lines):
        if f"{TEST_TARGET} /* QQPlayerTests */ = {{" in line:
            target_idx = i
            break
    assert target_idx is not None, "找不到 QQPlayerTests target"
    for i in range(target_idx, target_idx + 20):
        if line_startswith_name(lines, i, "QQPlayerTests"):
            lines.insert(i, "\t\t\tpackageProductDependencies = (\n")
            lines.insert(i + 1, f"\t\t\t\t{GRDB_PRODUCT},\n")
            lines.insert(i + 2, "\t\t\t);\n")
            break
    else:
        raise AssertionError("找不到 QQPlayerTests target 的 name 行")

    new_text = "".join(lines)
    if new_text == original:
        print("⚠️ 无变化")
        return

    PBXPROJ.write_text(new_text)
    r = subprocess.run(["plutil", "-lint", str(PBXPROJ)], capture_output=True, text=True)
    if r.returncode != 0:
        PBXPROJ.write_text(original)
        print(f"❌ plutil -lint 失败，已回滚: {r.stderr}")
        sys.exit(1)
    print(f"✅ GRDB 已加入 QQPlayerTests target（buildfile={new_id}），plutil -lint 通过")


def line_startswith_name(lines, i, name):
    return f"name = {name};" in lines[i]


if __name__ == "__main__":
    main()
