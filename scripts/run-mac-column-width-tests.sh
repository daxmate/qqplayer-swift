#!/usr/bin/env bash
# run-mac-column-width-tests.sh — 曲目列表列宽持久化的 swiftc 断言（无模拟器、无 DerivedData）
#
# 为什么存在：仓库没有 macOS 单测 target（QQPlayerTests 的 SDKROOT=iphoneos，
# 见 docs/sync-invariants.md:171），`QQPlayer/Mac/*` 不编 iOS；列宽持久化又是
# 「重启才看得出来」的行为，编译级验证抓不到。本脚本沿用 `run-mac-window-chrome-tests.sh`
# 的做法：swiftc **直编生产源码**（不复制实现）+ scripts/mac-column-width-harness 夹具，
# 用独立 UserDefaults suite 真跑 round-trip / 夹紧 / 脏值回落断言。
#
# 用法：scripts/run-mac-column-width-tests.sh [--verbose]
# 退出码：0 = 全部断言通过；1 = 有失败或编译失败；2 = 参数错误。

set -uo pipefail

cd "$(dirname "$0")/.." || { echo "❌ 无法进入仓库根"; exit 2; }

VERBOSE=0
for arg in "$@"; do
  case "$arg" in
    --verbose|-v) VERBOSE=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "❌ 未知参数：${arg}（仅支持 --verbose）"; exit 2 ;;
  esac
done

OUT_DIR="${TMPDIR:-/tmp}/qqp-mac-column-width-harness"
mkdir -p "$OUT_DIR" || { echo "❌ 无法创建构建目录 $OUT_DIR"; exit 1; }

PROD_SOURCES=(
  "QQPlayer/Mac/MacTrackColumnResizer.swift"
  "QQPlayer/Mac/MacTrackColumnWidthStore.swift"
)

FIXTURE_SOURCES=(
  "scripts/mac-column-width-harness/Stubs.swift"
  "scripts/mac-column-width-harness/main.swift"
)

echo "▶︎ 编译 harness（生产源码 + 夹具）"
swiftc -swift-version 5 -Onone -o "$OUT_DIR/mac-column-width-harness" \
  "${PROD_SOURCES[@]}" "${FIXTURE_SOURCES[@]}" 2>&1 | tee "$OUT_DIR/compile.log"
compile_status="${PIPESTATUS[0]}"
if [ "$compile_status" -ne 0 ]; then
  echo "❌ harness 编译失败（详见 $OUT_DIR/compile.log）"
  exit 1
fi
[ "$VERBOSE" -eq 1 ] && echo "✅ harness 编译通过 → $OUT_DIR/mac-column-width-harness"

echo "▶︎ 运行断言"
"$OUT_DIR/mac-column-width-harness"
exit $?
