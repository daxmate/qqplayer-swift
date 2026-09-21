//
//  IOSPassiveSyncCenter.swift
//  QQPlayer
//
//  M6 · T4/T5（2026-09-11）iOS App 级被动同步中心。
//
//  背景：同步发起方**恒为 Mac**（R1b-2 起），iOS 只应答 Mac 的 manifest/fetch 请求
//  并接收 Mac 推送的文件落库；但 `SyncLibraryPassiveHost` 此前**全仓零实例化**，
//  且 iOS 配对后只有在扫码那一次回连 → Mac 的推送根本送不到手机。本文件把这条
//  链路接成 App 级能力：
//    ① 前台 `start()`：浏览 mDNS → 按「已配对主机」尝试连接（身份由握手 pinning
//       校验；Bonjour 广播名只用于排序/展示，**绝不作为身份凭据**）→ 会话 ready
//       后装配 `SyncLibraryPassiveHost`（曲库根 = 本地沙盒 Documents，与
//       LibraryIndexer 扫描同一事实源）并 `attach`。
//    ② 退后台 `stop()`：拆接线 + 关会话 + 停浏览（被动端只在前台工作）。
//    ③ 断线重连：**仅前台**，指数退避 + 上限（`IOSPassiveReconnectPolicy`）；上限
//       用尽后交设置页「重连」按钮手动兜底（`reconnectNow()`）。
//    ④ 进度：`SyncLibraryPassiveHost.onFileLanded` / `onBatchCompleted` → `summary`
//       （**不加新协议帧**；v1 文件级进度）。
//    ⑤ **数据同步端**（S2-T12，2026-09-13）：会话 ready 时同时挂 `SyncChangeLogPeer`
//       ——它是帧 8/9（`change_log_pull` / `change_log_push`）的**唯一**处理器，此前
//       只在 Mac 侧装配（`MacSyncCoordinatorFactory`）→ iPhone 收到 Mac 推来的帧 9 被
//       静默丢弃、Mac 发来的帧 8 无人应答 → 收藏/播放记录/歌单等播放数据永不落机。
//       本中心把这条链路补上（`dataSyncPeerID` = 对端 hello 的 Device ID = 游标键）。
//
//  ⚠️ 会话回调单槽 + 挂接顺序（帧 8/9 与帧 15 都能到达的原因）：
//  `SyncPeerSession.onApplicationFrame` 是**单槽闭包**、后挂者为链头，链头**必须**把帧转发
//  给 prior，否则更早挂的处理器再也收不到帧。本中心 ready 时的挂接顺序为：
//    ① `SyncLibraryPassiveHost.attach`（内部再挂 SyncFileReceiver / SyncPeerLibraryResponder，
//       最后挂它自己 → 链序 … → responder → passiveHost）
//    ② `SyncChangeLogPeer.init`（后挂 = 链头，自身只挑 changeLogPull/Push，其余原样转发 prior）
//  于是链为「SyncChangeLogPeer → SyncLibraryPassiveHost → SyncPeerLibraryResponder → …」：
//  帧 8/9 在链头被数据端处理，`library_push_announce`（帧 15）沿 prior 到达被动端
//  —— 两种帧都能到达，互不遮挡。`onClosed` 同理（数据端处理为空 + 转发被动端收尾）。
//
//  复用而非重写（行为单一事实源）：
//    - 浏览/连接：`SyncBrowser`
//    - 名称匹配口径：`SyncConnectLogic.matches` / `SyncConnectLogic.pickHost`（扫码回连同源）
//    - 关闭原因 → 失败模型：`SyncConnectLogic.failure(fromCloseReason:)`
//    - 设备列表过滤：`SyncDeviceList.hosts(in:)`
//    - 接收落库：`SyncLibraryPassiveHost`（内部复用 `SyncLocalLibraryProvider` /
//      `SyncFileReceiver` / `SyncLyricsReceiver` / `LibraryIndexerSyncSink`）
//
//  平台：iOS 专用（macOS 侧由 `MacSyncHostCenter` 负责），整文件 `#if os(iOS)`。
//

#if os(iOS)

    import Combine
    import Foundation
    import Network
    import Observation

    // MARK: - 纯逻辑：数据同步（帧 8/9）账目（可单测，2026-09-15）

    /// 本机**被动侧最近一次数据同步**的账目。
    ///
    /// 为什么需要：Mac 是发起方、有完整的账目面板；手机侧以前这些数字**只进 print**，
    /// 用户在手机上完全看不出“这次同步了什么 / 丢了多少”（矩阵四级空格）。
    /// ⚠️ 计数**不在这里维护**：唯一存储 = `tally`（`SyncOutcomeTally`，与 Mac 面板**同一类型**
    /// ——L6 起两端不再各建一套账目），下面是它的投影；面板/纯逻辑读的名字不变。
    struct IOSPassiveDataSyncSummary: Equatable, Sendable {
        /// **唯一**结果账目（见 `SyncRowOutcome` / `SyncOutcomeTally`）。
        var tally = SyncOutcomeTally()
        /// 本机应答对端拉取时发出的 outbox 增量行数（最近一批）
        var answeredPullEntries: Int { tally.outboundEntries }
        /// 对端推来并落到本地业务表的行数
        var appliedEntries: Int { tally.appliedEntries }
        /// 因本地缺歌而挂起的行数（歌到位后重放）
        var suspendedEntries: Int { tally.suspendedEntries }
        /// 因缺身份键（未定位）未落库的行数
        var unresolvedEntries: Int { tally.unresolvedEntries }
        /// 播放位置未落地（跨端续播关 / 落点未接受）
        var unsupportedEntries: Int { tally.unsupportedEntries }
        /// 父行 / 被引用行不存在而跳过（歌单结构未到 / 引用歌本地查无）
        var skippedMissingParentEntries: Int { tally.skippedMissingParentEntries }
        /// 忽略的 delete 行数（删除不跨端传播）
        var ignoredDeletes: Int { tally.ignoredDeletes }
        /// 应用失败的行数（载荷解不开 / 落库抛错；歌单级失败在这里可见）
        var applyFailedEntries: Int { tally.applyFailedEntries }
        /// 本机应答拉取 / 推送增量时缺身份键的行数
        var missingIdentityEntries: Int { tally.missingIdentityEntries }
        /// 是否已有账目（false = 还没同步过 → 面板显示空态）
        var hasSessionData = false
        /// 最近一次更新时间
        var updatedAt: Date?
    }

    /// 账目 → 展示模型（纯函数，可单测）。
    enum IOSPassiveDataSyncPresenter {
        /// 一行缺口（计数 > 0 才出现）
        struct GapRow: Equatable {
            var labelKey: String
            var count: Int
            /// 计数下面的说明 key（可空）
            var hintKey: String?
        }

        /// 一条结果的**展示归属**（唯一映射在共享投影 `SyncEntityOutcomeDisclosure`：
        /// Mac 面板与手机面板共用一份，避免两处各自维护「哪个类别算缺口」）。
        typealias Placement = SyncOutcomePlacement

        /// 结果类别 → 展示归属（`switch` **无 `default`** 在共享投影里：新增
        /// `SyncRowOutcome` 类别那里编译不过 —— 不会出现「新类别静默不上屏」）。
        static func placement(of outcome: SyncRowOutcome) -> Placement {
            SyncEntityOutcomeDisclosure.placement(of: outcome)
        }

        /// 缺口行展示顺序（严重度：未定位 → 应用失败 → 身份歧义 → 缺依赖 → 未支持 → 缺指纹）。
        /// ⚠️ 与 `countOrder` 合起来必须**恰好覆盖** `SyncRowOutcome.allCases`（有用例钉住）。
        static var gapOrder: [SyncRowOutcome] { SyncEntityOutcomeDisclosure.gapOrder }

        /// 正常计数行展示顺序（已应用 / 挂起 / 发送 / 忽略删除）。
        static var countOrder: [SyncRowOutcome] { SyncEntityOutcomeDisclosure.countOrder }

        /// 缺口行（计数 > 0 才出现；顺序 = 严重度）。
        /// 读数一律走 `summary.tally`（不在 UI 层补算任何数字，INV-19）。
        static func gapRows(_ summary: IOSPassiveDataSyncSummary) -> [GapRow] {
            var rows: [GapRow] = []
            for outcome in gapOrder {
                guard case let .gap(labelKey, hintKey) = placement(of: outcome) else { continue }
                let count = summary.tally.count(for: outcome)
                guard count > 0 else { continue }
                rows.append(GapRow(labelKey: labelKey, count: count, hintKey: hintKey))
            }
            return rows
        }

        /// 正常计数行（恒出现；顺序固定）。
        static func countRows(_ summary: IOSPassiveDataSyncSummary) -> [(labelKey: String, count: Int)] {
            var rows: [(labelKey: String, count: Int)] = []
            for outcome in countOrder {
                guard case let .count(labelKey) = placement(of: outcome) else { continue }
                rows.append((labelKey: labelKey, count: summary.tally.count(for: outcome)))
            }
            return rows
        }
    }

    // MARK: - 中心（App 级单例）

    /// iOS App 级被动同步中心（契约 C3）：一个实例至多一个活动会话，只应答 + 接收。
    @MainActor
    @Observable
    final class IOSPassiveSyncCenter {
        static let shared = IOSPassiveSyncCenter()

        /// 连接状态
        var state: IOSPassiveSyncState = .idle
        /// 接收账目（`onFileLanded` / `onBatchCompleted` 驱动）
        private(set) var summary = SyncLibraryPassiveSummary()
        /// **数据同步**（帧 8/9）账目：手机侧的“同步了什么 / 丢了多少”（矩阵四级空格，2026-09-15）
        var dataSummary = IOSPassiveDataSyncSummary()
        /// 已配对主机数（设置页据此区分「未配对」与「未连接」）
        var pairedHostCount = 0

        let identityStore: SyncIdentityStore
        let deviceStore: DeviceStore
        let libraryRoot: () -> URL
        let clientName: () -> String?
        /// 同步库（生产 = `.shared`；测试注入内存库，避免碰真实 DB）
        let database: DatabaseManager
        /// 曲库索引状态源（= changeLog 同步前置门的事实来源，`IndexingGate` 唯一判定；
        /// 生产 = `LibraryIndexer.shared`，测试注入假源）。
        let indexingState: IndexingStateProviding

        /// 默认本机名来源（握手 hello / 配对请求携带的展示名）：
        /// 用户命名（`LocalDeviceNameStore`）优先，未命名回落系统设备名。
        /// 抽成静态函数是为了让 iOS 测试 target 能注入独立 store 锁定这条接线（不必建会话 / DB）；生产默认值即本函数。
        nonisolated static func defaultClientName(store: LocalDeviceNameStore = .shared) -> String? {
            store.name
        }

        var browser: SyncBrowser?
        var session: SyncPeerSession?
        var passiveHost: SyncLibraryPassiveHost?
        /// 数据同步端（帧 8/9 处理器）= `SyncChangeLogPeer`；nil = 未装配
        var dataSyncPeer: SyncChangeLogPeer?
        /// 数据同步端的对端游标键（`sync_cursor.peer_id`）；nil = 未装配
        var dataSyncPeerID: String?
        /// 待装配数据同步端的会话（前置门挡住时留着，索引终态后补装；拆除时清）
        var dataSyncSession: SyncPeerSession?
        /// 索引终态事实的订阅（start 挂、stop 摘）
        var indexingTerminalStateCancellable: AnyCancellable?

        /// 数据同步端是否已装配（可达性诊断 / 测试断言 / **运行时装配自检事实**）。
        var isDataSyncAttached: Bool {
            dataSyncPeer != nil
        }

        /// 播放位置落点是否已注入（装配自检事实；**门控关 = nil = 不适用**，不计缺口，见 INV-26）。
        var playbackPositionSinkAttached: Bool?
        var pairedHosts: [PeerDevice] = []
        var currentTarget: IOSPassiveSyncTarget?
        /// 本轮已尝试过的目标（`peerID|hostName`），避免浏览回调反复重连同一目标
        var attemptedTargets: Set<String> = []
        var isRunning = false
        var isTearingDown = false
        var isWaitingBackoff = false
        var automaticAttempts = 0
        /// 每次尝试的令牌：旧会话/旧被动端回调据其失效
        var attemptToken = UUID()
        var discoveryWork: DispatchWorkItem?
        var reconnectWork: DispatchWorkItem?

        init(
            identityStore: SyncIdentityStore = SyncIdentityStore(),
            deviceStore: DeviceStore = DeviceStore(),
            libraryRoot: @escaping () -> URL = { MusicFolderResolver.iosDocumentsDirectoryURL() },
            clientName: @escaping () -> String? = { IOSPassiveSyncCenter.defaultClientName() },
            database: DatabaseManager = .shared,
            indexingState: IndexingStateProviding = LibraryIndexer.shared
        ) {
            self.identityStore = identityStore
            self.deviceStore = deviceStore
            self.libraryRoot = libraryRoot
            self.clientName = clientName
            self.database = database
            self.indexingState = indexingState
            reloadPairedHosts()
        }

        // MARK: 生命周期

        /// App 进入前台 / 设置页出现：开始（幂等）。
        /// 已在跑但此前因「无已配对主机」闲置时，本调用会重新检查主机并立即开始。
        func start() {
            observeIndexingTerminalState()
            if isRunning {
                reloadPairedHosts()
                guard !state.isConnected, !state.isConnecting, !isWaitingBackoff, !pairedHosts.isEmpty else { return }
                beginAttempt()
                return
            }
            isRunning = true
            automaticAttempts = 0
            beginAttempt()
        }
        /// App 退到后台：拆接线 + 关会话 + 停浏览（幂等）。
        func stop() {
            isRunning = false
            indexingTerminalStateCancellable?.cancel()
            indexingTerminalStateCancellable = nil
            dataSyncSession = nil
            automaticAttempts = 0
            isWaitingBackoff = false
            cancelDiscovery()
            cancelReconnect()
            browser?.stopBrowsing()
            browser = nil
            tearDownSession()
            attemptedTargets.removeAll()
            currentTarget = nil
            state = .idle
        }

        /// 手动重连（自动重连上限用尽 / 刚配对完 / 用户主动）：重置退避计数立即重来。
        func reconnectNow() {
            isRunning = true
            automaticAttempts = 0
            attemptedTargets.removeAll()
            beginAttempt()
        }

        /// 会话 ready → 装配被动端（曲库根与既有扫描同源）**+ 数据同步端**（帧 8/9）。
        ///
        /// internal（非 private）仅供 iOS 测试 target 驱动装配路径（`@testable`）；
        /// 生产只由 `handlePhase` 调用。
        func attachPassiveHost(to session: SyncPeerSession) {
            let token = attemptToken
            let host = SyncLibraryPassiveHost(libraryRoot: libraryRoot(), database: database)
            host.onFileLanded = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.attemptToken == token, let host = self.passiveHost else { return }
                    self.summary = host.summary
                }
            }
            host.onBatchCompleted = { [weak self] summary in
                Task { @MainActor in
                    guard let self, self.attemptToken == token else { return }
                    self.summary = summary
                }
            }
            passiveHost = host
            guard host.attach(to: session) else {
                // 曲库根不存在 / 接线失败：拆掉并让会话关闭走统一失败路径
                passiveHost = nil
                recordWiringFacts()
                session.cancel(reason: .storageError("passive host attach failed"))
                return
            }
            summary = host.summary
            // 记下待装配数据同步端的会话：前置门若未开，索引终态后由
            // `refreshDataSyncAttachment()` 用这个会话补装。
            dataSyncSession = session
            // 被动端接好后挂数据同步端：帧 8/9 与帧 15 的链序见文件头注释。
            attachDataSync(to: session)
            // 装配完成 → 申报事实（会话 ready 的自检时点；缺口在面板上可见，见 SyncWiringSelfCheck）。
            recordWiringFacts()
        }

        /// 装配结果 → 运行时自检事实（INV-16 后半句：**本端声明的能力这一刻真的装上没有**）。
        ///
        /// 只申报事实，不做判定（判定 = `SyncWiringSelfCheck.gaps(items:)` 纯函数，
        /// 展示 = `SyncWiringSelfCheckPresenter`）；探针清单来自注册表，不在这里写死。
        private func recordWiringFacts() {
            let store = SyncWiringFactsStore.shared
            store.record(.libraryPassiveHost, attached: passiveHost != nil)
            // 前置门未开（索引未到终态）= 本端**有意**未装配，不是接线缺口 → 记「不适用」（nil），
            // 与「门控关 = 不适用」同口径；门开着却没装配才是缺口（false）。
            let gated = !IndexingGate.isReadyForChangeLogSync(indexingState)
            store.record(.changeLogPeer, attached: isDataSyncAttached ? true : (gated ? nil : false))
            store.record(.playbackPositionSink, attached: playbackPositionSinkAttached)
        }

    }

#endif
