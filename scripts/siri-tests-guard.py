#!/usr/bin/env python3
"""siri-tests-guard.py — QQPlayerSiriTests 的「防烂掉」守护（审计 2026-09-12 🔴-2）。

背景（可核查事实，非推测）
--------------------------
QQPlayerSiriTests 的 4 个测试文件都 `import AppIntentsTesting`：

    QQPlayerSiriTests/BaseTestCase.swift:12   import AppIntentsTesting
    QQPlayerSiriTests/EntityQueryTests.swift:9
    QQPlayerSiriTests/IntentExecutionTests.swift:9
    QQPlayerSiriTests/SpotlightTests.swift:10

而当前工具链（Xcode 26.6 / iPhoneSimulator26.5.sdk）**不提供 AppIntentsTesting 框架**：

    $ ls /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks/
    ... XCTest.framework  XCUIAutomation.framework  Testing.framework   # 无 AppIntentsTesting.framework
    $ find /Applications/Xcode.app -iname "*AppIntentsTesting*"        # 无输出

因此该 target 既不在任何 scheme 的 Testables 里（QQPlayer.xcscheme 唯一 Testable =
QQPlayerTests），也无法编译 → CI 与本地都没有执行路径。

本脚本做什么
------------
在「无法编译」的前提下提供**能跑的编译级/结构级验证**，并保证豁免不会永久静默：

1) 存在性：4 个测试文件必须在（防「悄悄删掉测试」）
2) 引用完整性：测试按字符串索引 App Intent / Entity / Enum 名字
   （`definitions.intents["ResumePlaybackIntent"]` 等）。逐个核对这些名字在
   QQPlayer/AppIntents/** 里仍有对应类型声明——这是这条线最主要的腐坏方式
   （生产侧改名/删除意图，测试却永远编译不到、无人发现）
3) 金丝雀：一旦工具链开始提供 AppIntentsTesting，立即以非 0 退出并要求
   maintainer 把 target 接回 scheme + CI（豁免到期，不许继续静默）
4) 打印当前缺失符号，供 ci.yml 注释引用

退出码：0 = 全部通过；1 = 有问题（见输出）。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SIRI_TESTS_DIR = REPO_ROOT / "QQPlayerSiriTests"
APPINTENTS_DIR = REPO_ROOT / "QQPlayer" / "AppIntents"

# 豁免所依赖的测试支持框架名（缺失即当前无法编译；出现即豁免到期）
EXEMPTED_FRAMEWORK = "AppIntentsTesting"

# 工具链里承载测试支持框架的目录（XCTest / XCUIAutomation / Testing 都在此）
PLATFORM_FRAMEWORK_DIRS = [
    Path("/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform"
         "/Developer/Library/Frameworks"),
    Path("/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform"
         "/Developer/Library/Frameworks"),
]

EXPECTED_TEST_FILES = [
    "BaseTestCase.swift",
    "EntityQueryTests.swift",
    "IntentExecutionTests.swift",
    "SpotlightTests.swift",
]

# 测试里按字符串索引的定义名
REFERENCE_PATTERN = re.compile(
    r'definitions\.(intents|entities|enums)\["([A-Za-z_][A-Za-z0-9_]*)"\]'
)


def fail(msg: str) -> None:
    print(f"❌ {msg}", file=sys.stderr)


def check_files_exist() -> bool:
    ok = True
    for name in EXPECTED_TEST_FILES:
        if not (SIRI_TESTS_DIR / name).is_file():
            fail(f"QQPlayerSiriTests/{name} 不存在——这条测试线不得被静默删除")
            ok = False
    if ok:
        print(f"✅ 测试文件齐备（{len(EXPECTED_TEST_FILES)} 个）")
    return ok


def collect_appintent_type_names() -> set[str]:
    """QQPlayer/AppIntents/** 下所有类型声明名（含命名空间内嵌套声明）。"""
    names: set[str] = set()
    decl = re.compile(
        r'^\s*(?:public\s+|internal\s+|private\s+|fileprivate\s+)?'
        r'(?:final\s+)?'
        r'(?:struct|enum|class|actor|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)',
        re.M,
    )
    for path in APPINTENTS_DIR.rglob("*.swift"):
        names.update(decl.findall(path.read_text(encoding="utf-8")))
    return names


def check_references() -> bool:
    declared = collect_appintent_type_names()
    if not declared:
        fail(f"{APPINTENTS_DIR} 下未找到任何类型声明——路径或结构已变，需人工确认")
        return False

    referenced: set[str] = set()
    for path in sorted(SIRI_TESTS_DIR.glob("*.swift")):
        for _kind, name in REFERENCE_PATTERN.findall(path.read_text(encoding="utf-8")):
            referenced.add(name)

    if not referenced:
        fail("测试里未发现任何 definitions.intents/entities/enums 引用——"
             "引用写法或文件结构已变，守护会失效，请人工确认")
        return False

    missing = sorted(referenced - declared)
    if missing:
        fail("以下名字被 Siri 测试引用，但 QQPlayer/AppIntents/** 已无对应类型"
             "（生产侧改名/删除 → 测试已失效，CI 因豁免看不见）：")
        for name in missing:
            print(f"    - {name}", file=sys.stderr)
        return False

    print(f"✅ 引用完整：{len(referenced)} 个定义名在 AppIntents 源码中均可解析")
    return True


def find_framework() -> Path | None:
    for directory in PLATFORM_FRAMEWORK_DIRS:
        candidate = directory / f"{EXEMPTED_FRAMEWORK}.framework"
        if candidate.exists():
            return candidate
    return None


def check_canary() -> bool:
    found = find_framework()
    if found is not None:
        fail(f"工具链已提供 {EXEMPTED_FRAMEWORK}（{found}）——豁免到期。"
             "请把 QQPlayerSiriTests 接回某个 scheme 的 Testables 并加入 CI，"
             "然后删除本脚本与 ci.yml 中的豁免说明。")
        return False
    print(f"✅ 金丝雀：{EXEMPTED_FRAMEWORK} 仍不在当前工具链"
          f"（已查 {len(PLATFORM_FRAMEWORK_DIRS)} 个 platform Framework 目录）"
          f"——豁免仍然成立，但这条线只有结构级验证（见下）")
    return True


def main() -> int:
    print("== QQPlayerSiriTests 守护 ==")
    results = [check_files_exist(), check_references(), check_canary()]
    if all(results):
        print("\n结论：结构级守护通过。⚠️ 运行时行为仍未被自动验证"
              "（target 无法编译：缺 AppIntentsTesting，见文件头证据）。")
        return 0
    print("\n结论：存在需要处理的问题（见上）。", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
