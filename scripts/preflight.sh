#!/usr/bin/env bash
#
# preflight.sh — 推送前的本地预检（quick / full）
#
# ⚠️ 它不是 CI 的替代品：单元测试仍然只由 CI 跑（.github/workflows/ci.yml 的
#    "Test (xcodebuild test, iOS simulator)"），本机禁起模拟器。本脚本只覆盖
#    「推上去才知道红」的那一类静态/编译问题，目的是减少无效 push 的往返
#    （2026-11-13 背景：一天 12 次 push 有 7 次被 cancel）。
#
# 用法：
#   scripts/preflight.sh            # 默认 quick，目标 < 4 分钟
#   scripts/preflight.sh --quick    # swiftlint + swiftformat + target 成员 + 同步 harness
#   scripts/preflight.sh --full     # quick + iOS / macOS 编译级验证，目标 < 10 分钟
#
# 约定：
#   - 任一步失败立即停跑，但仍会把已跑步骤的耗时表打完（便于看清卡在哪一步）。
#   - 退出码：0 = 全绿；1 = 有步骤失败；2 = 用法错误。
#   - 所有 xcodebuild 一律走 scripts/xcbuild.sh（共享 SPM 缓存）。裸 xcodebuild 会
#     新建空的 SourcePackages 并重新 clone 21 个 SPM 包，慢网络下能挂 1-2 小时。
#   - 只做静态检查 + 编译级验证，绝不起模拟器、不截图。
#   - 不复刻 CI 的全部步骤：设备探测自测、DSQ 资源共享 harness、iOS/macOS
#     版本号一致性断言仍在 CI 里跑（它们不在本脚本的既定范围）。

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

usage() {
  sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
}

MODE=""
case "${1:-}" in
  "" | --quick) MODE="quick" ;;
  --full) MODE="full" ;;
  -h | --help) usage; exit 0 ;;
  *)
    echo "❌ 未知参数：$1"
    echo
    usage
    exit 2
    ;;
esac
if [ "$#" -gt 1 ]; then
  echo "❌ 只接受一个参数（收到 $# 个）：$*"
  usage
  exit 2
fi

STEP_NAMES=()
STEP_SECS=()
STEP_RCS=()
FAILED=0
TOTAL_START="$(date +%s)"

print_row() {
  printf '  %-2s %5ss  %s\n' "$1" "$2" "$3"
}

finish() {
  local total=$(( $(date +%s) - TOTAL_START ))
  local i
  echo
  echo "──── 预检结果（$MODE）────"
  # 用下标循环而不是 "${!arr[@]}"：macOS 自带 bash 3.2 在 set -u + 空数组下会报 unbound variable。
  local n="${#STEP_NAMES[@]}"
  if [ "$n" -eq 0 ]; then
    echo "  （没有执行任何步骤）"
  fi
  local i=0
  while [ "$i" -lt "$n" ]; do
    if [ "${STEP_RCS[$i]}" -eq 0 ]; then
      print_row "✅" "${STEP_SECS[$i]}" "${STEP_NAMES[$i]}"
    else
      print_row "❌" "${STEP_SECS[$i]}" "${STEP_NAMES[$i]}（退出码 ${STEP_RCS[$i]}）"
    fi
    i=$(( i + 1 ))
  done
  echo "  总耗时 ${total}s"
  if [ "$FAILED" -ne 0 ]; then
    echo "❌ 预检失败：$FAILED 项未通过（逐条修，别推）"
  else
    echo "✅ 预检通过（单测仍以 CI 为准）"
  fi
}

run_step() {
  local name="$1"
  shift
  echo
  echo "==> $name"
  local t0 rc t1
  t0="$(date +%s)"
  "$@"
  rc=$?
  t1="$(date +%s)"
  STEP_NAMES+=("$name")
  STEP_SECS+=("$(( t1 - t0 ))")
  STEP_RCS+=("$rc")
  if [ "$rc" -eq 0 ]; then
    echo "<== ✅ $name（$(( t1 - t0 ))s）"
  else
    echo "<== ❌ $name（$(( t1 - t0 ))s，退出码 $rc）"
    FAILED=$(( FAILED + 1 ))
  fi
  return "$rc"
}

# 任一步失败：先打完整耗时表，再退出（不继续跑后面的步骤）。
fail_fast() {
  finish
  exit 1
}

for tool in swiftlint swiftformat python3; do
  command -v "$tool" >/dev/null 2>&1 \
    || echo "⚠️ 未找到 $tool（brew install $tool），对应步骤会直接失败"
done

echo "preflight ($MODE) @ $(git rev-parse --short HEAD 2>/dev/null || echo '?') $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"

# ---- quick ----
run_step "swiftlint lint（全量）" swiftlint lint || fail_fast
run_step "swiftformat --lint ." swiftformat --lint . || fail_fast

if git rev-parse --verify -q HEAD~1 >/dev/null 2>&1; then
  # 与 CI 一致：只看相对上一提交新增的文件是否登记了 target 归属
  run_step "target membership（--base HEAD~1）" \
    python3 scripts/check-target-membership.py --base HEAD~1 || fail_fast
else
  run_step "target membership（无 HEAD~1，只查名单完整性）" \
    python3 scripts/check-target-membership.py || fail_fast
fi

run_step "local sync harness（swiftc 直编，无模拟器）" \
  bash scripts/run-local-sync-tests.sh || fail_fast

# ---- full ----
if [ "$MODE" = "full" ]; then
  # 与 CI 的 Swift job 同一条命令形态，只是 destination 用 generic（不启动模拟器）。
  run_step "iOS 编译（Debug，generic iOS Simulator）" \
    scripts/xcbuild.sh build \
    -project QQPlayer.xcodeproj \
    -scheme QQPlayer \
    -destination 'generic/platform=iOS Simulator' \
    -configuration Debug \
    CODE_SIGNING_ALLOWED=NO || fail_fast

  # macOS job 用 build/DerivedDataMac，这里保持一致，避免两套产物互相拖慢。
  # 用 `env VAR=...` 而不是「VAR=... 函数名」：后者只在 bash 内部生效，若哪天被
  # 换成 sh / 或包装层改写，变量会静默丢失，两套构建就落到同一个 DerivedData 里。
  run_step "macOS 编译（Debug，QQPlayerMac）" \
    env QQPLAYER_DD="$ROOT/build/DerivedDataMac" \
    scripts/xcbuild.sh build \
    -project QQPlayer.xcodeproj \
    -scheme QQPlayerMac \
    -configuration Debug \
    CODE_SIGNING_ALLOWED=NO || fail_fast
fi

finish
[ "$FAILED" -eq 0 ] || exit 1
exit 0
