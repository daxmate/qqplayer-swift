#!/usr/bin/env python3
"""
gen-traditional-to-simplified.py — 由 OpenCC TSCharacters.txt 生成
QQPlayer/Services/TraditionalToSimplifiedMap.swift（**繁→简**单字映射）。

为什么需要它（2026-09-16 事故）：
  显示层的繁→简方向原先由「简→繁表（SimplifiedTraditionalMap.swift）运行时反转」得到。
  问题有二：
  1. 多个简体字对应同一繁体字（开/𫔭 → 開，共 27 组），反转结果取决于 Swift
     Dictionary 的迭代顺序（哈希种子每进程随机）→ 同一首歌在两次启动里可能显示
     「火力全开」或「火力全𫔭」，后者是非 BMP 生僻字、系统字体无字形 → 屏幕上是豆腐块 囗。
  2. 生成简→繁表时丢弃了 OpenCC 的次选字形（发 → 發 丢了 髮），于是 為/髮/臺/隻/乾
     这些字形根本没有反查项 → 简体界面下原样显示繁体（「因為」「頭髮」显示成繁体）。
  OpenCC 自带权威的**繁→简**数据（TSCharacters.txt），繁→简方向直接用它，不需要也不允许反转。

用法：
  curl -sLO https://raw.githubusercontent.com/BYVoid/OpenCC/master/data/dictionary/TSCharacters.txt
  python3 scripts/gen-traditional-to-simplified.py --input TSCharacters.txt          # 写文件
  python3 scripts/gen-traditional-to-simplified.py --input TSCharacters.txt --check  # 只校验是否最新

过滤规则（对应 QQPlayerTests 里的不变量断言）：
  1. 每行取 OpenCC 的**首选值**（行内第一个字形）；
  2. 首选值为**非 BMP**（U+FFFF 以上）的行整行跳过 —— 显示层输出必须是基本平面内的
     可渲染字形，否则字体无字形、屏幕上是豆腐块（本次事故的观感）；
  3. 繁 = 简 的恒等行跳过（查不到即原样保留，语义等价，也省掉 600+ 行噪音）。

许可：OpenCC 数据为 Apache-2.0（https://github.com/BYVoid/OpenCC）。
"""
import argparse
import hashlib
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
OUT = REPO / "QQPlayer" / "Services" / "TraditionalToSimplifiedMap.swift"

HEADER = """//
//  TraditionalToSimplifiedMap.swift
//  QQPlayer
//
//  **繁→简**单字映射表（显示层字形归一的繁→简方向唯一数据源；未收录的字形原样保留）。
//  数据源: OpenCC TSCharacters.txt（Apache-2.0, https://github.com/BYVoid/OpenCC）
//  生成: scripts/gen-traditional-to-simplified.py --input TSCharacters.txt
//  输入指纹: {digest}
//
//  ⚠️ 不要再由 SimplifiedTraditionalMap.swift（简→繁）运行时反转出反查表：
//     多个简体字对应同一繁体字（开/𫔭 → 開 共 27 组），反转结果取决于 Dictionary 的
//     哈希顺序（每进程随机）→ 同一首歌可能显示「火力全开」或「火力全𫔭」（非 BMP，
//     字体无字形 = 豆腐块 囗）；且 為/髮/臺/隻 等次选字形在简→繁表里根本没有反查项。
//     事故与修法记录：2026-09-16。本文件是**唯一**繁→简数据源（形状测试守着这条）。
//
//  生成规则: 每行取 OpenCC 首选值；跳过首选值为非 BMP 的行（生僻异体，字体无字形）；
//            跳过 繁=简 的恒等行；按码点升序（生成结果稳定、diff 可读）。
//
import Foundation

/// 繁→简单字映射（OpenCC TSCharacters 首选值）
let traditionalToSimplifiedMap: [Character: Character] = [
"""


def parse(path):
    """返回 [(繁体, 简体)]：取首选值 + 两条过滤规则。"""
    entries = []
    skipped_nonbmp = 0
    skipped_identity = 0
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        traditional, variants = parts[0], parts[1].split(" ")
        simplified = variants[0]
        if len(traditional) != 1 or len(simplified) != 1:
            continue
        if ord(simplified) > 0xFFFF:          # 规则 2
            skipped_nonbmp += 1
            continue
        if traditional == simplified:          # 规则 3
            skipped_identity += 1
            continue
        entries.append((traditional, simplified))
    entries.sort(key=lambda pair: ord(pair[0]))
    return entries, skipped_nonbmp, skipped_identity


def render(entries, digest):
    body = "".join(f'    "{t}": "{s}",\n' for t, s in entries)
    return HEADER.replace("{digest}", digest) + body + "]\n"


def main():
    parser = argparse.ArgumentParser(description="生成 TraditionalToSimplifiedMap.swift")
    parser.add_argument("--input", required=True, help="OpenCC TSCharacters.txt 路径")
    parser.add_argument("--check", action="store_true", help="只校验仓库文件是否为最新（不写）")
    parser.add_argument("--output", default=str(OUT), help=f"输出路径（默认 {OUT}）")
    args = parser.parse_args()

    source = pathlib.Path(args.input)
    if not source.exists():
        print(f"❌ 找不到输入文件：{source}", file=sys.stderr)
        return 2
    digest = hashlib.sha256(source.read_bytes()).hexdigest()[:12]
    entries, skipped_nonbmp, skipped_identity = parse(source)
    text = render(entries, digest)
    out = pathlib.Path(args.output)

    if args.check:
        current = out.read_text(encoding="utf-8") if out.exists() else ""
        if current == text:
            print(f"✅ 已是最新（{len(entries)} 条）")
            return 0
        print("❌ 仓库文件与 OpenCC 数据不一致，请重新生成：", file=sys.stderr)
        print(f"   python3 scripts/gen-traditional-to-simplified.py --input {args.input}", file=sys.stderr)
        return 1

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text, encoding="utf-8")
    print(f"✅ 已写入 {out}")
    print(f"   条目 {len(entries)}｜跳过非 BMP {skipped_nonbmp}｜跳过恒等 {skipped_identity}｜指纹 {digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
