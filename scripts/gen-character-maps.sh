#!/usr/bin/env bash
#
# gen-character-maps.sh — 由「Swift 字面量版」映射表导出 TSV（资源 + 基线夹具的唯一生成器）
#
# 为什么存在（P2-① 简繁映射表下沉）：
#   简→繁 / 繁→简两张单字映射表原本是 6900 行 Swift 字面量（每个 entry 一个
#   `"简": "繁",` 行），编译/IDE 索引负担很重。下沉成资源文件时**数据必须逐字不变**，
#   而「逐字不变」不能靠人誊抄——本脚本编译**原始字面量源文件**，把两张表 dump 成
#   按码点排序的 `键\t值` TSV，一次运行同时产出：
#     - 资源文件（进 app bundle，运行时加载）
#     - 基线夹具（进 QQPlayerTests/Fixtures，测试用它断言「加载后的表 == 基线」）
#   两者由同一次 dump 写出 → 字节必然一致（测试再断言一次，防手改）。
#
# 用法：
#   scripts/gen-character-maps.sh --ref <git-ref> --resources <dir> --fixtures <dir>
#   scripts/gen-character-maps.sh          # 默认 --ref HEAD，输出到仓库约定路径
#
# ⚠️ --ref 必须是**还没下沉**的版本（映射表还是 Swift 字面量）：
#    脚本把该 ref 下的两个 .swift 与一个 dump main 一起用 swiftc 编译，
#    字面量版能直接 dump；下沉后版本在命令行进程里读不到 bundle 资源 → 会 fail-closed 失败。
#
# 校验（任一不满足直接报错退出，绝不写出可疑数据）：
#   - 键/值都必须是**单个 Unicode 标量**（否则 TSV 的「一字符一列」假设不成立）
#   - 键/值不得含制表符 / 换行 / 其他控制字符（否则破坏行结构）
#   - 跨文件键集合不得重复（一张表里同一 key 出现两次 = 数据有歧义）
set -euo pipefail

REF="HEAD"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCES_DIR="$REPO_ROOT/QQPlayer/Resources"
FIXTURES_DIR="$REPO_ROOT/QQPlayerTests/Fixtures"

while [ $# -gt 0 ]; do
  case "$1" in
    --ref) REF="$2"; shift 2 ;;
    --resources) RESOURCES_DIR="$2"; shift 2 ;;
    --fixtures) FIXTURES_DIR="$2"; shift 2 ;;
    *) echo "❌ 未知参数：$1" >&2; exit 2 ;;
  esac
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git -C "$REPO_ROOT" show "$REF:QQPlayer/Services/SimplifiedTraditionalMap.swift" > "$TMP/SimplifiedTraditionalMap.swift"
git -C "$REPO_ROOT" show "$REF:QQPlayer/Services/TraditionalToSimplifiedMap.swift" > "$TMP/TraditionalToSimplifiedMap.swift"

cat > "$TMP/main.swift" <<'SWIFT'
import Foundation

/// 单标量判定：TSV 一行两列，每列必须恰好一个 Unicode 标量
func singleScalar(_ c: Character) -> Unicode.Scalar? {
    let scalars = Array(c.unicodeScalars)
    return scalars.count == 1 ? scalars[0] : nil
}

func dump(_ name: String, _ map: [Character: Character], to dir: URL) {
    var lines: [(sortKey: Unicode.Scalar, text: String)] = []
    var seen = Set<Character>()
    for (key, value) in map {
        guard let k = singleScalar(key), let v = singleScalar(value) else {
            FileHandle.standardError.write("❌ \(name): 非单标量条目（key=\(key) value=\(value)）\n".data(using: .utf8)!)
            exit(1)
        }
        for scalar in [k, v] where scalar.properties.generalCategory == .control
            || scalar == "\t" || scalar == "\n" || scalar == "\r" {
            FileHandle.standardError.write("❌ \(name): 键/值含控制字符 U+\(String(scalar.value, radix: 16, uppercase: true))\n".data(using: .utf8)!)
            exit(1)
        }
        guard seen.insert(key).inserted else {
            FileHandle.standardError.write("❌ \(name): 键 \(key) 重复\n".data(using: .utf8)!)
            exit(1)
        }
        // 排序键 = 码点（与 Swift String 排序无关，保证跨平台/跨运行稳定）
        lines.append((sortKey: k, text: "\(key)\t\(value)"))
    }
    // 按码点升序（每个 key 都是单标量，直接比标量值）
    lines.sort { $0.sortKey.value < $1.sortKey.value }
    let text = lines.map { $0.text }.joined(separator: "\n") + "\n"
    try! text.write(to: dir.appendingPathComponent("\(name).tsv"), atomically: true, encoding: .utf8)
    FileHandle.standardError.write("✅ \(name): \(lines.count) 条\n".data(using: .utf8)!)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
dump("SimplifiedToTraditional", simplifiedToTraditionalMap, to: outDir)
dump("TraditionalToSimplified", traditionalToSimplifiedMap, to: outDir)
SWIFT

echo "▶︎ 编译 $REF 的两张表（字面量版）+ dump main…"
swiftc -O "$TMP/SimplifiedTraditionalMap.swift" "$TMP/TraditionalToSimplifiedMap.swift" "$TMP/main.swift" -o "$TMP/dump"

mkdir -p "$TMP/out" "$RESOURCES_DIR" "$FIXTURES_DIR"
"$TMP/dump" "$TMP/out"

# 资源文件（★ 与基线夹具字节一致：同一次 dump 输出，先落资源再复制成夹具）
cp "$TMP/out/SimplifiedToTraditional.tsv" "$RESOURCES_DIR/SimplifiedToTraditional.tsv"
cp "$TMP/out/TraditionalToSimplified.tsv" "$RESOURCES_DIR/TraditionalToSimplified.tsv"
cp "$TMP/out/SimplifiedToTraditional.tsv" "$FIXTURES_DIR/simplified-to-traditional.baseline.tsv"
cp "$TMP/out/TraditionalToSimplified.tsv" "$FIXTURES_DIR/traditional-to-simplified.baseline.tsv"

# 哈希清单（before/after 对比用：改造后测试断言「表 == 夹具」且夹具哈希未变）
{
  echo "# 简繁映射表基线哈希（由 scripts/gen-character-maps.sh --ref $REF 生成）"
  echo "# 格式：<sha256>  <文件名>（文件名相对仓库根）"
  (cd "$REPO_ROOT" && shasum -a 256 \
      "QQPlayerTests/Fixtures/simplified-to-traditional.baseline.tsv" \
      "QQPlayerTests/Fixtures/traditional-to-simplified.baseline.tsv")
} > "$FIXTURES_DIR/character-maps.baseline.sha256"

echo "▶︎ 资源：$RESOURCES_DIR/{SimplifiedToTraditional,TraditionalToSimplified}.tsv"
echo "▶︎ 夹具：$FIXTURES_DIR/{simplified-to-traditional,traditional-to-simplified}.baseline.tsv"
cat "$FIXTURES_DIR/character-maps.baseline.sha256"
