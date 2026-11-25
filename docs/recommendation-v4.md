# 推荐 v4（第一阶段：生成质量 + 已下载标记）

> 状态：2026-11-25 第一批（A 生成质量 / B 已下载标记）+ 第二批（C 移除输入框与「按艺人推荐」）。
> 代码入口：`QQPlayer/Services/RecommendationV3Engine.swift`（v3 引擎沿用，选择/抽样/画像换成 v4 算法）。

## 1. 为什么改

v3 的实际表现是「外部热歌榜 + 关键词检索」的规则拼装：

- 种子艺人取 `seeds.prefix(8)`，**完全确定**——同一份画像永远同一批歌；
- 单艺人热歌只取 10 首、池级上限「艺人 ≤2 / 专辑 ≤1」，池子薄到没得挑；
- 画像亲和度用「全期播放次数 + 文件修改时间」，跟最近爱听什么几乎无关；
- 通道配额 40/40/20 硬占位，explore 通道 20% 位置无条件占据，相关性再高也挤不进；
- 已下载条目在排序阶段被直接剔除，用户刚下载完、下一次后台重算就从列表消失。

v4 第一批就是把这五点逐条改掉，不引入模型、不做协同过滤（单用户本地曲库）。

## 2. 用户可感知的行为变化

| 场景 | v3 | v4 |
|---|---|---|
| 点「刷新 / 换一批」 | 同一批歌（除非曲库变了） | 每次重新抽种子，批次不同 |
| 同一批内 | —— | 稳定（批次存活期内不重抽、不重排） |
| 单艺人候选深度 | 10 首 | 50 首（网易云 `artist/top/song`，provider 上限 50） |
| 曲风覆盖 | 40/40/20 硬配额 | 每通道下限（2/2/1），其余按分数竞争 |
| 同艺人扎堆 | 靠硬上限压，可能出现「换汤不换药」 | MMR 主动降权，有替代就不连选 |
| 下载了推荐里的歌 | 后台重算后条目消失 | 条目保留并显示「已下载」（单批 ≤3 首） |
| 曲库匹配 | 「A & B」「(Live)」「繁体」「电影主题曲括号」大量漏配 | 多键匹配（任一命中即算），漏配大幅减少 |

## 2b. 批次 C：输入框与「按艺人推荐」已移除

| 项 | 现状 |
|---|---|
| 推荐页自然语言输入框 | **已移除**（无输入框、无指令 chip、无「按你的要求」分组标题） |
| 「按指定艺人推荐」 | **已移除**（点名艺人硬约束、本人/相似配额、结果不足提示一并删除） |
| 设置项「对话上下文轮数」 | **已移除** |
| 设置项「相似艺人比例」 | **已移除**（只服务于点名艺人配额） |
| 磁盘上的请求历史 JSON | **保留文件、停止读写**（不迁移、不删除） |

以后想按艺人找歌 → 走下载区的在线搜索（手动搜艺人 / 歌名），不再经过推荐页。

实现层同时清理了只服务于该功能的死负载：请求解析（JSON parser / 规则 planner / 历史 store）、
Engine 的点名约束接线、Plan/Reason 的 prompt 与 parser、`makeChatPlanner`。
缓存键里的 `rawText` 字段保留但恒为空串（改键格式需递增缓存 schemaVersion，等于让所有用户缓存失效一次）；
`RecommendationPlanSource.localModel` 只留作旧缓存 JSON 解码兼容。

## 3. 算法参数（实现即口径）

### 3.1 种子抽样（`RecommendationSeedSampler`）

- 候选窗口：亲和度前 **20** 名；
- 权重：`max(affinity, 0.01)`，**加权无放回**；
- K = `RecommendationV3Engine.maxSeedArtists`（默认 8）；
- 随机源：`RecommendationSeededRandom`（SplitMix64），每轮刷新由 `seedProvider` 生成新种子；
  测试注入固定 seed → 同 seed 同结果；
- 亲和度并列 → 按 artist key 升序，保证稳定；
- 抽出的种子写回**本轮画像副本**，召回/排序全程复用（批次内不重抽）。

### 3.2 扩池

- `topSongsLimit = 50`（艺人热歌深度；`perSourceLimit = 10` 只留给风格关键词/艺名搜索）；
- 池级上限：同艺人 ≤4、同专辑 ≤2（`RecommendationRankerV3`）；
- 批次级上限：同艺人 ≤2、同专辑 ≤1（只在选择阶段执行）；
- 种子通道并发：TaskGroup，每批 ≤4 个种子（每个种子 2 次 HTTP），结果按种子原序回填。

### 3.3 画像行为信号（`RecommendationProfileV3Builder`）

输入：`RecommendationProfileV3Input.plays`（DB `play_history` 的 stableId / playedAt / playDurationMs）。

```
w_session  = exp(-ln2 × daysSince / 30)          // 30 天半衰
completion = min(1, playDuration / duration)     // 时长缺失按 0.6 中性
factor     = 1.0    (completion ≥ 0.9)
           = 0.1    (completion < 0.3)           // 跳过
           = 0.1 + (completion - 0.3) / 0.6 × 0.9   // 其余线性
behavior   = Σ(w_session × factor)，按全体艺人最大值归一
affinity   = 0.7 × behavior + 0.2 × 曲库规模 + 0.1 × 收藏
```

- **移除** `addedAt`（文件修改时间）作为 recency——那是入库动作，不是听歌口味；
- 无播放历史 → 退化为「曲库规模 + 全期播放次数 + 收藏」按原权重比例（去掉 recency 后归一），不崩、不编造；
- 保留 v2 的 30 天半衰 / 完成率参考实现作对照，不复活整条 v2。

### 3.4 通道下限（`RecommendationSelectionV4`）

- 目标 ≥5：seed ≥2、similar ≥2、explore ≥1；
- 目标 <5：`floor(下限 × total / 5)` 按比例缩小；
- 配额由用户配置改为**固定下限**：设置页那组「通道配额比例」滑块（原 40/40/20）已移除，
  文案键同步删除；`RecommendationV3Settings` 里的 `quotaSeed/quotaSimilar/quotaExplore`
  只留作旧 JSON 解码兼容（引擎不再读取，无生产消费方）；
- 下限阶段**不吃 MMR**（多样性不得破坏下限）；
- 剩余位置按全局 MMR 竞争；某通道候选不足 → 名额自动让给其他通道，总数不少发；
- 全程按归一化键去重。

### 3.5 多样性（MMR）

```
value = 0.7 × relevance − 0.3 × maxSimilarity
relevance      = score / 本批最高分
maxSimilarity  = max(同艺人 1.0, 同专辑 0.6, 同簇 genre 0.3, 年份差 ≤2 年 0.1)
```

- 同输入同输出（分数降序 + key 升序 tie-break）；
- 批内上限（艺人 ≤2 / 专辑 ≤1）与 MMR 同时生效。

### 3.6 已下载标记

- 排序阶段不再「在曲库就剔掉」：把曲库命中按 `keepKeys`（本批可见的已下载项）放行；
- 后台重算（缓存过期 / 画像刷新）时：
  - 引擎侧 `keepKeys` 放行；
  - 列表侧 `RecommendationDownloadedRetention.merge` 把上一批里「已下载且新批没有」的条目按原位置合回；
- 单批保留上限 **3** 首，超出按原批顺序丢弃；
- **换一批 / 新生成批次仍排除已下载**（已拥有的不重复推）；
- 判定入口：`RecommendationDownloadedIndex`（协议 `RecommendationDownloadedIndexProviding`，可注入桩）；
- 下载落库 → `.trackFound` 300ms 去抖重读曲库键（既有链路，本批只补注入面与测试，未重复订阅）。

### 3.7 归一化键（`RecommendationLibraryMatcher`）

| 规则 | 说明 |
|---|---|
| 多艺人拆分 | `&` / `、` / `,` / `，` / `/` / `feat.` / `ft.` / `featuring` / `with` 拆成集合，**任一命中即算**；同时保留主艺人键 |
| 副标题剥离 | 中文/全角括号里的「电影《…》主题曲」、`【…】`、以及白名单版本词；剥离后**原键仍做二次尝试** |
| dash 版本后缀 | `- 现场版 / - Live / - 演唱会 / - Remastered / - 伴奏 / - DJ版 / - 片段`（含 `- 2011 Remaster`） |
| 繁简折叠 | 匹配前统一（`RecommendationNormalization.toSimplified` = CharacterMapResourceLoader 的 OpenCC 表，与入库 canonicalize 同一张；**禁止 StringTransform**），**只改键、不改展示** |
| 库内无 artistId | 不再退化成 `标题#`：先按「标题 + 首艺人」，再退到纯标题（仅一侧缺艺人时启用） |
| 文件名兜底 | `周杰伦-晴天` 仅在**艺人缺失**时拆成艺人 + 标题，且两侧都要有实质内容（交叉验证） |
| `&` 的两副面孔 | 唯一键 `key()` **不拆 `&`**（`Simon & Garfunkel` 是组合名，保护既有契约）；匹配集合 `keys()` 才拆 |
| 两套键的关系 | `RecommendationKey` 继续服务黑名单/缓存身份（单键、宽松）；`RecommendationLibraryMatcher` 是曲库匹配/已下载的唯一入口（多键）。两者**不再互相冒充** |

## 4. 验收标准

本批交付的机器可验证标准（`scripts/run-reco-v4-tests.sh` + `QQPlayerTests/RecommendationV4Tests.swift`）：

1. SeedSampler：同 seed 同结果、无重复、只取前 20 名、K 边界（0 / 超窗口）；
2. ProfileV3：半衰数值、完成率分档、跳过降权、归一化、空数据退化；
3. 选择：下限满足、候选不足重分配、总数正确、去重、批内上限、保留已下载 ≤3；
4. MMR：有替代不连选同艺人、相似度取最大、λ 效果、确定性；
5. 匹配器：`&` 集合匹配、中文括号、现场版、繁简、无 artistId、文件名兜底（逐条断言）；
6. 已下载：下载完成 → 判定为已下载且仍在列表；新批次排除已下载、保留项放行。

人工验收（真机）：连续两次刷新应给出不同批次；下载推荐里的歌后触发后台重算，条目仍在并显示「已下载」；下载超过 3 首时超出部分消失。

## 5. 回滚点

- **整批回滚**：`git revert` 本批提交（抽样 / 画像 / 选择+MMR / 标记与归一化 / 测试 / 文档），互不依赖语义；
- **只回滚选择算法**：`RecommendationV3Engine.select` 改回 `quotas.allocation(total:)` + 通道占位（`allocation` 函数保留未删）；
- **只回滚种子抽样**：`RecommendationV3Engine.recommend` 去掉 `RecommendationSeedSampler` 调用，直接用 `profile.seeds`（原 `prefix` 行为）；
- **只回滚已下载保留**：`retainedDownloadedKeys()` 传空集、`RecommendationDownloadedRetention.merge` 换成 `fresh`；
- 数据面无破坏性变更：无新表、无迁移；`play_history` 只读。

## 6. 已知限制 / 后续

- MMR 的「同簇 genre」依赖候选自带 genre：远程源多数不带，只有 iTunes 标准化命中的候选才吃得到 0.3 这一档；
- 艺人热歌 50 首受网易云接口上限约束（provider 内部 `min(50, limit)`）；
- 并发召回只做了种子通道；相似通道仍是 ≤3 个种子串行（首屏占比小，暂不动）；
- 批次 C 已交付（输入框 / 按艺人推荐移除，见 §2b）；输入框时代的历史 JSON 留在磁盘上不再读写。
