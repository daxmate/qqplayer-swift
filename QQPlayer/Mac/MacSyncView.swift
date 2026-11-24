//
//  MacSyncView.swift
//  QQPlayer
//
//  局域网同步（S2/M6；2026-11-16 P1a「设备入口外移」）macOS **同步中心主体**
//  （QQPlayerMac target only）：同步中心内容区主体（自带 `Form` 壳 + 置顶标题行）。
//
//  P1a 信息架构（用户 2026-11-16 拍板，**推翻** 2026-09-26 的「设备 / 同步」顶层两页）：
//   · 内容区**恒为「同步」页**（传歌 / 播放数据两流），不再有顶层页分段控件；
//   · 设备面（待批准请求 · 身份与二维码 · 连接状态 · 已配对设备 · 本次同步目标）从顶层页
//     外移成右上角「设备…」按钮 + Popover，内容仍复用唯一一份 `devicePane`
//     （有未批准配对请求时按钮挂红点）；
//   · 未选内容时内容区顶部给「空态引导卡」（同步全曲库 / 挑几首歌），不再走进死胡同。
//
//  拆法（批 B1 硬约束 R1「拆 View 不拆模型」）：一个状态模型 + 三份呈现 ——
//  `SyncHostCenter` 与各 ViewModel（`MacSyncRunViewModel` / `MacSyncContentModel` /
//  `MacSyncDataViewModel`）**一行不动**，只拆视图。三块 Pane 各自独立成文件：
//   · `SyncDevicePane.swift` → 「设备」页
//   · `SyncTracksPane.swift` → 「同步」页（分段控件 + 传歌流）
//   · `SyncDataPane.swift`  → 播放数据流（= 原 F 数据同步区）
//  原分区文件（`+Connection` / `+Content` / `+Run`）继续承载各分区本体（A 并入设备页）。
//
//  ⚠️ 批 D（2026-09-26）三块 Pane 已从「本类型的 extension」改为**独立 struct**
//  （`SyncDevicePane` / `SyncTracksPane` + `SyncPage` / `SyncDataPane`），本文件只做装配。
//  做法 = **父 = 唯一观察者**：三个 ViewModel 仍是 `ObservableObject`（`@Observable` 迁移尚未
//  覆盖），子视图不得写 `@ObservedObject` / `@StateObject`（`ObservationMigrationContractTests`
//  是按 (文件, 标记) 的棘轮：新增即红）⇒ 子 struct 只收**值输入 + 回调 / 绑定**，父 body
//  重算 ⇒ 子拿到新值即重绘。分区本体**仍留在分区文件**（`+Connection` / `+Content` / `+Run`），
//  由父读值构建后作为内容输入交给 `SyncTracksPane` 组合（不复制任何分区实现）。
//
//  ⚠️ 状态归属：两页的**全部 `@State` / `@StateObject` 都留在本文件**（唯一观察者），
//  页切换只切渲染内容、不卸载本类型 ⇒ ViewModel 生命周期与拆分前逐字一致
//  （页切换不会丢在途传输结果、不打断对端清单加载）。
//
//  纪律：本文件**只做展示**——能不能开始 / 现在什么阶段 / 进度多少 / 结果怎么算，
//  全部来自 `MacSyncRunViewModel` + `MacSyncContentModel` + `MacSyncDataViewModel` +
//  `SyncDeviceListModel` + `SyncUIState` / `SyncUIDirectionContent`（纯逻辑，有单测）。
//  View 里不写判断。
//
//  ⚠️ 历史（2026-09-18 前）：曾要求「macOS 13 兼容：不使用 macOS 14+ API（`onChange` 单参数闭包、
//  不用 `ContentUnavailableView`）」。同日部署目标提到 14.0，此约束解除；
//  文件内的 `onChange` 已改为两参数签名。新增代码仍以「不引入 macOS 15+ API」为惯例。
//

import AppKit
import SwiftUI

/// 同步中心入口默认页（2026-09-26 批 B1 引入；**2026-11-16 P1a 起不再是页切换**）。
/// P1a 把设备面外移成「设备…」Popover ⇒ 内容区恒为「同步」页；本枚举只作为两个入口
/// `initialPage` 的**兼容入参**保留（调用点不必改），不再驱动任何页切换。
enum MacSyncPage: Hashable {
    /// 设备面（现为「设备…」Popover 的内容：待批准请求 / 身份与二维码 / 连接状态 / 已配对设备 / 局域网开关）。
    case device
    /// 同步页（分段切「传歌 / 播放数据」）。
    case sync
}

/// 「同步」页的两个流（分段控件切换；同一时刻只渲染一个，两流永不共用一屏）。
enum MacSyncFlow: Hashable {
    /// 传歌（文件传输：方向 / 内容 / 执行 / 结果）。
    case tracks
    /// 播放数据（收藏 / 播放历史 / 歌单结构）。
    case data
}

/// 同步中心主体（自带 `Form` 壳；顶层页分段控件置顶、不随内容滚动）。
struct MacSyncRunSection: View {
    /// 2026-09-20 批 6-8：中心迁 `@Observable` ⇒ 视图侧改**组合根环境注入**（读属性即按需重绘）。
    /// 两个入口（设置页 `MacSyncSettingsView` / 工具栏面板 `MacSyncCenterView`）共用本视图。
    @Environment(SyncHostCenter.self) private var envHostCenter
    /// App 强调色（读环境值，与主窗同源；macOS 上 `Color.accentColor` 跟随系统强调色而非
    /// App tint——2026-09-05 已统一，本文件 2026-09-11 新增时复发，见 M1）
    @Environment(\.appAccentColor) var accentColor
    /// 设置窗玻璃是否生效（设置窗作用域环境值，见 `MacSettingsWindowGlass`）。
    /// 只在设置窗注入；主窗 / 工具栏面板入口读到的恒为默认值 `false` ⇒ 外观不变。
    /// 注意：本属性在 `MacSyncView+Run.swift` 的扩展里也要读（底栏背景），故不能用 `private`。
    @Environment(\.macSettingsGlassActive) var settingsGlassActive
    /// 主窗玻璃是否生效（主窗根注入；主窗工具栏弹出的同步面板是 sheet，
    /// 由 `macSheetGlass()` 在 sheet 根注入为 true）。
    @Environment(\.macWindowGlassActive) var windowGlassActive
    /// 顶部 / 底部条带是否让路给玻璃：**设置窗场景 或 主窗 sheet 场景**任一生效都清底
    /// （分隔线保留）。两个入口共用本视图，故判据取并集。
    /// 注意：`MacSyncView+Run.swift` 的扩展也要读（底栏背景），故不能用 `private`。
    var glassChromeLetsBackgroundThrough: Bool {
        settingsGlassActive || windowGlassActive
    }
    /// 执行侧（阶段 / 进度 / 结果）。
    @StateObject var model: MacSyncRunViewModel
    /// 内容侧（方向 / 内容源 / 选项 / 选择集）。
    @StateObject var content: MacSyncContentModel
    /// 数据同步侧（S2-T12：收藏 / 播放历史 / 歌单结构）。
    @StateObject var dataModel: MacSyncDataViewModel
    /// 运行时装配自检事实（L5：本端声明的能力真的装配上了吗；缺口 = 0 时面板空态）。
    /// 2026-09-20 批 6-8：迁 `@Observable` ⇒ 环境注入（非 private：`SyncDataPane.swift` 分区文件要用）。
    @Environment(SyncWiringFactsStore.self) var wiringFacts
    /// F2 对齐歌词补发轮的事实（连接就绪自动跑的那一轮；nil = 本次连接还没跑过）。
    @Environment(MacLyricsResendFactsStore.self) var lyricsFacts

    // MARK: - 置顶行与流（P1a：设备面已外移成 Popover）

    /// 「设备…」Popover 开关（设备 / 配对面唯一入口）。
    @State var showsDevicePopover = false
    /// 「同步」页当前流（传歌 / 播放数据）。
    @State var flow: MacSyncFlow = .tracks
    /// 智能源勾选的行内提示（nil = 无提示）。P1b：由 `toggleSmartSource` 返回、
    /// 视图自己持有——不进 `MacSyncContentModel` 的发布状态（迁移棘轮：不新增 @Published）。
    @State var smartSourceNotice: String?

    // MARK: - 设备页状态（原 `MacSyncCenterView`；拆分后仍由本类型持有 = 唯一观察者）

    @State var identity: SyncIdentity?
    @State var identityError: String?
    @State var qrPayload: PairQRPayload?
    @State var qrImage: NSImage?
    @State var devices: [PeerDevice] = []
    @State var devicesError: String?
    /// 待撤销配对的设备（nil = 无待确认删除）
    @State var pendingUnpair: PeerDevice?

    /// 设备区选中项（= 本次同步目标；**读**：唯一来源是持久化的 `DeleteSettings.syncTargetDeviceID`）。
    /// 批 B2：选择**持久化**（重启后仍记得）；写入一律走 `selectTargetDevice(_:)`
    /// （唯一写入口：归一 → 持久化 → 推进闸门）。

    /// 设备存储（设备页读写；与拆分前同款：视图层持有）。
    let deviceStore = DeviceStore()

    // MARK: - 同步页状态（原 `MacSyncRunSection`）

    /// 全曲库二次确认（Q4 决策：全库必须确认）。
    @State var showLibraryWideConfirm = false
    /// 「重新对账」二次确认（身份缺口包：重置两端游标 = 重新拉一遍，不可无声执行）。
    @State var showResetCursorsConfirm = false
    /// 二次确认文案里的规模（弹框时现算）。
    @State var libraryWidePreview: SyncUISelectionSummary = .empty
    /// E 结果区「详情」展开态（默认折叠；视图本地态，不持久化）。
    @State var showFileResultDetail = false
    /// F 数据同步结果「详情」展开态（同上）。
    @State var showDataResultDetail = false
    /// 本页设置读写（跨端续播开关；与 MacSettingsView 同做法：load → 改 → save）。
    @State var deleteSettings = DeleteSettings.load()
    /// 单曲搜索防抖任务。
    @State var searchTask: Task<Void, Never>?

    /// 发起方显式传入的中心实例（`init(hostCenter:)`；nil = 用环境值）。
    private let injectedHostCenter: SyncHostCenter?
    /// 本视图实际使用的中心：**显式传入优先**，否则环境值（保留 init 注入语义，与环境注入并存）。
    var hostCenter: SyncHostCenter { injectedHostCenter ?? envHostCenter }

    /// 本机展示名（QR hostName 字段；Bonjour 友好名优先，回落到进程主机名）
    var hostName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    /// ⚠️ 默认值是 `nil` 而不是 `.shared`：View 的 init 是非隔离上下文，
    /// 默认实参里直接引用 `@MainActor` 的 `.shared` 会报隔离错报（Swift 6 下是错误）
    /// （与两个 ViewModel 同一处理）。
    /// 2026-09-20 批 6-8：参数**保留**（调用方可传实例），只是不再用它建 `ObservedObject` ——
    /// 观察走环境注入；`hostCenter` 计算属性 = 显式传入 ?? 环境值。
    /// 注：三个 view model 仍在 init 里用 `hostCenter ?? .shared` 建（init 读不到环境值）；
    /// 组合根注入的就是同一个 `.shared`，两个入口传入的也是环境值 → 三处同一个实例。
    @MainActor
    init(hostCenter: SyncHostCenter? = nil, initialPage: MacSyncPage = .sync) {
        let center = hostCenter ?? .shared
        let contentModel = MacSyncContentModel(hostCenter: center)
        injectedHostCenter = hostCenter
        // P1a：`initialPage` 只作兼容入参（设备面已外移），内容区恒为「同步」页。
        _ = initialPage
        _content = StateObject(wrappedValue: contentModel)
        _model = StateObject(wrappedValue: MacSyncRunViewModel(hostCenter: center, content: contentModel))
        _dataModel = StateObject(wrappedValue: MacSyncDataViewModel(hostCenter: center))
    }

    var body: some View {
        // 2026-09-29：`Form` 壳由 `MacSyncCenterView` 下移到这里，置顶行才能固定
        // 在内容区顶部（`VStack` 内先放置顶行、再放独立滚动的 `Form`）。全部 `@State`
        // 仍留在本类型（唯一观察者）；P1a 起只有一页，设备面走 Popover、不卸载观察者。
        VStack(spacing: DesignTokens.space0) {
            pinnedHeader
            Form {
                syncPage
            }
            .formStyle(.grouped)
            // sheet（同步面板）与设置页两个来源共用一个 Form：让路判据取两个键的并集
            .macSheetGlassListBackground()

            // 2026-11-16 P0：执行区（选择摘要 + 开始/取消）固定在底栏，不再随 `Form` 滚动、
            // 不再被 sheet 底边裁切。P1a 起内容区恒为「同步」页 ⇒ 底栏恒在（无设备页）。
            syncActionBar
        }
        .onAppear {
            model.onAppear()
            deleteSettings = DeleteSettings.load()
            loadIdentityIfNeeded()
            // 监听生命周期归 SyncHostCenter（App 启动即常驻）；本视图只挂控制面回调。
            // ⚠️ 单槽回调：整个 App 仅此一处挂接（两个入口共用本视图）。
            // 审计 M4：槽位不再捕获本 View 值（struct）——修复前 `{ [self] in reloadDevices() }`
            // 形成 单例 → 闭包 → View 副本 → 单例 的强引用环（每开一次面板滞留一份 View
            // 及其 qrImage 位图/设备数组），且面板关闭后槽位仍指向已卸载副本，回调会写
            // 一个不再安装到视图上的 @State（静默无效）。改发无状态通知，订阅方是活视图。
            hostCenter.onDevicesChanged = {
                NotificationCenter.default.post(name: .macSyncDevicesChanged, object: nil)
            }
            reloadDevices()
            // 展示首张 QR（identity 就绪才生成；nonce 注册见 refreshQR）
            refreshQR()
        }
        .onDisappear {
            searchTask?.cancel()
            content.onDisappear()
            model.onDisappear()
            dataModel.onDisappear()
        }
        .onReceive(NotificationCenter.default.publisher(for: .macSyncDevicesChanged)) { _ in
            reloadDevices()
        }
        // 连接状态变化（移动端连上/断开）→ 重算在线态与默认选中
        .onChange(of: hostCenter.connectedPeer?.peerID) { _, _ in
            syncTargetSelection()
        }
        .alert(
            "sync_load_failed_title".localized,
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.clearError() } }
            )
        ) {
            Button(Localized.ok) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog(
            "sync_run_library_confirm_title".localized,
            isPresented: $showLibraryWideConfirm,
            titleVisibility: .visible
        ) {
            Button("sync_run_library_confirm_action".localized) {
                content.setLibraryWide()
            }
            Button(Localized.cancel, role: .cancel) {}
        } message: {
            Text(
                "sync_run_library_confirm_message".localized(
                    with: libraryWidePreview.sizeText,
                    libraryWidePreview.trackCount
                )
            )
        }
        .confirmationDialog(
            "sync_run_data_reset_confirm_title".localized,
            isPresented: $showResetCursorsConfirm,
            titleVisibility: .visible
        ) {
            Button("sync_run_data_reset_confirm_action".localized) {
                // 批 B2：显式传「所选设备」（不再由 `MacSyncDataViewModel` 自己读 connectedPeer）
                dataModel.resetCursorsForPeer(targetDeviceID ?? "")
            }
            Button(Localized.cancel, role: .cancel) {}
        } message: {
            Text("sync_run_data_reset_confirm_message".localized)
        }
        .confirmationDialog(
            "sync_unpair_confirm_title".localized,
            isPresented: Binding(
                get: { pendingUnpair != nil },
                set: { if !$0 { pendingUnpair = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingUnpair
        ) { device in
            Button("sync_unpair".localized, role: .destructive) {
                unpair(device)
            }
            Button(Localized.cancel, role: .cancel) {}
        } message: { device in
            Text("sync_unpair_confirm_message".localized(with: SyncDeviceList.displayName(device)))
        }
    }

    /// 置顶单行：左「歌曲/数据」流分段、右「设备…」按钮；行内不再重复「同步」标题（sheet 标题已有）。
    private var titleRow: some View {
        HStack(spacing: DesignTokens.space12) {
            SyncFlowPicker(flow: $flow)
            Spacer(minLength: DesignTokens.space0)
            devicesButton
        }
        .padding(.horizontal, DesignTokens.space20)
        .padding(.vertical, DesignTokens.space12)
    }

    /// 「设备…」按钮：设备 / 配对面的唯一入口 —— Popover 内容就是唯一实现 `devicePane`
    /// （不复制第二份设备面）。有未批准配对请求时按钮右上角挂红点，状态源是
    /// `hostCenter.pendingCard`（与设备面板同一份，不新订阅、不另存状态）。
    private var devicesButton: some View {
        let hasPending = hostCenter.pendingCard != nil
        return Button {
            showsDevicePopover.toggle()
        } label: {
            Text("sync_devices_button".localized)
                .overlay(alignment: .topTrailing) {
                    if hasPending {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                            .offset(x: DesignTokens.space6, y: -DesignTokens.space4)
                            .accessibilityHidden(true)
                    }
                }
        }
        .popover(isPresented: $showsDevicePopover, arrowEdge: .bottom) {
            Form {
                devicePane
            }
            .formStyle(.grouped)
            .frame(width: 520, height: 560)
        }
        .help("sync_devices_button".localized)
    }

    /// 置顶行：单行头部固定在内容区顶部，不随下方 `Form` 滚动
    /// （用户 2026-09-29：「最上面的 tab 需要永远置顶，不滚动」）。
    /// 只剩一行头部（流分段 + 设备入口）；picker 唯一实现见 `SyncFlowPicker`（`SyncTracksPane.swift`）。
    /// 背景 + 分隔线对齐 macOS 原生分组外观（`.bar` 随明暗外观自适应）。
    /// 设置窗玻璃生效时不画底 ⇒ 直接透出整窗封面模糊底（分隔线保留）。
    private var pinnedHeader: some View {
        VStack(spacing: DesignTokens.space0) {
            titleRow
            Divider()
        }
        .background(glassChromeLetsBackgroundThrough ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.bar))
    }

    // MARK: - 三块 Pane（批 D：独立 struct；父只做「值输入 + 回调」装配）

    /// 「设备」页（`SyncDevicePane`）。
    var devicePane: some View {
        SyncDevicePane(
            hostCenter: hostCenter,
            model: model,
            identity: identity,
            qrImage: qrImage,
            hostName: hostName,
            accentColor: accentColor,
            devices: devices,
            deviceRows: deviceRows,
            syncTargetStatus: syncTargetStatus,
            targetDeviceID: targetDeviceID,
            identityError: $identityError,
            devicesError: $devicesError,
            pendingUnpair: $pendingUnpair,
            onReloadDevices: { reloadDevices() },
            onRefreshQR: { refreshQR() },
            onSelectTarget: { selectTargetDevice($0) },
            onAdoptConnected: { adoptConnectedTarget() },
            onUnpair: { unpair($0) }
        )
    }

    /// 「同步」页（`SyncPage`：内容 switch 切传歌 / 播放数据；分段控件已上移置顶）。
    var syncPage: some View {
        SyncPage(
            flow: flow,
            tracksPane: tracksPane,
            dataPane: dataPane
        )
    }

    /// 传歌流（`SyncTracksPane`）——三区（方向 / 内容选择 / 结果）本体仍由分区文件构建，
    /// 本处只做组合；D 执行区 2026-11-16 已删。
    var tracksPane: some View {
        SyncTracksPane(
            directionSection: directionSection,
            selectionSection: selectionSection,
            resultSection: resultSection
        )
    }

    /// 播放数据流（`SyncDataPane`）。
    var dataPane: some View {
        SyncDataPane(
            dataModel: dataModel,
            wiringFacts: wiringFacts,
            syncTargetStatus: syncTargetStatus,
            onAdoptConnected: { adoptConnectedTarget() },
            deleteSettings: $deleteSettings,
            showResetCursorsConfirm: $showResetCursorsConfirm,
            showDataResultDetail: $showDataResultDetail
        )
    }

    // MARK: - 设备页数据（原 `MacSyncCenterView`，2026-09-26 批 B1 随状态一并迁来）

    func loadIdentityIfNeeded() {
        guard identity == nil else { return }
        do {
            identity = try SyncIdentityStore().loadOrCreateIdentity()
        } catch {
            identityError = error.localizedDescription
        }
    }

    /// 生成新 nonce + 载荷并重绘二维码（每次调用换一张新码）。
    /// S2 接线：新码的 sessionNonce 同步注册进运行中的监听器（不注册则
    /// 客户端带签名 nonce 回连时验签无源 → 配对必被拒）。
    /// 监听器未运行（开关关闭 / 启动失败）时静默忽略（与旧行为一致）。
    @MainActor
    func refreshQR() {
        guard let identity else { return }
        let payload = PairQRPayloadFactory.make(
            hostName: hostName,
            identity: identity,
            sessionNonce: SyncSessionNonce.makeNew()
        )
        do {
            let json = try SyncQRCodec.encode(payload)
            qrPayload = payload
            qrImage = SyncQRImageFactory.make(from: json)
            hostCenter.registerQRNonce(nonceBase64: payload.sessionNonce)
        } catch {
            identityError = error.localizedDescription
        }
    }

    func reloadDevices() {
        do {
            devices = try deviceStore.all()
        } catch {
            devicesError = error.localizedDescription
        }
        syncTargetSelection()
    }

    /// 设备区选中项（= 本次同步目标）。批 B2：持久化在既有偏好入口 `DeleteSettings` 里
    /// （重启后仍记得所选设备；空串 = 未选）。判定一律走 `SyncDeviceListModel`（纯逻辑）。
    var targetDeviceID: String? {
        deleteSettings.syncTargetDeviceID.isEmpty ? nil : deleteSettings.syncTargetDeviceID
    }

    /// 目标行模型（过滤 + 在线态 + 短码，决策全在 `SyncDeviceListModel`）。
    /// 批 D：由「设备」Pane 文件迁回本文件（父是唯一真值持有者：装配与对账都读它）。
    var deviceRows: [SyncDeviceTargetRow] {
        SyncDeviceListModel.rows(
            in: devices,
            onlinePeerID: hostCenter.connectedPeer?.peerID
        )
    }

    /// 本次同步目标状态（唯一决策 `SyncDeviceListModel` 的结论；View 只渲染）。
    var syncTargetStatus: SyncDeviceTargetStatus {
        SyncDeviceTargetSelection(peerID: targetDeviceID).status(in: deviceRows)
    }

    /// 选中一台设备（**唯一写入口**）：归一 → 写持久化 → 推进闸门。
    /// 传 nil 清空选择（不删任何记录，只是「没选目标」）。
    func selectTargetDevice(_ peerID: String?) {
        let normalized = SyncDeviceTargetSelection(peerID: peerID).peerID
        if normalized != targetDeviceID {
            deleteSettings.syncTargetDeviceID = normalized ?? ""
            deleteSettings.save()
        }
        syncTargetSelection()
    }

    /// 「连上的 ≠ 所选」提示里的**一键改用**：把选择改成当前连上的那台。
    /// 选择从哪来仍是决策层的事（`SyncDeviceListModel.adoptingConnectedPeer`）。
    func adoptConnectedTarget() {
        let adopted = SyncDeviceTargetSelection(peerID: targetDeviceID).adoptingConnectedPeer(in: deviceRows)
        selectTargetDevice(adopted.peerID)
    }

    /// 设备列表 / 连接状态 / 选择变化后重算选中（在线优先、原选中仍在则保持），
    /// 并把「唯一决策」的结果推给两个执行侧（传歌 / 数据）—— 连同目标在线态构成同步闸门。
    func syncTargetSelection() {
        let rows = deviceRows
        let reconciled = SyncDeviceTargetSelection(peerID: targetDeviceID).reconciled(in: rows)
        if reconciled.peerID != targetDeviceID {
            // 原选中已撤销配对（或从未选过）→ 回落到默认（在线那台 / 未选）并持久化
            deleteSettings.syncTargetDeviceID = reconciled.peerID ?? ""
            deleteSettings.save()
        }
        let status = reconciled.status(in: rows)
        // 批 B2 收尾：目标状态不再镜像到两个 ViewModel —— 传歌侧经 `updateSyncTarget` 落进其私有
        // 镜像并刷新闸门；数据侧的派生/动作点由视图直接传 `syncTargetStatus`（见 `SyncDataPane`）。
        model.updateSyncTarget(status)
    }

    func unpair(_ device: PeerDevice) {
        do {
            try deviceStore.remove(peerID: device.peerID)
            reloadDevices()
        } catch {
            devicesError = error.localizedDescription
        }
    }
}

#Preview("设备页") {
    Form {
        MacSyncRunSection(initialPage: .device)
    }
    .formStyle(.grouped)
    .frame(width: 560, height: 720)
    // Preview 是组合根之外的第二个合法装配点（App 根注入不覆盖画布）→ 显式装配（批 6-8）。
    // 实例取自 `MacSyncPreviewEnvironment`（非视图层 helper）⇒ 视图文件里不留 `.shared` 直连。
    .environment(MacSyncPreviewEnvironment.hostCenter)
    .environment(MacSyncPreviewEnvironment.wiringFacts)
    .environment(MacSyncPreviewEnvironment.lyricsResendFacts)
}

#Preview("同步页") {
    Form {
        MacSyncRunSection(initialPage: .sync)
    }
    .formStyle(.grouped)
    .frame(width: 560, height: 720)
    .environment(MacSyncPreviewEnvironment.hostCenter)
    .environment(MacSyncPreviewEnvironment.wiringFacts)
    .environment(MacSyncPreviewEnvironment.lyricsResendFacts)
}
