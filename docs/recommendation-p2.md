# 本地 AI 推荐 P2：Mac 内嵌 MLX 模型（已退役，存档）

> 状态：**2026-11-13 推荐 v3 起已整体移除**（MLX SPM 依赖、模型下载/校验/删除、模型设置全部删除；planner 恒为规则实现）。本文仅作历史存档，不再代表当前实现；当前实现见 `RecommendationV3Engine` 与 `RecommendationProfileV3`。

> 未接入期间：Mac / iOS 均按规则 planner 运行，功能不退化；模型管理 UI 已可用（下载 / 校验 / 删除）。

## 1. 架构

```
TasteProfile（P1 画像）
  └─ RecommendationProfileSummary      纯值摘要（艺人 / 年代 / genre / 完成率 / 曲库规模 / 语言线索）
       ├─ RecommendationPlanPrompt     严格 JSON prompt（system + user）
       └─ RecommendationPlanning 协议
            ├─ RuleRecommendationPlanner     包装 P1 RecommendationIntentBuilder
            ├─ MLXRecommendationPlanner      Apple Silicon + canImport(MLXLLM) 才编译
            └─ FallbackRecommendationPlanner 主 planner 空结果 → 规则（永不抛给 UI）
  └─ RecommendationEngine.recommend(profile:count:intents:)   召回 / 去重 / 打分 / 黑名单不变
```

- 模型只生成**检索计划**（query 列表），不直接产出歌曲。
- 规则与模型共用同一份 `RecommendationIntent`（kind = artist / decade / genre）。
- 选择逻辑在 `RecommendationPlannerFactory`：关闭开关、模型不完整、Intel Mac → 规则。

## 2. 模型与镜像

- 默认目标：`mlx-community/Qwen2.5-3B-Instruct-4bit`。
- 镜像实测（2026-11-03）：
  - 原定 `Qwen2.5-4B-Instruct-4bit`：`resolve/main/config.json` → **404**（hf-mirror 无此 repo）。
  - `Qwen2.5-3B-Instruct-4bit` → **307 → 200**（存在），选为最近可用的 4bit MLX 指令模型并更新默认值。
- 模型文件**不进 bundle、不进仓库**，落盘（2026-11-04 起并入共享资源根）：
  `<DSQ 共享根>/Models/Recommendation/<sanitize(modelId)>/v1/`
  - 共享根优先级：`DSQ_SHARED_ROOT` → App Group 容器
    `B6FA37AYT5.dsqcommon/DSQ Common Resources` → 非沙盒且该目录已存在 → Application Support 兜底；
    唯一实现在 `QQPlayer/Services/DSQSharedPaths.swift`。
  - 旧路径 `~/Library/Application Support/QQPlayer/RecommendationModels/<modelId>/`
    在迁移完成前仍可读（`RecommendationModelLayout.resolved` 自动回落）。
  - 迁移（默认 dry-run，必须显式 apply）：
    `bash scripts/dsq-shared-migrate.sh --dry-run` / `--apply`。

## 3. 下载与校验

- 清单来源：**硬编码文件清单 + 逐个 `HEAD https://hf-mirror.com/<repo>/resolve/main/<file>` 取 `Content-Length`**，
  不再依赖 `/api/models` 仓库 API（该接口在镜像上经常不可用 / 限流，失败时无法区分「模型不存在」与「接口挂了」）。
- 实测文件：`config.json`、`tokenizer.json`、`tokenizer_config.json`、`special_tokens_map.json`、`generation_config.json`；
  权重先探 `model.safetensors`，404 则读 `model.safetensors.index.json` 的 `weight_map` 取出分片名再逐个 HEAD。
- 必需文件：`config.json` + `tokenizer.json|tokenizer.model` + 至少一个 `*.safetensors`；缺任何一个直接抛
  `manifestUnavailable(modelId, missing)`，UI 上表现为明确的失败文案（不再笼统「无法获取清单」）。
- 下载：逐文件、`Range` 续传（206）、服务端不支持续传（200）时重下、失败重试 1 次、可取消。
- 校验：`RecommendationModelStore.isComplete` = 每个文件存在、大小 == 清单大小、> 0。
- 状态机：`notDownloaded → downloading(progress) → ready → loading`，失败 `failed(message)`；删除整目录回 `notDownloaded`。
- 清单持久化在模型目录 `manifest.json`（重启后无需重新请求）。

## 4. Prompt

- system：只输出 JSON、schema `{"queries":[{"query","kind"}]}`、6–12 条、query ≤ 40 字符、禁路径/DB/个人信息。
- user：固定字段顺序渲染摘要；空字段用 `(none)` / `(unknown)` / `0%`，不编造。
- 采样：temperature 0.3、maxTokens 512、30s 超时。

## 5. 解析与回退

1. 取第一个 `{` 到最后一个 `}`（容忍代码围栏 / 前后废话；无对象再试数组）。
2. `JSONDecoder` 解 `{queries:[...]}` 或 `[...]`。
3. 清洗：trim / 压空白 / 单行化、空串丢弃、> 40 字符丢弃、未知 kind 丢弃、大小写不敏感去重、最多 12 条。
4. 清洗后为空 → `nil` → `FallbackRecommendationPlanner` 回退规则并记 `AppLog.warn`。
5. 加载失败 / 超时 / 生成异常同样走回退，UI 只看到「规则结果」，不出现模型错误弹窗。

## 6. 内存与常驻

- 默认**用完卸载**：每次 `makePlan` 结束后 `MLXRunner.unload()`（容器置 nil，释放权重）。
- 设置项 `recommendationKeepModelLoaded`（默认关）：开启后 App 生命周期内保留。
- 设置项 `recommendationUseLocalModel`（默认开）：关闭后连加载都不发生。

## 7. 设置 UI（macOS）

设置 → 推荐：

- 模型卡片：repo 名 / 体积（清单已知时）/ 状态 / 下载 / 进度 / 取消 / 删除。
- 开关：使用本地模型生成推荐、模型常驻内存。
- Intel / 依赖不可用：卡片提示「仅 Apple Silicon」，推荐自动走规则。
- 文案键 17 个，五语种（en / zh-Hans / zh-Hant / fr / ru）齐全。

## 8. P1 vs P2 人工质量评估清单（用户执行）

对同一份画像各生成一批（建议 20 条）：

- [ ] 命中率：前 10 条里「愿意点开试听」的比例
- [ ] 多样性：艺人 / 年代 / genre 分布是否比规则更宽
- [ ] 相关性：是否明显跑题（同歌手复读、无关 genre）
- [ ] 新鲜度：是否出现已收藏 / 已听腻的曲目
- [ ] 稳定性：连续两次生成的差异是否合理（不是随机跳变）
- [ ] 延迟：生成耗时是否可接受（规则 vs 模型）
- [ ] 回退可见性：模型失败时是否无感回退（UI 正常出结果）

## 9. MLX 依赖接入（2026-11-03）

- 依赖：`https://github.com/ml-explore/mlx-swift-examples.git`，**exact `2.29.1`**，产品 `MLXLLM` + `MLXLMCommon`，**只挂 QQPlayerMac**。
  iOS target 不链接、也不编译 MLX 文件；`#if canImport(MLXLLM) && arch(arm64) && os(macOS)` 保证 Intel Mac / iOS 自动走规则 planner。
- `project.pbxproj` 里写的是 GitHub 远端 URL；`Package.resolved` 只记录远端 tag，**不含任何本地路径或本地镜像 SHA**。
- 首次编译需要 **Metal Toolchain**（Xcode 26 起独立分发）：`xcodebuild -downloadComponent MetalToolchain`。

### 9.1 本机构建（网络受限时）

构建机到 GitHub 很慢（10–20 KB/s），用本地 SPM 镜像 + 环境变量重写 URL，不改全局 git config：

```bash
GIT_CONFIG_COUNT=9 \
GIT_CONFIG_KEY_0=url.file:///tmp/spm-mirrors/repos/mlx-swift-examples.insteadOf GIT_CONFIG_VALUE_0=https://github.com/ml-explore/mlx-swift-examples \
GIT_CONFIG_KEY_1=url.file:///tmp/spm-mirrors/repos/mlx-swift.insteadOf          GIT_CONFIG_VALUE_1=https://github.com/ml-explore/mlx-swift \
GIT_CONFIG_KEY_2=url.file:///tmp/spm-mirrors/repos/swift-transformers.insteadOf GIT_CONFIG_VALUE_2=https://github.com/huggingface/swift-transformers \
GIT_CONFIG_KEY_3=url.file:///tmp/spm-mirrors/repos/swift-numerics.insteadOf    GIT_CONFIG_VALUE_3=https://github.com/apple/swift-numerics \
GIT_CONFIG_KEY_4=url.file:///tmp/spm-mirrors/repos/swift-jinja.insteadOf       GIT_CONFIG_VALUE_4=https://github.com/huggingface/swift-jinja \
GIT_CONFIG_KEY_5=url.file:///tmp/spm-mirrors/repos/GzipSwift.insteadOf         GIT_CONFIG_VALUE_5=https://github.com/1024jp/GzipSwift \
GIT_CONFIG_KEY_6=url.file:///tmp/spm-mirrors/repos/swift-docc-plugin.insteadOf GIT_CONFIG_VALUE_6=https://github.com/swiftlang/swift-docc-plugin \
GIT_CONFIG_KEY_7=url.file:///tmp/spm-mirrors/repos/swift-collections.insteadOf GIT_CONFIG_VALUE_7=https://github.com/apple/swift-collections \
GIT_CONFIG_KEY_8=url.file:///tmp/spm-mirrors/repos/swift-docc-symbolkit.insteadOf GIT_CONFIG_VALUE_8=https://github.com/swiftlang/swift-docc-symbolkit \
scripts/xcbuild.sh build -scheme QQPlayerMac -destination 'platform=macOS'
```

⚠️ 镜像坑（本机专用，不影响仓库）：镜像是源码快照，**没有 mlx / mlx-c 子模块**。需把
mlx `ee18e1c`、mlx-c `d5b8715` 的源码放进 `build/SourcePackagesShared/checkouts/mlx-swift/Source/Cmlx/{mlx,mlx-c}`；
用官方远端 clone 时 SPM 会自动 checkout 子模块，没有这一步。

### 9.2 验证（2026-11-03）

- Mac Debug：`BUILD SUCCEEDED`，项目代码 0 警告；`QQPlayer.debug.dylib` 含 102 个 `MLXRecommendationPlanner` 符号（canImport 生效）。
- Mac Release：`BUILD SUCCEEDED`；仅剩 3 条 MLX 上游 Metal 头文件的 `-Wc++17-extensions` 警告（第三方源码，仓库内改不了）+ 1 条 appintents 工具提示。
- iOS（generic/platform=iOS Simulator）：构建通过，日志里没有 MLX / Cmlx 目标，确认不链接。
- 模型下载改为硬编码清单 + HEAD，见 §3；不再请求 `/api/models`。
