#!/usr/bin/env bash
# 自证测试：scripts/git-hooks/pre-push 的第 ④ 项「非 main 分支推送需显式确认」（2026-09-22 用户拍板）
#
# 做法：在临时目录建本地仓库 + 本地 bare remote（全程不联网），装上被验钩子，断言四条：
#   ① 推非 main 分支 → 被拦（退出码非 0，输出含 AGENTS.md 与 QQPLAYER_ALLOW_BRANCH_PUSH）
#   ② 同一次推送带 QQPLAYER_ALLOW_BRANCH_PUSH=1 → 放行
#   ③ 推 main → 不被本项拦（最小可控场景：单提交 / 无 merge / 无 .swift 改动）
#   ④ 删除远端分支（git push origin --delete <branch>）→ 不被本项拦
#
# fail-closed：任一断言失败即非 0 退出；trap 清理临时目录。
set -u

HOOK_SRC="$(cd "$(dirname "$0")" && pwd)/pre-push"
tmp="$(mktemp -d)" || exit 1
trap 'rm -rf "$tmp"' EXIT

remote="$tmp/remote.git"
repo="$tmp/repo"
pass=0
fail=0

[ -f "$HOOK_SRC" ] || { echo "❌ 找不到被验钩子：$HOOK_SRC"; exit 1; }

git init -q --bare "$remote" || exit 1
git init -q "$repo" || exit 1
git -C "$repo" symbolic-ref HEAD refs/heads/main
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
git -C "$repo" config commit.gpgsign false
git -C "$repo" remote add origin "$remote"

# 装被验钩子，并显式指定 core.hooksPath，避免被本机全局 hooksPath 覆盖
mkdir -p "$repo/.git/hooks"
cp "$HOOK_SRC" "$repo/.git/hooks/pre-push"
chmod +x "$repo/.git/hooks/pre-push"
git -C "$repo" config core.hooksPath "$repo/.git/hooks"

printf 'hello\n' >"$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -q -m "init"
git -C "$repo" branch feat/x

ok() { echo "  ✅ $1"; pass=$((pass + 1)); }
no() { echo "  ❌ $1"; fail=$((fail + 1)); }

# ---- 断言 ①：推非 main 分支 → 被拦 ----
echo "=== 断言 ①：推非 main 分支 → 被拦 ==="
out1="$(cd "$repo" && git push origin feat/x 2>&1)"; rc1=$?
echo "$out1"
if [ "$rc1" -ne 0 ]; then ok "退出码非 0（=$rc1）"; else no "退出码应为非 0，实际 $rc1"; fi
case "$out1" in *AGENTS.md*) ok "输出含 AGENTS.md" ;; *) no "输出缺 AGENTS.md" ;; esac
case "$out1" in *QQPLAYER_ALLOW_BRANCH_PUSH*) ok "输出含 QQPLAYER_ALLOW_BRANCH_PUSH" ;; *) no "输出缺 QQPLAYER_ALLOW_BRANCH_PUSH" ;; esac
if git -C "$remote" rev-parse --verify -q refs/heads/feat/x >/dev/null; then
  no "远端不应出现 refs/heads/feat/x"
else
  ok "远端未出现 refs/heads/feat/x（确实被拦）"
fi

# ---- 断言 ②：同一次推送带 QQPLAYER_ALLOW_BRANCH_PUSH=1 → 放行 ----
echo "=== 断言 ②：QQPLAYER_ALLOW_BRANCH_PUSH=1 → 放行 ==="
out2="$(cd "$repo" && QQPLAYER_ALLOW_BRANCH_PUSH=1 git push origin feat/x 2>&1)"; rc2=$?
echo "$out2"
if [ "$rc2" -eq 0 ]; then ok "退出码为 0"; else no "退出码应为 0，实际 $rc2"; fi
if git -C "$remote" rev-parse --verify -q refs/heads/feat/x >/dev/null; then
  ok "远端已出现 refs/heads/feat/x（确实放行）"
else
  no "远端未出现 refs/heads/feat/x"
fi

# ---- 断言 ③：推 main → 不被本项拦 ----
echo "=== 断言 ③：推 main → 不被本项拦 ==="
out3="$(cd "$repo" && git push origin main 2>&1)"; rc3=$?
echo "$out3"
if [ "$rc3" -eq 0 ]; then ok "退出码为 0（main 未被第 ④ 项拦）"; else no "退出码应为 0，实际 $rc3"; fi
if git -C "$remote" rev-parse --verify -q refs/heads/main >/dev/null; then
  ok "远端已出现 refs/heads/main"
else
  no "远端未出现 refs/heads/main"
fi

# ---- 断言 ④：删除远端分支 → 不被本项拦 ----
echo "=== 断言 ④：删除远端分支 → 不被本项拦 ==="
out4="$(cd "$repo" && git push origin --delete feat/x 2>&1)"; rc4=$?
echo "$out4"
if [ "$rc4" -eq 0 ]; then ok "退出码为 0（删分支未被第 ④ 项拦）"; else no "退出码应为 0，实际 $rc4"; fi
if git -C "$remote" rev-parse --verify -q refs/heads/feat/x >/dev/null; then
  no "远端仍存在 refs/heads/feat/x（删除未生效）"
else
  ok "远端 refs/heads/feat/x 已删除"
fi

echo ""
echo "结果：通过 $pass 项，失败 $fail 项"
if [ "$fail" -ne 0 ]; then
  echo "❌ pre-push 第 ④ 项自证测试未通过"
  exit 1
fi
echo "✅ pre-push 第 ④ 项自证测试全部通过（① 拦截 ✓ ② 放行 ✓ ③ main 不被拦 ✓ ④ 删分支不被拦 ✓）"
exit 0
