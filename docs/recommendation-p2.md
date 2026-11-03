# 本地 AI 推荐 P2：Mac 内嵌 MLX 模型

> 状态：代码层已落地；**MLX SPM 依赖未接入**（2026-11-03 构建机无法从 GitHub 拉取，见文末「依赖阻塞」）。
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
- 模型文件**不进 bundle、不进仓库**，落盘：
  `~/Library/Application Support/QQPlayer/RecommendationModels/<sanitize(modelId)>/`

## 3. 下载与校验

- 清单来源：`https://hf-mirror.com/api/models/<repo>`，解析 `siblings[].rfilename/size`。
- 必需文件：`config.json` + `tokenizer.json|tokenizer.model` + 至少一个 `*.safetensors`；
  另收 `tokenizer_config.json`、`special_tokens_map.json`、`generation_config.json`、`chat_template.jinja`、`*.safetensors.index.json`。
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

## 9. 依赖阻塞（2026-11-03 实测）

- 目标：`https://github.com/ml-explore/mlx-swift-examples` tag `2.29.1`（产品 MLXLLM / MLXLMCommon）。
- 实测结果：
  - `git ls-remote` 可取到 tag（元数据通）。
  - `git clone --depth 1` 直连 / 走本机代理：约 **10–12 KB/s**，60s 仅 ~500 KB。
  - `https://ghproxy.net/...`：约 2.5 KB/s；`kkgithub.com` 不可达；`gitclone.com` 返回 500。
  - 本机 SPM 缓存与全局缓存**均无** mlx 副本（`mdfind` 仅命中半成品 mirror）。
- 结论：在当前网络下无法完成 SPM 解析（mlx-swift-examples + mlx-swift + swift-transformers 数百 MB），
  因此 `project.pbxproj` **未**写入不完整的包引用（避免 Mac target 无法解析而整体不可构建）。
- 代码已按 `#if canImport(MLXLLM) && arch(arm64) && os(macOS)` 隔离：
  依赖可用时编译 MLX planner；不可用时工厂直接返回规则 planner。
- 恢复步骤（网络可用后）：
  1. 加包：`https://github.com/ml-explore/mlx-swift-examples.git`，exact `2.29.1`，产品 `MLXLLM` / `MLXLMCommon`，仅 QQPlayerMac。
  2. Mac target 链接两产品；确认 `canImport(MLXLLM)` 为真。
  3. 选择 hf-mirror 存在的 4bit 模型并更新 `RecommendationModelManager.defaultModelId`。
  4. 跑 `scripts/xcbuild.sh build -scheme QQPlayerMac` + 真实下载冒烟 + 人工质量评估。
