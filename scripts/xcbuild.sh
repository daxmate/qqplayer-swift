#!/usr/bin/env bash
#
# xcbuild.sh — QQPlayer 统一构建入口（共享 SPM 缓存 + 独立 DerivedData）
#
# 为什么存在：
#   Xcode 每次在新 DerivedData 路径下构建，都会新建一个空的 SourcePackages 并重新
#   解析/clone 全部 SPM 依赖（GRDB.swift 的 git 子模块 SQLiteLib 在慢网络下能挂 1-2
#   小时）。本项目早就有一份完整缓存，但靠人手写 `-clonedSourcePackagesDirPath`
#   很容易漏 —— 本脚本把它固化成唯一入口，所有 worktree / 子代理一律走这里。
#
# 用法（与 xcodebuild 参数完全一致，脚本自动补两个路径参数）：
#   scripts/xcbuild.sh build-for-testing -scheme QQPlayer -destination 'generic/platform=iOS Simulator'
#   scripts/xcbuild.sh build -scheme QQPlayerMac -destination 'platform=macOS'
#   scripts/xcbuild.sh test -scheme QQPlayer -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
#
# 环境变量：
#   QQPLAYER_DD       覆盖 DerivedData 路径（默认 <工作树根>/build/DerivedData，按工作区隔离防互踩）
#   QQPLAYER_SPM      显式指定共享 SPM 缓存路径；指定后严格校验，不合格直接失败、不回退
#                     （不设时按候选链自动解析：本工作树 → 主仓库 → 兄弟 worktree → Xcode 默认 DerivedData）
#   QQPLAYER_BUILD_DIR 覆盖统一产物根目录（默认 <工作树根>/build）
#   QQPLAYER_NO_LOCK  置 1 跳过构建锁（仅在确知无并发构建时用）
#
# 构建锁（2026-09-13 立，血的教训）：
#   两个 worktree 同时构建时，SPM 会对**同一份共享 clone 缓存**做并发解析——
#   实测会把 repositories/<pkg> 镜像清空并重新 `git clone --mirror`（日志特征
#   `skipping cache due to an error: ... already exists unexpectedly`），慢网络下
#   克隆挂死、构建 CPU 归零、缓存处于半残状态（当日两次踩坑，含子代理构建）。
#   DerivedData 会话名隔离挡不住这个（踩的是共享 clone 缓存）→ 这里用目录锁把**所有**
#   走本入口的构建全局串行化；后到者排队等待，超时/陈旧锁自动清理。
#
# 退出码：0 成功｜2 共享 SPM 缓存不合格或缺失｜3 构建锁等待超时｜4 成品复制失败
set -euo pipefail

# 工作树根：每个 worktree 各自一份 build/（产物不再落到 /tmp）。
if command -v git >/dev/null 2>&1; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  WORKSPACE_NAME="$(basename "$ROOT")"
  GIT_COMMON_DIR="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
else
  ROOT="$(pwd)"
  WORKSPACE_NAME="$(basename "$ROOT")"
  GIT_COMMON_DIR=""
fi

# 共享 SPM 缓存：本工作树 build/SourcePackagesShared 存在就用；否则回退到主仓库
# （git-common-dir 的父目录），所有 worktree 复用同一份 clone 缓存，不重新 clone。
if [ -n "$GIT_COMMON_DIR" ]; then
  MAIN_ROOT="$(dirname "$GIT_COMMON_DIR")"
else
  MAIN_ROOT="$ROOT"
fi
# ---- 共享 SPM 缓存解析（候选链 + 回退，2026-11-24 加固）----
# 为什么不再只认一个默认路径：不同机器铺缓存的位置不同（本 worktree / 主仓库 /
# 兄弟 worktree / Xcode 默认 DerivedData），而且「目录存在」不等于「缓存完整」——
# 一次中断的构建会留下空壳 SourcePackagesShared，被选中后必然 exit 2，哪怕别处
# 有完整缓存。故改为候选链逐个校验：先到先得，全不合格才报错并列出各自原因。

# 合格判据与 xcodebuild 的报错文案保持一致：两个包的实际 checkout 都在。
spm_cache_ok() {
  [ -d "${1}/checkouts/GRDB.swift" ] && [ -d "${1}/checkouts/SFBAudioEngine" ]
}

# 不合格原因（只用于日志，不参与判断）。
spm_cache_reason() {
  if [ ! -d "${1}" ]; then
    printf '目录不存在'
  elif [ ! -d "${1}/checkouts" ]; then
    printf '缺少 checkouts/（空壳目录）'
  elif [ ! -d "${1}/checkouts/GRDB.swift" ]; then
    printf '缺少 checkouts/GRDB.swift'
  elif [ ! -d "${1}/checkouts/SFBAudioEngine" ]; then
    printf '缺少 checkouts/SFBAudioEngine'
  else
    printf '未知原因'
  fi
}

SHARED_SPM=""
SPM_CANDIDATE_N=0
SPM_TRIED=""

# 试一个候选：同一路径只试一次（本工作树 / 主仓库 / 其它 worktree 常重叠）；
# 合格即采用并返回 0，否则打印跳过原因返回 1。
spm_try_candidate() {
  local cand="${1}"
  case "${SPM_TRIED}" in
    *"|${cand}|"*) return 1 ;;
  esac
  SPM_TRIED="${SPM_TRIED}|${cand}|"
  SPM_CANDIDATE_N=$((SPM_CANDIDATE_N + 1))
  if spm_cache_ok "${cand}"; then
    SHARED_SPM="${cand}"
    echo "✔ 共享 SPM 缓存：${cand}（第 ${SPM_CANDIDATE_N} 候选）"
    return 0
  fi
  echo "✘ 跳过 ${cand}：$(spm_cache_reason "${cand}")" >&2
  return 1
}

# 第 1 候选：QQPLAYER_SPM 显式指定 —— 严格模式，不合格直接失败、不回退。
# （用户点名了某份缓存却被悄悄换掉，比直接报错更难排查。）
if [ -n "${QQPLAYER_SPM:-}" ]; then
  if spm_cache_ok "${QQPLAYER_SPM}"; then
    SHARED_SPM="${QQPLAYER_SPM}"
    echo "✔ 共享 SPM 缓存：${QQPLAYER_SPM}（QQPLAYER_SPM 显式指定）"
  else
    echo "❌ 共享 SPM 缓存不合格：${QQPLAYER_SPM}（$(spm_cache_reason "${QQPLAYER_SPM}")）" >&2
    echo "   QQPLAYER_SPM 是显式指定，脚本不会回退到其它缓存；请修正路径或铺好缓存后重试。" >&2
    exit 2
  fi
fi

# 第 2/3 候选：本工作树 → 主仓库（git-common-dir 的父目录）。
if [ -z "${SHARED_SPM}" ]; then
  for CAND in "${ROOT}/build/SourcePackagesShared" "${MAIN_ROOT}/build/SourcePackagesShared"; do
    if spm_try_candidate "${CAND}"; then break; fi
  done
fi

# 第 4 候选：兄弟 worktree（同一份缓存常被先建好的工作树铺过）。
if [ -z "${SHARED_SPM}" ] && command -v git >/dev/null 2>&1; then
  while IFS= read -r WT_PATH; do
    [ -n "${WT_PATH}" ] || continue
    if spm_try_candidate "${WT_PATH}/build/SourcePackagesShared"; then break; fi
  done <<SPM_WORKTREES
$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
SPM_WORKTREES
fi

# 第 5 候选：Xcode 默认 DerivedData（多份合格时取最近修改的那份）。
if [ -z "${SHARED_SPM}" ]; then
  XCODE_SPM_BEST=""
  XCODE_SPM_BEST_MTIME=0
  for CAND in "${HOME}/Library/Developer/Xcode/DerivedData"/*/SourcePackages; do
    if [ ! -d "${CAND}" ]; then continue; fi
    if spm_cache_ok "${CAND}"; then
      CAND_MTIME="$(stat -f %m "${CAND}" 2>/dev/null || echo 0)"
      if [ "${CAND_MTIME}" -gt "${XCODE_SPM_BEST_MTIME}" ]; then
        XCODE_SPM_BEST="${CAND}"
        XCODE_SPM_BEST_MTIME="${CAND_MTIME}"
      fi
    else
      echo "✘ 跳过 ${CAND}：$(spm_cache_reason "${CAND}")" >&2
    fi
  done
  if [ -n "${XCODE_SPM_BEST}" ]; then
    if spm_try_candidate "${XCODE_SPM_BEST}"; then :; fi
  fi
fi

# 全军覆没：列出试过的全部候选 + 给出可执行的下一步，而不是只说「不存在」。
if [ -z "${SHARED_SPM}" ]; then
  echo "❌ 未找到合格的共享 SPM 缓存（已试 ${SPM_CANDIDATE_N} 个候选）" >&2
  echo "   合格判据：checkouts/GRDB.swift 与 checkouts/SFBAudioEngine 同时存在。" >&2
  echo "   已试候选：" >&2
  OLD_IFS="${IFS}"
  IFS='|'
  for TRIED in ${SPM_TRIED}; do
    if [ -n "${TRIED}" ]; then echo "     - ${TRIED}" >&2; fi
  done
  IFS="${OLD_IFS}"
  echo "   下一步：从已构建过的机器 rsync 一份 build/SourcePackagesShared 过来，" >&2
  echo "           或在本机用 Xcode 打开工程解析一次依赖（Package Dependencies → Resolve），" >&2
  echo "           再用 QQPLAYER_SPM=<路径> 显式指定。" >&2
  exit 2
fi

BUILD_DIR="${QQPLAYER_BUILD_DIR:-$ROOT/build}"
DERIVED_DATA="${QQPLAYER_DD:-$BUILD_DIR/DerivedData}"
mkdir -p "$DERIVED_DATA"

# ---- 构建锁（全局串行；mkdir 原子性做锁，macOS 无 flock）----
LOCK_DIR="/tmp/qqplayer-xcbuild.lock"
if [ "${QQPLAYER_NO_LOCK:-0}" != "1" ]; then
  waited=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    lock_age=0
    if [ -d "$LOCK_DIR" ]; then
      lock_mtime="$(stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0)"
      lock_age=$(( $(date +%s) - lock_mtime ))
    fi
    if [ "$lock_age" -gt 1800 ]; then
      echo "⚠️  构建锁超过 30 分钟未释放（疑似中断残留），强制清理：$LOCK_DIR"
      rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR"
      continue
    fi
    if [ "$waited" -ge 2400 ]; then
      echo "❌ 等待构建锁超时（40 分钟）：${LOCK_DIR}（如确无并发构建，用 QQPLAYER_NO_LOCK=1 绕过）" >&2
      exit 3
    fi
    [ $(( waited % 60 )) -eq 0 ] && echo "⏳ 其他构建进行中，排队等待（已等 ${waited}s）…"
    sleep 5
    waited=$((waited + 5))
  done
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true; exit 130' INT TERM
fi

echo "▶︎ 共享 SPM 缓存：$SHARED_SPM"
echo "▶︎ DerivedData：$DERIVED_DATA"
echo "▶︎ 命令：xcodebuild $*"

# ⚠️ 不能用 exec：exec 会替换 shell 进程 → EXIT trap 不执行 → 锁永不释放
# （2026-09-13 实测：冒烟测试后 /tmp/qqplayer-xcbuild.lock 残留）。
xcodebuild \
  -clonedSourcePackagesDirPath "$SHARED_SPM" \
  -derivedDataPath "$DERIVED_DATA" \
  "$@"

# ---- 成品汇总（仅 build 动作）----
# 所有 .app 统一复制到 <build>/Products/<sdk>/<Config>/，保留签名/扩展属性；
# test / build-for-testing 不复制，避免测试构建污染成品目录。
COPY_FAILED=0
if [ "${1:-}" = "build" ]; then
  CONFIG="Debug"
  PREV=""
  for ARG in "$@"; do
    if [ "$PREV" = "-configuration" ]; then CONFIG="$ARG"; fi
    case "$ARG" in
      -configuration=*) CONFIG="${ARG#-configuration=}" ;;
    esac
    PREV="$ARG"
  done

  SDK=""
  case " $* " in
    *"iOS Simulator"*|*"-sdk iphonesimulator"*) SDK="iphonesimulator" ;;
    *"-sdk iphoneos"*|*"platform=iOS"*|*"id="*) SDK="iphoneos" ;;
    *"macOS"*|*"-sdk macosx"*) SDK="macosx" ;;
  esac

  if [ -n "$SDK" ]; then
    if [ "$SDK" = "macosx" ]; then
      SRC_PRODUCTS="$DERIVED_DATA/Build/Products/$CONFIG"
    else
      SRC_PRODUCTS="$DERIVED_DATA/Build/Products/$CONFIG-$SDK"
    fi
    DEST_DIR="${BUILD_DIR}/Products/${SDK}/${CONFIG}"
    FOUND=0
    for APP in "${SRC_PRODUCTS}"/*.app; do
      [ -d "${APP}" ] || continue
      FOUND=1
      DEST_APP="${DEST_DIR}/$(basename "${APP}")"
      # 目标目录建不出来（例如 Products 被占成普通文件 / 权限问题）按失败处理，
      # 不能因为「后面还有 ditto 兜着」就继续往下打印成功。
      if ! mkdir -p "${DEST_DIR}"; then
        echo "❌ 复制成品失败：${APP} → ${DEST_APP}（无法创建目录 ${DEST_DIR}）" >&2
        COPY_FAILED=$((COPY_FAILED + 1))
        continue
      fi
      DITTO_STATUS=0
      ditto "${APP}" "${DEST_APP}" || DITTO_STATUS=$?
      if [ "${DITTO_STATUS}" -ne 0 ]; then
        echo "❌ 复制成品失败：${APP} → ${DEST_APP}（ditto exit ${DITTO_STATUS}）" >&2
        COPY_FAILED=$((COPY_FAILED + 1))
        continue
      fi
      # ditto 成功也不等于成品可用：主可执行文件缺失的空壳 .app 同样要拦。
      # 可执行文件位置随 SDK 变：macOS 在 Contents/MacOS/，iOS 在 bundle 根目录
      # （QQPlayer.app/QQPlayer）—— 写死 macOS 布局会把所有 iOS 构建误报成失败。
      APP_EXEC=""
      if [ "${SDK}" = "macosx" ]; then
        for EXEC in "${DEST_APP}/Contents/MacOS/"*; do
          if [ -f "${EXEC}" ] && [ -x "${EXEC}" ]; then
            APP_EXEC="${EXEC}"
            break
          fi
        done
      else
        APP_BUNDLE="$(basename "${DEST_APP}" .app)"
        if [ -f "${DEST_APP}/${APP_BUNDLE}" ] && [ -x "${DEST_APP}/${APP_BUNDLE}" ]; then
          APP_EXEC="${DEST_APP}/${APP_BUNDLE}"
        fi
      fi
      if [ -n "${APP_EXEC}" ]; then
        echo "✅ 成品：${DEST_APP}"
      elif [ "${SDK}" = "macosx" ]; then
        echo "❌ 复制成品失败：${APP} → ${DEST_APP}（缺少 Contents/MacOS 可执行文件）" >&2
        COPY_FAILED=$((COPY_FAILED + 1))
      else
        echo "❌ 复制成品失败：${APP} → ${DEST_APP}（缺少 bundle 根目录可执行文件 ${APP_BUNDLE}）" >&2
        COPY_FAILED=$((COPY_FAILED + 1))
      fi
    done
    if [ "${FOUND}" = "0" ]; then
      echo "⚠️  未在 ${SRC_PRODUCTS} 找到 .app（跳过成品复制）" >&2
    fi
  fi
fi

# exit 4：构建本身可能已经成功，但成品没落地 —— 下游（build-app.sh / 手工取包）
# 必须能发现，不能用「xcodebuild 返回 0」当成「包好了」。
if [ "${COPY_FAILED}" -ne 0 ]; then
  echo "❌ 成品复制失败 ${COPY_FAILED} 个（详见上面的 ❌ 行），退出码 4" >&2
  exit 4
fi
