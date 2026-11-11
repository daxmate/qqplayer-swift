#!/usr/bin/env bash
#
# bump-version.sh — 升 QQPlayer 版本号（单一真源：项目级 build settings）
#
# 用法：./scripts/bump-version.sh <marketing> <build>
#   例：./scripts/bump-version.sh 1.2.0 63
#
# 1) 改 QQPlayer.xcodeproj/project.pbxproj 里**项目级** Debug/Release 两个
#    XCBuildConfiguration 的 MARKETING_VERSION / CURRENT_PROJECT_VERSION；
#    各 target 默认继承（iOS 与 macOS 因此天然同步）。
# 2) 「跟随式同步」target 级覆盖：某个 target 配置写死了旧版值（即本次改前
#    项目级的值）就一起改成新版；值与旧版不一致的（如测试 target 的 1.0/1）
#    保持不动。这样既不误伤测试 target，也不需要维护例外表。
# 3) 改完直接解析 pbxproj 打印项目级 + 每个 target 的最终取值（不依赖
#    xcodebuild，避免 -list / -showBuildSettings 卡住或超时）。

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


def block_text(rng):
    return "\n".join(lines[rng[0]:rng[1] + 1])


def read_value(rng, key):
    for i in range(rng[0], rng[1] + 1):
        m = re.fullmatch(r"(\t+)" + key + r" = ([^;]+);", lines[i])
        if m:
            return m.group(2)
    return None


def write_value(rng, key, value):
    """改块内该键的唯一一行，保留原缩进；返回命中行数。"""
    hits = 0
    for i in range(rng[0], rng[1] + 1):
        m = re.fullmatch(r"(\t+)" + key + r" = [^;]+;", lines[i])
        if m:
            lines[i] = "%s%s = %s;" % (m.group(1), key, value)
            hits += 1
    return hits


def config_name(rng):
    for i in range(rng[0], rng[1] + 1):
        m = re.fullmatch(r"\t+name = (\w+);", lines[i])
        if m:
            return m.group(1)
    return "?"


text = "\n".join(lines)

# ---- 项目级：单一真源 ----
root = re.search(r"rootObject = ([0-9A-F]{24})", text)
if not root:
    sys.exit("❌ 未找到 rootObject")
rng = find_block(root.group(1))
if not rng:
    sys.exit("❌ 未找到 PBXProject 对象块")

proj = block_text(rng)
m = re.search(r"buildConfigurationList = ([0-9A-F]{24})", proj)
if not m:
    sys.exit("❌ PBXProject 未找到 buildConfigurationList")
lrng = find_block(m.group(1))
if not lrng:
    sys.exit("❌ 未找到项目级 XCConfigurationList")

lst = block_text(lrng)
m = re.search(r"buildConfigurations = \((.*?)\);", lst, re.S)
if not m:
    sys.exit("❌ 项目级 XCConfigurationList 未找到 buildConfigurations")
ids = re.findall(r"([0-9A-F]{24})", m.group(1))
if len(ids) != 2:
    sys.exit("❌ 项目级配置数异常：%s" % ids)

old_mv = old_bv = None
for cid in ids:
    crng = find_block(cid)
    if not crng:
        sys.exit("❌ 未找到配置块 %s" % cid)
    mv = read_value(crng, "MARKETING_VERSION")
    bv = read_value(crng, "CURRENT_PROJECT_VERSION")
    if mv is None or bv is None:
        sys.exit(
            "❌ 配置 %s 缺少项目级版本键（MARKETING_VERSION=%s，"
            "CURRENT_PROJECT_VERSION=%s）；项目级应为单一真源" % (cid, mv, bv)
        )
    if old_mv is None:
        old_mv, old_bv = mv, bv
    elif (mv, bv) != (old_mv, old_bv):
        sys.exit(
            "❌ 项目级 Debug/Release 版本不一致（%s/%s vs %s/%s），请先修复"
            % (mv, bv, old_mv, old_bv)
        )
    hit_mv = write_value(crng, "MARKETING_VERSION", new_mv)
    hit_bv = write_value(crng, "CURRENT_PROJECT_VERSION", new_bv)
    if hit_mv != 1 or hit_bv != 1:
        sys.exit(
            "❌ 配置 %s 的项目级版本键异常（MARKETING_VERSION=%d，"
            "CURRENT_PROJECT_VERSION=%d）；项目级应为单一真源，请先修复"
            % (cid, hit_mv, hit_bv)
        )

# ---- target 级覆盖：跟随式同步 ----
config_ids = []
for cm in re.finditer(r"^\t\t([0-9A-F]{24}) /\* .*? \*/ = \{$", text, re.M):
    crng = find_block(cm.group(1))
    if crng and "isa = XCBuildConfiguration;" in block_text(crng):
        config_ids.append(cm.group(1))

cfg_target = {}
for tm in re.finditer(r"^\t\t([0-9A-F]{24}) /\* .*? \*/ = \{$", text, re.M):
    trng = find_block(tm.group(1))
    if not trng:
        continue
    tb = block_text(trng)
    if "isa = PBXNativeTarget;" not in tb and "isa = PBXAggregateTarget;" not in tb:
        continue
    tn = re.search(r"\n\t\t\tname = (.*?);", tb)
    bcl = re.search(r"buildConfigurationList = ([0-9A-F]{24})", tb)
    if not tn or not bcl:
        continue
    clrng = find_block(bcl.group(1))
    if not clrng:
        continue
    lm = re.search(r"buildConfigurations = \((.*?)\);", block_text(clrng), re.S)
    if not lm:
        continue
    for cid in re.findall(r"([0-9A-F]{24})", lm.group(1)):
        cfg_target[cid] = tn.group(1)

synced = []
kept = []
rows = []
for cid in config_ids:
    if cid in ids:
        continue  # 项目级已处理
    crng = find_block(cid)
    label = "%s/%s" % (cfg_target.get(cid, "未归属target"), config_name(crng))
    keys = []
    kept_keys = []
    for key, old, new in (
        ("MARKETING_VERSION", old_mv, new_mv),
        ("CURRENT_PROJECT_VERSION", old_bv, new_bv),
    ):
        cur = read_value(crng, key)
        if cur is None or cur == new:
            continue
        if cur == old:
            write_value(crng, key, new)
            keys.append(key)
        else:
            kept_keys.append("%s=%s" % (key, cur))
    mv = read_value(crng, "MARKETING_VERSION")
    bv = read_value(crng, "CURRENT_PROJECT_VERSION")
    if keys:
        synced.append("%s（%s）" % (label, "、".join(keys)))
    if kept_keys:
        kept.append("%s（%s）" % (label, "、".join(kept_keys)))
    rows.append((label, mv if mv is not None else new_mv, bv if bv is not None else new_bv))

open(path, "w", encoding="utf-8").write("\n".join(lines))

print("✅ 已更新项目级 %d 个配置：MARKETING_VERSION=%s CURRENT_PROJECT_VERSION=%s"
      % (len(ids), new_mv, new_bv))
if synced:
    print("✅ 跟随同步 target 级：" + "；".join(synced))
else:
    print("ℹ️ 没有 target 级覆盖需要跟随同步")
if kept:
    print("ℹ️ 保持不动（与旧版不一致）：" + "；".join(kept))

print("")
print("各 target 最终取值（解析 pbxproj）：")
print("  %-30s %-16s %s" % ("target/配置", "MARKETING", "BUILD"))
print("  %-30s %-16s %s" % ("项目级", new_mv, new_bv))
for label, mv, bv in rows:
    print("  %-30s %-16s %s" % (label, mv, bv))
PY
