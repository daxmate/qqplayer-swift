#!/usr/bin/env bash
#
# bump-version.sh — 升 QQPlayer 版本号（单一真源：项目级 build settings）
#
# 用法：./scripts/bump-version.sh <marketing> <build>
#   例：./scripts/bump-version.sh 1.2.0 63
#
# 只改 QQPlayer.xcodeproj/project.pbxproj 里**项目级** Debug/Release 两个
# XCBuildConfiguration 的 MARKETING_VERSION / CURRENT_PROJECT_VERSION；
# 各 target 一律继承（iOS 与 macOS 因此天然同步）。
# 改完打印所有 target 的实际取值以便核对。

set -euo pipefail

usage() {
  echo "用法：$0 <marketing> <build>" >&2
  echo "  marketing 语义化版本，如 1.2.0" >&2
  echo "  build     正整数，如 63" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage
MARKETING="$1"
BUILD="$2"

if [[ ! "$MARKETING" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "❌ marketing 版本不合法：'$MARKETING'（需 x.y.z，如 1.2.0）" >&2
  exit 2
fi
if [[ ! "$BUILD" =~ ^[1-9][0-9]*$ ]]; then
  echo "❌ build 号不合法：'$BUILD'（需正整数，如 63）" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PBX="$ROOT/QQPlayer.xcodeproj/project.pbxproj"
PROJ="$ROOT/QQPlayer.xcodeproj"

if [[ ! -f "$PBX" ]]; then
  echo "❌ 找不到 $PBX" >&2
  exit 1
fi

python3 - "$PBX" "$MARKETING" "$BUILD" <<'PY'
import re
import sys

path, new_mv, new_bv = sys.argv[1:4]
lines = open(path, encoding="utf-8").read().split("\n")

def find_block(cid):
    """返回对象块的行区间 (start, end)（含首尾）。"""
    for i, line in enumerate(lines):
        if line.strip().startswith(cid) and line.rstrip().endswith("= {"):
            depth = 0
            for j in range(i, len(lines)):
                depth += lines[j].count("{") - lines[j].count("}")
                if depth == 0 and j > i:
                    return i, j
    return None

text = "\n".join(lines)
root = re.search(r"rootObject = ([0-9A-F]{24})", text)
if not root:
    sys.exit("❌ 未找到 rootObject")
rng = find_block(root.group(1))
if not rng:
    sys.exit("❌ 未找到 PBXProject 对象块")

proj = "\n".join(lines[rng[0]:rng[1] + 1])
m = re.search(r"buildConfigurationList = ([0-9A-F]{24})", proj)
if not m:
    sys.exit("❌ PBXProject 未找到 buildConfigurationList")
lrng = find_block(m.group(1))
if not lrng:
    sys.exit("❌ 未找到项目级 XCConfigurationList")

lst = "\n".join(lines[lrng[0]:lrng[1] + 1])
m = re.search(r"buildConfigurations = \((.*?)\);", lst, re.S)
if not m:
    sys.exit("❌ 项目级 XCConfigurationList 未找到 buildConfigurations")
ids = re.findall(r"([0-9A-F]{24})", m.group(1))
if len(ids) != 2:
    sys.exit("❌ 项目级配置数异常：%s" % ids)

changed = []
for cid in ids:
    rng = find_block(cid)
    if not rng:
        sys.exit("❌ 未找到配置块 %s" % cid)
    hit_mv = hit_bv = 0
    for i in range(rng[0], rng[1] + 1):
        line = lines[i]
        if re.fullmatch(r"\t+MARKETING_VERSION = .*;", line):
            lines[i] = "\t\t\t\tMARKETING_VERSION = %s;" % new_mv
            hit_mv += 1
        elif re.fullmatch(r"\t+CURRENT_PROJECT_VERSION = .*;", line):
            lines[i] = "\t\t\t\tCURRENT_PROJECT_VERSION = %s;" % new_bv
            hit_bv += 1
    if hit_mv != 1 or hit_bv != 1:
        sys.exit(
            "❌ 配置 %s 的项目级版本键异常（MARKETING_VERSION=%d，"
            "CURRENT_PROJECT_VERSION=%d）；项目级应为单一真源，请先修复"
            % (cid, hit_mv, hit_bv)
        )
    changed.append(cid)

open(path, "w", encoding="utf-8").write("\n".join(lines))
print("✅ 已更新项目级 %d 个配置：MARKETING_VERSION=%s CURRENT_PROJECT_VERSION=%s"
      % (len(changed), new_mv, new_bv))
PY

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "⚠️ 未找到 xcodebuild，跳过 target 取值核对"
  exit 0
fi

# xcodebuild 偶发卡住（工程不完整/首次打开索引）→ 用 perl alarm 兜底超时
xc() { perl -e 'alarm 120; exec @ARGV' -- xcodebuild "$@"; }

if ! TARGETS="$(xc -list -json -project "$PROJ" 2>/dev/null \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("\n".join(d["project"]["targets"]))')"; then
  echo "⚠️ xcodebuild -list 失败，跳过 target 取值核对"
  exit 0
fi

echo ""
echo "各 target 实际取值（Release）："
printf '  %-26s %-16s %s\n' "target" "MARKETING" "BUILD"
diffs=0
while IFS= read -r t; do
  [[ -n "$t" ]] || continue
  vals="$(xc -showBuildSettings -project "$PROJ" -target "$t" -configuration Release 2>/dev/null \
    | sed -nE 's/^[[:space:]]*(MARKETING_VERSION|CURRENT_PROJECT_VERSION) = (.*)$/\1=\2/p')"
  mv="$(printf '%s\n' "$vals" | sed -n 's/^MARKETING_VERSION=//p')"
  bv="$(printf '%s\n' "$vals" | sed -n 's/^CURRENT_PROJECT_VERSION=//p')"
  note=""
  if [[ "$mv" == "$MARKETING" && "$bv" == "$BUILD" ]]; then
    :
  else
    note="  ⚠️ 与项目级不一致（该 target 有自己的覆盖）"
    diffs=$((diffs + 1))
  fi
  printf '  %-26s %-16s %s%s\n' "$t" "${mv:-?}" "${bv:-?}" "$note"
done <<< "$TARGETS"

if [[ $diffs -gt 0 ]]; then
  echo ""
  echo "⚠️ 有 $diffs 个 target 的取值与项目级不同（测试 target 自带覆盖属已知情况）。"
fi
