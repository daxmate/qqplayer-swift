//
//  SyncEntityRegistry+Assembly.swift
//  QQPlayer
//
//  注册表的平台常量、共享装配点与派生访问器（自 SyncEntityRegistry.swift 拆出）。
//  唯一声明处仍是 SyncEntityRegistry.swift（实体清单字面量留在那里）；本片只放常量与派生。
//  同族：SyncEntityRegistry.swift、SyncEntityRegistry+Shape.swift（登记形状类型）。
//

import Foundation

extension SyncEntityRegistry {
    /// 帧 8/9（变更日志通道）的帧号——装配点里重复出现，抽成常量防写错。
    /// 帧号冻结断言（`frame-8-9-numbers-frozen`）的标记也由它派生：改常量 = 断言自动跟改。
    static let changeLogFrameNumbers = (pull: 8, push: 9)

    /// 平台标识：装配点与运行时自检共用的**唯一口径**（不得在别处手写 "Mac" / "iOS" 字面量）。
    static let platformMac = "Mac"
    static let platformIOS = "iOS"

    /// 帧号冻结断言的标记（**派生自 `changeLogFrameNumbers`**，手写「= 8」不可能与之漂移）。
    static var frozenFrameMarkers: [String] {
        [
            "case changeLogPull = \(changeLogFrameNumbers.pull)",
            "case changeLogPush = \(changeLogFrameNumbers.push)",
        ]
    }

    // MARK: - 共享装配点（不属任何一条实体登记）

    /// **跨实体的装配点**：通道级（帧 8/9 的处理器与线上帧号）与平台级编排（Mac 跟歌走携带）。
    ///
    /// 与实体装配点**同一类型、同一份申报**：静态断言（`assertion`）与运行时自检（`probe`）
    /// 走同一条推导路径——此前这几条活在 `SyncWiringContractTests` 的手写清单里，正是
    /// 「同一语义多处手工维护」的另一半。
    static let sharedAssemblyPoints: [SyncEntityAssemblyPoint] = [
        SyncEntityAssemblyPoint(
            platform: nil,
            frame: changeLogFrameNumbers.push,
            detail: "帧 8/9 的分发处理器：SyncChangeLogPeer 的帧分发表（两端共用同一处理器）",
            assertion: SyncEntityAssemblyAssertion(
                id: "frame-8-9-handler-present",
                path: "QQPlayer/Sync/SyncChangeLogPeer.swift",
                requiredMarkers: ["case .changeLogPull:", "case .changeLogPush:"],
                alternativeMarkers: [],
                guidance: """
                帧 8/9 的唯一处理器没了（分支被删 / 改名）：全仓再没有地方响应播放数据同步帧 → 帧 8/9 变成死协议。
                请检查 SyncChangeLogPeer 的帧分发表是否仍有 case .changeLogPull: / case .changeLogPush: 两个分支（类型本身存在于 QQPlayer/Sync/SyncChangeLogPeer.swift）。
                """
            ),
            probe: nil
        ),
        SyncEntityAssemblyPoint(
            platform: nil,
            frame: changeLogFrameNumbers.pull,
            detail: "帧 8/9 的线上帧号：SyncFrame 的 changeLogPull / changeLogPush（两端版本可能不同步升级）",
            assertion: SyncEntityAssemblyAssertion(
                id: "frame-8-9-numbers-frozen",
                path: "QQPlayer/Sync/SyncFrame.swift",
                // 标记**派生自 `changeLogFrameNumbers`**：改常量 = 断言里期望的号自动跟着变。
                requiredMarkers: frozenFrameMarkers,
                alternativeMarkers: [],
                guidance: """
                帧号被改动了：帧 8/9 是跨端线上契约（两端版本可能不同步升级），改号 = 老版本对端解错帧、同步静默错乱。
                请把 SyncFrame.FrameType 的 changeLogPull 恢复到 = 8、changeLogPush 恢复到 = 9（新增帧只能用未占用的号段）。
                """
            ),
            probe: nil
        ),
        SyncEntityAssemblyPoint(
            platform: nil,
            frame: nil,
            detail: "歌曲身份解析入口：SyncContentHashResolver 遵守 SyncIdentityResolving，歌词映射从入口构造（两端共用）",
            assertion: SyncEntityAssemblyAssertion(
                id: "identity-entry-implemented-and-wired",
                path: "QQPlayer/Sync/SyncChangeLogMapping.swift",
                requiredMarkers: [
                    "extension SyncContentHashResolver: SyncIdentityResolving",
                    "SyncLyricsContentMapping(identity:",
                ],
                alternativeMarkers: [],
                guidance: """
                歌曲身份解析的入口实现断了：`SyncContentHashResolver` 不再声明遵守 `SyncIdentityResolving`，
                或歌词映射不再从入口构造（`SyncLyricsContentMapping(identity:)`）——两条都是「入口空转」的形状：
                编译能过（协议可选遵守）、下游各自拿闭包，漏接线一处就静默。
                请检查 QQPlayer/Sync/SyncChangeLogMapping.swift：`SyncContentHashResolver` 必须有 `: SyncIdentityResolving` 遵守声明，
                `.live(database:libraryRoot:)` 必须走 `SyncLyricsContentMapping(identity: SyncContentHashResolver(database:libraryRoot:))`。
                """
            ),
            probe: nil
        ),
        SyncEntityAssemblyPoint(
            platform: platformMac,
            frame: nil,
            detail: "跟歌走携带：MacSyncCoordinatorFactory 把 SyncPlaybackCarryPeer 装配进 SyncCollectionSyncCoordinator（R3b；对端 Device ID 为空则不装）",
            assertion: SyncEntityAssemblyAssertion(
                id: "mac-playback-carry-attached",
                path: "QQPlayer/Mac/MacSyncCoordinatorFactory.swift",
                requiredMarkers: ["SyncPlaybackCarryPeer("],
                alternativeMarkers: [],
                guidance: """
                跟歌走链路失去装配：推 / 拉歌时播放数据不再跟随传输 → R3b 能力静默失效（要用户重新同步数据才补回来）。
                请检查 MacSyncCoordinatorFactory 里 SyncCollectionSyncCoordinator 的 playbackCarry 实参是否仍传 SyncPlaybackCarryPeer(session:libraryRoot:peerID:)。
                """
            ),
            probe: .playbackCarry
        ),
    ]

    // MARK: - 派生访问器（散落名单只准从这里取，不得手写第二份）

    /// **全部装配点**（实体维度 + 共享维度）——静态装配断言与运行时自检的唯一来源。
    static var allAssemblyPoints: [SyncEntityAssemblyPoint] {
        entries.flatMap(\.assemblyPoints) + sharedAssemblyPoints
    }

    /// 全部 **(能力标识, 装配点)**：实体装配点的标识 = 登记的 L0 编号；共享装配点的标识 = 断言 id。
    /// 静态断言与运行时自检都从这里取（一处声明，两处消费）。
    static var capabilityAssemblyPoints: [(capabilityID: String, point: SyncEntityAssemblyPoint)] {
        entries.flatMap { entry in
            entry.assemblyPoints.map { (entry.l0ID, $0) }
        } + sharedAssemblyPoints.map { ($0.assertion?.id ?? "shared", $0) }
    }

    /// 某平台声明的装配点（顺序 = 注册表声明顺序；`nil` 平台 = 与平台无关，不在此列）。
    static func assemblyPoints(platform: String) -> [SyncEntityAssemblyPoint] {
        allAssemblyPoints.filter { $0.platform == platform }
    }

    /// **实体词表的顺序**（= 注册表声明顺序；只取有 `SyncChangeEntity` 的登记，A–E）。
    ///
    /// 用途 = 结果计数的**分桶维度 + 展示顺序**（按实体披露的明细行）都从这里派生，
    /// 面板/计数层不得手写第二份实体名单。
    static var entityOrder: [SyncChangeEntity] {
        entries.compactMap(\.entity)
    }

    /// 某实体的登记（未登记 = nil）。
    static func entry(for entity: SyncChangeEntity) -> SyncEntityRegistryEntry? {
        entries.first { $0.entity == entity }
    }

    /// 该实体是否引用歌曲（= 上线时需要跨端身份键）。
    ///
    /// 语义与收口前的手写判定（`entity` 是否等于 `.playlist`）**逐项相同**：未登记的 case 取 `true`
    /// （默认「引用」= 保守，缺身份键会被计数披露而不会静默错落库）。
    /// 「每个 case 都必须有登记」由 CI 的 `everyEntityCaseIsRegistered` 保证。
    static func referencesTrack(_ entity: SyncChangeEntity) -> Bool {
        entry(for: entity)?.referencesTrack ?? true
    }
}
