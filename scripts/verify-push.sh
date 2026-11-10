#!/usr/bin/env bash
# verify-push.sh — push 之后的 CI 终局校验（把「事后门禁」从人肉变脚本）
#
# 背景（2026-09-20 用户拍板）：本仓库不做 PR，ruleset 只禁强推/禁删除，
# CI 在 push 之后才跑 —— 也就是说 main 变红是允许发生的。唯一可靠的兜底
# 是「推完立刻等 CI 出结论」。本脚本把这一步固化：找不到 run、run 未绿、
# 超时，全部以非零退出，不允许「报告说全绿」。
#
# 用法：
#   scripts/verify-push.sh            # 校验当前 HEAD 是否已推送且 CI 全绿
#   scripts/verify-push.sh <sha>      # 校验指定 commit
#   VERIFY_TIMEOUT_MIN=60 scripts/verify-push.sh
#   SHOW_JOBS=1 scripts/verify-push.sh   # 额外列出每个 job 的结论
#
# 退出码：0 全绿；1 CI 红/取消；2 环境或前置条件不满足（未推送/无 gh/超时）

set -uo pipefail

TIMEOUT_MIN="${VERIFY_TIMEOUT_MIN:-45}"
POLL_SEC=10

die() { echo "❌ $*" >&2; exit 2; }

command -v gh >/dev/null 2>&1 || die "未找到 gh（GitHub CLI）"
command -v git >/dev/null 2>&1 || die "未找到 git"
command -v python3 >/dev/null 2>&1 || die "未找到 python3"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "不在 git 仓库内"
cd "$ROOT" || die "无法进入仓库根目录"

SHA="${1:-$(git rev-parse HEAD)}"
git rev-parse --verify "${SHA}^{commit}" >/dev/null 2>&1 || die "无效 commit: $SHA"
SHA="$(git rev-parse "${SHA}^{commit}")"
SHORT="$(git rev-parse --short "$SHA")"

# ---- 前置：必须已推到 origin/main ----
git fetch origin main --quiet 2>/dev/null || echo "⚠️  fetch 失败，继续用本地 origin/main"
REMOTE_SHA="$(git rev-parse origin/main 2>/dev/null || true)"
[ -n "$REMOTE_SHA" ] || die "读不到 origin/main"
if [ "$REMOTE_SHA" != "$SHA" ]; then
  if git merge-base --is-ancestor "$SHA" "$REMOTE_SHA" 2>/dev/null; then
    echo "ℹ️  $SHORT 是 origin/main 的祖先（已被后续提交覆盖），校验包含它的最近一次 run"
  else
    die "$SHORT 还没在 origin/main 上（先 push，或确认 sha）"
  fi
fi

json_field() { # $1=json  $2=field
  printf '%s' "$1" | python3 -c 'import json,sys
f=sys.argv[1]
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(d.get(f,"") if isinstance(d,dict) else "")' "$2" 2>/dev/null
}

# ---- 找这次 push 触发的 run ----
DEADLINE=$(( $(date +%s) + TIMEOUT_MIN * 60 ))
RUN_JSON=""
while :; do
  RUN_JSON="$(gh run list --commit "$SHA" --limit 20 --json databaseId,status,conclusion,workflowName,url 2>/dev/null || true)"
  [ -n "$RUN_JSON" ] && [ "$RUN_JSON" != "[]" ] && break
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    die "等了 ${TIMEOUT_MIN} 分钟仍没看到 $SHORT 的 CI run（检查 workflow 触发条件）"
  fi
  echo "… 等待 CI run 出现（$SHORT，每 ${POLL_SEC}s 查一次）"
  sleep "$POLL_SEC"
done

IDS="$(printf '%s' "$RUN_JSON" | python3 -c 'import json,sys
print(" ".join(str(r["databaseId"]) for r in json.load(sys.stdin)))' 2>/dev/null)"
[ -n "$IDS" ] || die "解析 run 列表失败"

FAIL=0
SUMMARY=""
for id in $IDS; do
  REMAIN=$(( DEADLINE - $(date +%s) ))
  [ "$REMAIN" -gt 0 ] || die "总超时（${TIMEOUT_MIN} 分钟）尚未跑完"
  echo "… 等待 run $id"
  gh run watch "$id" --exit-status --interval "$POLL_SEC" >/dev/null 2>&1 || true

  STATE="$(gh run view "$id" --json status,conclusion,workflowName,url 2>/dev/null || true)"
  CONC="$(json_field "$STATE" conclusion)"
  NAME="$(json_field "$STATE" workflowName)"
  URL="$(json_field "$STATE" url)"
  [ -n "$CONC" ] || CONC="unknown"
  if [ "$CONC" != "success" ]; then
    FAIL=1
    SUMMARY="${SUMMARY}❌ ${NAME:-run $id}: $CONC  $URL"
    SUMMARY="$SUMMARY
"
  else
    SUMMARY="${SUMMARY}✅ ${NAME:-run $id}: success  $URL"
    SUMMARY="$SUMMARY
"
    if [ "${SHOW_JOBS:-0}" = "1" ]; then
      SUMMARY="${SUMMARY}$(gh run view "$id" --json jobs --jq '.jobs[] | "   - \(.name): \(.conclusion)"' 2>/dev/null)
"
    fi
  fi
done

echo ""
echo "===== CI 终局（$SHORT）====="
printf '%s' "$SUMMARY"

if [ "$FAIL" -ne 0 ]; then
  echo "----- 失败摘要（最后 60 行）-----"
  for id in $IDS; do
    gh run view "$id" --log-failed 2>/dev/null | tail -60
  done
  echo "❌ CI 未全绿：修掉再推，或给出回退方案。不要口头声称全绿。"
  exit 1
fi

echo "✅ CI 全绿。把上面结论贴进完成报告；用例数核对：gh run view <id> --log | grep -E 'Executed .* tests'"
exit 0
