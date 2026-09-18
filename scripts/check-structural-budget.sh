#!/usr/bin/env bash
# 结构预算棘轮 · 本地校验/生成入口（无模拟器、无 Testing）
#
#   scripts/check-structural-budget.sh [check|selftest|emit|emit-prints]
#
# check（默认）：用 fixture 基线校验当前 worktree —— 拆完文件、改完基线先跑这个再提交。
# selftest     ：合成输入正反验证（四条规则必须各自变红）。
# emit         ：重新生成「超长文件」基线到 stdout（只允许收紧后手工替换）。
# emit-prints  ：重新生成「裸 print」基线到 stdout。
#
# 口径实现在 QQPlayerTests/StructuralBudgetRule.swift（本脚本不复制计数逻辑）；
# 仓库根由该文件的 `#filePath` 推出，因此在任意 worktree 里运行都作用于该 worktree。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RULE="$REPO_ROOT/QQPlayerTests/StructuralBudgetRule.swift"
TOOL="$REPO_ROOT/scripts/structural-budget-tool.swift"
BIN="${TMPDIR:-/tmp}/structural-budget-tool"

[ -f "$RULE" ] || { echo "❌ 找不到口径实现：$RULE" >&2; exit 2; }
[ -f "$TOOL" ] || { echo "❌ 找不到工具：$TOOL" >&2; exit 2; }

swiftc -O -o "$BIN" "$RULE" "$TOOL"
exec "$BIN" "${1:-check}"
