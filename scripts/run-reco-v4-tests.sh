#!/usr/bin/env bash
# run-reco-v4-tests.sh — 推荐 v4 纯逻辑本地 harness（无模拟器 / 无网络 / 无 DB）
#
# 为什么存在：iOS 单测要 xcodebuild + 模拟器（CI 兜底），而纪律禁止本地起模拟器。
# 本脚本用 swiftc 直编**生产源码**（Matcher / SeedSampler / SelectionV4 / ProfileV3 /
# RankerV3 / Retention + 依赖类型）跑与 QQPlayerTests/RecommendationV4Tests.swift
# 同构的断言；`scripts/reco-v4-harness/shims.swift` 只补网络客户端类型，不进 App。
#
# 覆盖不到的（由 CI 的 xcodebuild test 兜底）：Swift Testing 套件本体、iOS/Mac 目标编译。
#
# 用法：
#   scripts/run-reco-v4-tests.sh            # 编译 + 跑
#   scripts/run-reco-v4-tests.sh --verbose  # 打印编译命令

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

VERBOSE=0
for arg in "$@"; do
  case "$arg" in
    --verbose|-v) VERBOSE=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "❌ 未知参数：$arg"; exit 2 ;;
  esac
done

SERVICES="QQPlayer/Services"
SOURCES=(
  "$SERVICES/RecommendationTypes.swift"
  "$SERVICES/RecommendationProfile.swift"
  "$SERVICES/RecommendationScoring.swift"
  "$SERVICES/RecommendationStore.swift"
  "$SERVICES/RecommendationV3Types.swift"
  "$SERVICES/CharacterMapResourceLoader.swift"
  "$SERVICES/RecommendationNormalization.swift"
  "$SERVICES/RecommendationLibraryMatcher.swift"
  "$SERVICES/RecommendationSeedSampler.swift"
  "$SERVICES/RecommendationSelectionV4.swift"
  "$SERVICES/RecommendationProfileV3.swift"
  "$SERVICES/RecommendationRankerV3.swift"
  "$SERVICES/RecommendationDownloadedRetention.swift"
  "scripts/reco-v4-harness/shims.swift"
  "scripts/reco-v4-harness/main.swift"
)

OUT="${TMPDIR:-/tmp}/reco-v4-harness"
mkdir -p "$OUT"
BIN="$OUT/reco-v4-tests"

if [ "$VERBOSE" = "1" ]; then
  echo "swiftc ${SOURCES[*]} -o $BIN"
fi

swiftc "${SOURCES[@]}" -o "$BIN" 2> "$OUT/compile.log"
STATUS=$?
if [ "$STATUS" -ne 0 ]; then
  echo "❌ 编译失败："
  sed -n '1,60p' "$OUT/compile.log"
  exit 1
fi

"$BIN"
