#!/usr/bin/env python3
"""
gen-zh-hant.py — 从 zh-Hans.lproj/Localizable.strings 生成台湾繁体 zh-Hant.lproj/Localizable.strings。

转换依据：QQPlayer/Resources/SimplifiedToTraditional.tsv 的简→繁单字映射
（OpenCC STCharacters.txt 数据，Apache-2.0）。
2026-09-17 P2-① 起该表已从 Swift 字面量（旧 SimplifiedTraditionalMap.swift）下沉为资源文件，
运行时唯一入口是 QQPlayer/Services/CharacterMapResourceLoader.swift；两者共用同一份 TSV，
基线夹具 QQPlayerTests/Fixtures/simplified-to-traditional.baseline.tsv 与资源字节一致。
解析规则与 CharacterMapResourceLoader.parse 对齐（每行 `<简>\t<繁>`，键/值各一个 Unicode
标量；空行容忍，列数/标量/重复键判错）。
单字表无法处理词组级差异
（软件→軟體、网络→網路 等），脚本会输出【台湾用词校对候选】清单，需人工
按 TW 惯用词过一遍再提交。

用法：
  python3 scripts/gen-zh-hant.py                # 读 main 仓库，写 zh-Hant.lproj/Localizable.strings
  python3 scripts/gen-zh-hant.py --dry-run      # 只打印转换结果与校对候选，不写文件
"""
import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MAP_TSV = REPO / "QQPlayer" / "Resources" / "SimplifiedToTraditional.tsv"
HANS_STRINGS = REPO / "QQPlayer" / "Resources" / "zh-Hans.lproj" / "Localizable.strings"
HANT_STRINGS = REPO / "QQPlayer" / "Resources" / "zh-Hant.lproj" / "Localizable.strings"

# --- fail-closed 下限（本次缺陷的核心：静默错比崩溃危险）---
# 真表 3881 条（2026-09-22 实测）；低于此数说明解析到的是残表/错表，宁可报错也不写文件。
MIN_MAP_ENTRIES = 1000
# 转换率告警下限：912 条 zh-Hans 正常应有绝大多数含简体字面（实测约 9 成）。
# 低于此比例 = 映射表或源文件可疑，即使能算出结果也要显式告警，不静默写盘。
MIN_CHANGE_RATIO = 0.30


class MapLoadError(Exception):
    """映射表不存在/读不出/格式坏 —— 一律 fail-closed。"""


# 台湾惯用词（转换后若命中，提示人工确认；键=大陆用词，值=台湾惯用）
# 说明：单字转换会得到 软件→軟件、网络→網絡，需词级修正为 軟體、網路。
TW_WORD_REVIEW = {
    "軟件": "軟體",
    "網絡": "網路",
    "視頻": "影片",     # 视具体情况（視頻/影片/視訊 依语境）
    "信息": "資訊",
    "菜單": "選單",
    "設置": "設定",
    "搜索": "搜尋",
    "保存": "儲存",
    "加載": "載入",
    "創建": "建立",
    "上傳": "上傳",     # 相同，无需改
    "軟盤": "磁碟",
    "硬盤": "硬碟",
    "鼠標": "滑鼠",
    "程序": "程式",     # 程序/程式 依语境
    "打印": "列印",
    "鏈接": "連結",
    "服務器": "伺服器",
    "文件夾": "資料夾",
}

# 台湾标准字形修正（OpenCC STCharacters 会选异体/通用繁体，台湾标准用字不同）
# 啓→啟（開啟）、爲→為（因為/成為）
TW_CHAR_FIX = {
    "啓": "啟",
    "爲": "為",
}


def parse_map(path: Path) -> dict[str, str]:
    """解析简→繁 TSV（每行 `<简体字>\t<繁体字>`，各恰好一个 Unicode 标量）。

    与 CharacterMapResourceLoader.parse 同规则：空行容忍，其余异常（列数不对/
    非单标量/键重复/读不出）一律抛 MapLoadError，绝不「跳过坏行继续」。
    """
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise MapLoadError(f"读不出 {path}：{exc}") from exc

    mapping: dict[str, str] = {}
    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.rstrip("\r")
        if not line:
            continue
        columns = line.split("\t")
        if len(columns) != 2:
            raise MapLoadError(f"第 {lineno} 行：期望 2 列（键<TAB>值），实际 {len(columns)} 列")
        key, value = columns
        if len(key) != 1 or len(value) != 1:
            raise MapLoadError(f"第 {lineno} 行：键/值必须是单个 Unicode 标量")
        if key in mapping:
            raise MapLoadError(f"第 {lineno} 行：键 {key} 重复（数据有歧义）")
        mapping[key] = value
    return mapping


def to_traditional(text: str, mapping: dict[str, str]) -> str:
    """逐字简→繁转换（未收录的字原样保留）。"""
    return "".join(mapping.get(ch, ch) for ch in text)


def parse_strings(path: Path) -> list[tuple[str | None, str, str]]:
    """解析 Apple .strings：返回 [(注释, key, value)]。"""
    entries: list[tuple[str | None, str, str]] = []
    comment: str | None = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line.startswith("/*") and line.endswith("*/"):
            comment = line
            continue
        m = re.match(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$', line)
        if m:
            entries.append((comment, m.group(1), m.group(2)))
            comment = None
        elif line:
            # 非空且无法解析的行（如多行注释）原样保留到输出？直接跳过
            pass
    return entries


def main() -> int:
    parser = argparse.ArgumentParser(description="生成台湾繁体 Localizable.strings")
    parser.add_argument("--dry-run", action="store_true", help="只打印不写文件")
    args = parser.parse_args()

    if not MAP_TSV.exists():
        print(f"❌ 映射表不存在: {MAP_TSV}", file=sys.stderr)
        return 1
    if not HANS_STRINGS.exists():
        print(f"❌ zh-Hans strings 不存在: {HANS_STRINGS}", file=sys.stderr)
        return 1

    # --- fail-closed：映射表坏 → 立即退出，绝不写文件（空表会让全部条目原样落盘）---
    try:
        mapping = parse_map(MAP_TSV)
    except MapLoadError as exc:
        print(f"❌ 简→繁映射表解析失败（fail-closed，不写文件）：{exc}", file=sys.stderr)
        return 1
    print(f"ℹ️  简→繁映射: {len(mapping)} 字（{MAP_TSV.relative_to(REPO)}）")
    if len(mapping) < MIN_MAP_ENTRIES:
        print(
            f"❌ 映射表仅 {len(mapping)} 条，低于下限 {MIN_MAP_ENTRIES} 条 —— 明显异常，"
            "fail-closed，不写文件。请核对 SimplifiedToTraditional.tsv 是否完整。",
            file=sys.stderr,
        )
        return 1

    entries = parse_strings(HANS_STRINGS)
    print(f"ℹ️  zh-Hans 条目: {len(entries)}")
    if not entries:
        print(
            f"❌ zh-Hans 条目为 0（{HANS_STRINGS}）—— 源文件空了，fail-closed，不写文件。",
            file=sys.stderr,
        )
        return 1

    out_lines: list[str] = []
    review_hits: list[str] = []
    changed = 0
    for comment, key, value in entries:
        if comment:
            out_lines.append(comment)
        converted = to_traditional(value, mapping)
        # 台湾标准字形修正（异体→标准）
        converted = "".join(TW_CHAR_FIX.get(ch, ch) for ch in converted)
        if converted != value:
            changed += 1
        # 词级校对候选
        hits = [tw for cn, tw in TW_WORD_REVIEW.items() if cn in converted]
        if hits:
            review_hits.append(f"  {value}  →  {converted}   [候选: {'/'.join(set(hits))}]")
        out_lines.append(f'"{key}" = "{converted}";')
        out_lines.append("")

    # --- 转换率异常 → 显式告警（不静默）---
    ratio = changed / len(entries)
    if ratio < MIN_CHANGE_RATIO:
        print(
            f"⚠️  转换率异常低：{changed}/{len(entries)} = {ratio:.1%}（下限 {MIN_CHANGE_RATIO:.0%}）"
            " —— 映射表或 zh-Hans 源可能不对，写盘前请人工确认。",
            file=sys.stderr,
        )

    if args.dry_run:
        print("\n".join(out_lines))
        print(f"\n===== 台湾用词校对候选（{len(review_hits)} 处）=====")
        print("\n".join(review_hits))
        print(f"===== 统计: {changed}/{len(entries)} 条发生转换 =====")
        return 0

    HANT_STRINGS.parent.mkdir(parents=True, exist_ok=True)
    HANT_STRINGS.write_text("\n".join(out_lines), encoding="utf-8")
    print(f"✅ 已写入 {HANT_STRINGS}（{changed}/{len(entries)} 条转换）")
    print(f"\n===== 台湾用词校对候选（{len(review_hits)} 处，需人工过一遍）=====")
    print("\n".join(review_hits))
    print("校对说明：单字转换后的词组需按台湾惯用修正（如 軟件→軟體），")
    print("修正后重新运行本脚本不会覆盖（直接编辑生成的 strings 文件即可）。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
