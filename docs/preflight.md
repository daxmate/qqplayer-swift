# 推送前本地预检（preflight）🚦

> 为什么有这份文档：CI 从 push 到出结论要等一整轮（2026-11-13 实测：Swift job 5m32，
> 其中 Set up job 222s、测试步骤 92s；自托管 runner 四个 job 串行跑，总 16m54）。
> 当天 12 次 push 里有 7 次被 cancel —— 绝大多数是「推上去才发现 lint / 编译红」。
> `scripts/preflight.sh` 把这类「本机就能查出来」的问题提前拦下来，减少无谓往返。

## 一、它是什么 / 不是什么

**是**：推送前的静态检查 + 编译级验证，一条命令跑完，失败就停、并把每步耗时打出来。

**不是**：
- 不是 CI 的替代品 —— **本地绿 ≠ 提交绿**：**单测只在 CI 跑**（本机纪律：不起模拟器），
  preflight 不跑 `xcodebuild test`；本脚本全绿只说明「静态检查 + 编译级验证」这一层过了，
  行为正确性、测试结果、真机表现仍以 CI 与真机验收为准。
- 不是「跑完就一定能绿」。它只覆盖编译期/静态期能抓住的问题；行为错误、时序问题、UI 效果仍然靠 CI 与真机。
- 不替 `scripts/git-hooks/pre-push` 兜底 —— 那个钩子仍会做「main 线性 + 改动范围 lint + 成员归属」。

## 二、用法

```bash
scripts/preflight.sh            # 默认 quick，目标 < 4 分钟
scripts/preflight.sh --quick    # 显式 quick
scripts/preflight.sh --full     # quick + iOS / macOS 编译级验证，目标 < 10 分钟
```

- 输出：每步 `==> 步骤名` 开头、`<== ✅/❌ 步骤名（Ns）` 结尾，最后一张耗时表。
- 退出码：`0` 全绿 / `1` 有步骤失败 / `2` 用法错误。
- 任一步失败**立即停跑**，但会先把已跑步骤的耗时表打完（便于看清卡在哪一步）。
- 全程**不起模拟器**；所有 xcodebuild 一律走 `scripts/xcbuild.sh`（共享 SPM 缓存 + 工作区隔离的 DerivedData）。

## 三、两个档位分别跑什么

| 档位 | 步骤 | 对应的 CI 位置 |
|---|---|---|
| quick | `swiftlint lint`（全量，只报不修） | Swift job「Lint (swiftlint)」 |
| quick | `swiftformat --lint .` | Swift job「Format (swiftformat --lint)」 |
| quick | `python3 scripts/check-target-membership.py`（有 `HEAD~1` 时带 `--base HEAD~1`） | Swift job「Target membership (guard)」 |
| quick | `bash scripts/run-local-sync-tests.sh` | local-harness job（swiftc 直编，无模拟器） |
| full | `xcbuild.sh build -scheme QQPlayer -destination 'generic/platform=iOS Simulator' -configuration Debug` | Swift job 的编译面（不含 test） |
| full | `xcbuild.sh build -scheme QQPlayerMac -configuration Debug`（`QQPLAYER_DD=build/DerivedDataMac`） | macOS job「Build QQPlayerMac」 |

## 四、实测耗时（2026-11-13，xmini / Xcode 27.2）

quick，**闭包缓存热**（日常复跑）：

| 步骤 | 耗时 |
|---|---|
| swiftlint lint（734 文件，0 violation；`--no-cache` 复测 0.7s） | 0–1s |
| swiftformat --lint .（0/744 需格式化） | 1s |
| target membership | 0s |
| local sync harness（718 断言） | 21s |
| **合计** | **22s** |

quick，**闭包缓存冷**（全新 worktree 第一次跑）：harness 156s（编译闭包迭代 15 轮），**合计 158s**。

full，`build/` 全新（DerivedData 全清，SPM checkout 走共享缓存）：quick 三项 2s + harness 20s + iOS 44s + macOS 41s = **107s**。

> 结论：quick 日常 20 秒级、冷启动约 2.5 分钟、full 冷启动约 2 分钟以内（本机空闲时）。
> 有别的构建在跑时，`xcbuild.sh` 的全局锁会让编译步骤排队，那段等待计入该步骤耗时。

## 五、该跑哪档

| 改了什么 | 跑哪个 |
|---|---|
| 只改 `.md` / 注释 | 不用跑（pre-push 钩子也放行） |
| 改 Swift 源码、加文件 | `--quick` |
| 改 pbxproj / target 归属 / 共享 SPM 依赖 | `--full` |
| 动 iOS 与 Mac 共用代码 | `--full` |
| 改 CI workflow / 脚本 | `--quick` + 复核 workflow 语法 |

## 六、它没覆盖的（仍由 CI 兜底）

- **单元测试**（约 2481 例）：只在 CI 的 `Test (xcodebuild test, iOS simulator)` 跑，本机禁模拟器。
- `scripts/detect-device-test.py`（真机探测判据自测）、`scripts/run-dsq-shared-tests.sh`（DSQ 资源共享 harness）。
- iOS / macOS 版本号一致性断言（`Assert iOS/macOS version sync`）。
- 编译警告零容忍：CI 从 `/tmp/xcodebuild-*.log` 里 grep `warning:`；preflight 只保证「编得过」。

## 七、坑

1. **不要裸 `xcodebuild`**：新 DerivedData 会新建空 `SourcePackages` 重新 clone 21 个 SPM 包，
   GRDB 的 git 子模块在慢网络下能挂 1–2 小时。一律 `scripts/xcbuild.sh`。
2. **harness 闭包缓存 key 含 worktree 根路径**（`$TMPDIR/qqp-sync-harness-build/closure-cache.json`）：
   换 worktree 第一次跑必然付出 ~150s 冷启动；`--refresh` 可强制重算。
3. **别在脚本运行中编辑它**：bash 是边走边读的，中途改文件会让它重放后面的代码块
   （2026-11-13 实测：一次 full 因此跑了两次 macOS 编译）。
