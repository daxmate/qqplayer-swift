#if os(iOS)

    import Foundation

    // target: ios-only（iOS 被动同步中心分片：数据同步端装配（帧 8/9）；macOS 不编译）

    extension IOSPassiveSyncCenter {
        /// 索引终态事实变化 → 若会话已就绪，补装数据同步端（幂等：已装配就什么都不做）。
        ///
        /// internal（非 private）仅供 iOS 测试 target 驱动这条路径（与 `attachPassiveHost` 同口径）；
        /// 生产只由 `observeIndexingTerminalState` 的订阅回调触发。
        func refreshDataSyncAttachment() {
            guard let session = dataSyncSession, session.isReady else { return }
            attachDataSync(to: session)
        }

        /// 被动端数据同步端的 applier：开关开（跨端续播）才注入落点；
        /// 门控期的轻量应答端：只回 notReady（空批 + 不推进游标），不接数据、不补发对账。
        private func installNotReadyResponderIfNeeded(on session: SyncPeerSession) {
            guard dataSyncNotReadyResponder == nil else { return }
            dataSyncNotReadyResponder = SyncChangeLogNotReadyResponder(session: session)
            AppLog.warn(
                .general,
                "⏸️ IOSPassiveSyncCenter: 曲库索引未到终态，装配轻量应答端（只回 notReady；不发起数据同步、不补发对账，待终态后换真实应答端）"
            )
        }

        /// 门控被命中时的事实（2026-11-03 真机复现用）：两个来源都记，便于区分
        /// 「本启动还没扫完」与「曲库确实还没有行」。
        /// ⚠️ 只读 isIndexing / 扫描 latch / track 行数，不在这里复述门的判定
        /// （唯一实现仍是 IndexingGate）。
        private func logGateFacts() {
            let scanned = (indexingState as? LibraryIndexer)?.hasCompletedScanThisLaunch ?? false
            let rows: Int? = try? database.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track")
            }
            AppLog.info(
                .general,
                "ℹ️ IOSPassiveSyncCenter: 门控事实（hasCompletedScanThisLaunch=\(scanned)，"
                    + "isIndexing=\(indexingState.isIndexing)，track 行数=\(rows.map(String.init) ?? "读取失败")）"
            )
        }

        /// 关 = 本端不接受播放位置（关着时行不落地也不计「已应用」，见 INV-20/INV-26）。
        private static func makePassiveApplier(database: DatabaseManager) -> SyncChangeLogApplier {
            var applier = SyncChangeLogApplier(database: database)
            if applier.playbackPositionSyncEnabled {
                applier.playbackPositionSink = { PlaybackPositionResumeSink.apply($0) }
            }
            return applier
        }

        /// 数据同步账目累加（主线程）。会话回调不在主线程 → 调用方负责 `Task { @MainActor in }`。
        private func recordDataSync(_ mutate: (inout IOSPassiveDataSyncSummary) -> Void) {
            var updated = dataSummary
            mutate(&updated)
            updated.hasSessionData = true
            updated.updatedAt = Date()
            dataSummary = updated
        }

        /// 会话 ready → 装配数据同步端（帧 8/9 = `SyncChangeLogPeer`，全仓帧 8/9 唯一处理器）。
        ///
        /// **前置门**（唯一判定 = `IndexingGate.isReadyForChangeLogSync`）：曲库索引未到终态时
        /// 本端**不接数据**——不装配 peer（不发起数据同步、不应用远端行、不跑补发对账），
        /// 但**会回 notReady**（轻量应答端）：沉默会让对端每轮都等满 20s 应答窗口。等终态后
        /// 由 `refreshDataSyncAttachment()` 换成真实应答端。理由见 `IndexingGate` 内的取证注释。
        ///
        /// 装配顺序：本方法在 `SyncLibraryPassiveHost.attach` **之后**调用——
        /// `SyncChangeLogPeer.init` 会把 handler 挂成链头并转发 prior，于是帧 8/9 由它处理、
        /// 帧 15 继续到达被动端（见文件头「会话回调单槽 + 挂接顺序」）。
        func attachDataSync(to session: SyncPeerSession) {
            guard dataSyncPeer == nil else { return }
            guard IndexingGate.isReadyForChangeLogSync(indexingState) else {
                // 门控期**不能沉默**：对端发来 change_log_pull 时若无处理器，它只能等满
                // 20s 应答窗口再报「对端无应答」（2026-11-03 真机取证）。装轻量应答端，
                // 立刻回 notReady，对端按退避重试；门开后由本方法下半段换成真实应答端。
                installNotReadyResponderIfNeeded(on: session)
                logGateFacts()
                return
            }
            // 门开了：先停掉轻量应答端（否则它会和真实应答端各回一条），再装配真身。
            dataSyncNotReadyResponder?.deactivate()
            dataSyncNotReadyResponder = nil
            guard let peerID = IOSPassiveDataSyncLogic.dataSyncPeerID(
                peerDeviceID: session.peerHelloValue?.deviceID
            ) else {
                // 空游标键会往 sync_cursor 写脏行（与 MacSyncCoordinatorFactory 同口径）
                AppLog.warn(.general, "⚠️ IOSPassiveSyncCenter: 会话无对端 Device ID，不装配数据同步端（避免空游标键写脏数据）")
                return
            }
            // T15b（2026-09-14）：装配数据同步端**之前**先对账本端 outbox 的出站悬空引用
            // （引用 stableId 在 track 表查无行的行——容器路径变化后旧 id 失效，业务表被
            // TrackIdentityMigration 迁移过、outbox 没有 → 每轮推送这些行都拿不到指纹，
            // 对端全部判「未定位」跳过）。本方法一次会话只走一次（dataSyncPeer == nil 守卫），
            // 正好在首次推送之前把 outbox 修好/清干净。失败只打日志，不影响装配主流程。
            do {
                let repair = try SyncChangeLogDanglingRepair(database: database).run()
                if repair.didChange {
                    AppLog.info(.general, "ℹ️ IOSPassiveSyncCenter: 出站悬空引用修复 + 本地真值补发完成" + repair.logText)
                }
            } catch {
                AppLog.warn(.general, "⚠️ IOSPassiveSyncCenter: 出站悬空引用对账失败 \(error)")
            }
            let applier = Self.makePassiveApplier(database: database)
            // 自检事实：门控开 = 「落点真的注入了吗」，门控关 = 不适用（不报缺口，INV-26）。
            playbackPositionSinkAttached = applier.playbackPositionSyncEnabled
                ? (applier.playbackPositionSink != nil)
                : nil
            let peer = SyncChangeLogPeer(
                session: session,
                store: SyncChangeLogStore(database: database),
                applier: applier,
                peerID: peerID,
                libraryRoot: libraryRoot()
            )
            // 诊断打点：只记计数 / 错误类别，不打印曲目内容（隐私）。
            // 同一批数字同时交给 `dataSummary`（手机侧的账目面板，2026-09-15）——
            // 会话回调不在主线程 → 统一 Task 跳主线程累加。
            peer.onPullHandled = { [weak self] _, count in
                AppLog.info(.general, "ℹ️ SyncChangeLogPeer: 已应答远端拉取（本批 outbox 行数=\(count)）")
                Task { @MainActor in self?.recordDataSync { $0.tally.overwrite(.outbound, with: count) } }
            }
            peer.onPushApplied = { [weak self] count in
                AppLog.info(.general, "ℹ️ SyncChangeLogPeer: 已应用远端播放数据（行数=\(count)）")
                Task { @MainActor in self?.recordDataSync { $0.tally.accumulate(.applied, count: count) } }
            }
            peer.onPushSuspended = { [weak self] groups in
                Task { @MainActor in
                    self?.recordDataSync { summary in
                        for group in groups {
                            summary.tally.accumulate(.suspended, entity: group.entity, count: group.count)
                        }
                    }
                }
                let total = groups.reduce(0) { $0 + $1.count }
                guard total > 0 else { return }
                AppLog.info(.general, "ℹ️ SyncChangeLogPeer: 本地缺歌挂起（行数=\(total)，待歌到位重放）")
            }
            // 身份缺口披露（2026-09-14）：引用歌曲但拿不到指纹的行两端都跳/标。
            peer.onPushUnresolved = { [weak self] groups in
                Task { @MainActor in
                    self?.recordDataSync { summary in
                        for group in groups {
                            summary.tally.accumulate(.unresolved, entity: group.entity, count: group.count)
                        }
                    }
                }
                let total = groups.reduce(0) { $0 + $1.count }
                guard total > 0 else { return }
                AppLog.warn(.general, "⚠️ SyncChangeLogPeer: 跳过未定位的远端行（行数=\(total)，缺身份键）")
            }
            // 身份歧义（2026-09-15）：第二身份相对路径命中多首本地曲目 → 不落库。
            peer.onPushAmbiguous = { [weak self] groups in
                Task { @MainActor in
                    self?.recordDataSync { summary in
                        for group in groups {
                            summary.tally.accumulate(.ambiguousIdentity, entity: group.entity, count: group.count)
                        }
                    }
                }
                let total = groups.reduce(0) { $0 + $1.count }
                guard total > 0 else { return }
                AppLog.warn(.general, "⚠️ SyncChangeLogPeer: 跳过身份歧义的远端行（行数=\(total)，相对路径命中多首本地曲目）")
            }
            // 父行 / 被引用行不存在而跳过（矩阵三级 #8）：以前静默失败，现在计数可见。
            peer.onPushSkippedMissingParent = { [weak self] groups in
                Task { @MainActor in
                    self?.recordDataSync { summary in
                        for group in groups {
                            summary.tally.accumulate(.skippedMissingParent, entity: group.entity, count: group.count)
                        }
                    }
                }
                let total = groups.reduce(0) { $0 + $1.count }
                guard total > 0 else { return }
                AppLog.info(.general, "ℹ️ SyncChangeLogPeer: 跳过依赖尚未到达的远端行（行数=\(total)，歌单结构未到或歌无本机行）")
            }
            // 跨端续播关（默认）/ 落点未接：播放位置行不落地、也不计入「已应用」。
            peer.onPushUnsupported = { [weak self] groups in
                Task { @MainActor in
                    self?.recordDataSync { summary in
                        for group in groups {
                            summary.tally.accumulate(.unsupported, entity: group.entity, count: group.count)
                        }
                    }
                }
                let total = groups.reduce(0) { $0 + $1.count }
                guard total > 0 else { return }
                AppLog.info(.general, "ℹ️ SyncChangeLogPeer: 跳过未落地的播放位置行（行数=\(total)，跨端续播关或落点未接）")
            }
            // 应用失败（载荷解不开 / 落库抛错；歌单级失败在这里单独可见）
            peer.onPushApplyFailed = { [weak self] groups in
                Task { @MainActor in
                    self?.recordDataSync { summary in
                        for group in groups {
                            summary.tally.accumulate(.applyFailed, entity: group.entity, count: group.count)
                        }
                    }
                }
                let total = groups.reduce(0) { $0 + $1.count }
                guard total > 0 else { return }
                AppLog.warn(.general, "⚠️ SyncChangeLogPeer: 应用失败的远端行（行数=\(total)，载荷非法或落库失败）")
            }
            // 时钟超前门（契约 B1 / INV-34）：对端时间戳来自未来的行不应用，按实体计数上屏。
            peer.onPushFutureTimestamp = { [weak self] groups in
                Task { @MainActor in
                    self?.recordDataSync { summary in
                        for group in groups {
                            summary.tally.accumulate(.futureTimestamp, entity: group.entity, count: group.count)
                        }
                    }
                }
                let total = groups.reduce(0) { $0 + $1.count }
                guard total > 0 else { return }
                AppLog.warn(.general, "⚠️ SyncChangeLogPeer: 对端时间戳超前的远端行（行数=\(total)，超过 5 分钟容差，未应用）")
            }
            peer.onPullMissingIdentity = { [weak self] groups in
                Task { @MainActor in
                    self?.recordDataSync { summary in
                        for group in groups {
                            summary.tally.accumulate(.missingIdentity, entity: group.entity, count: group.count)
                        }
                    }
                }
                let total = groups.reduce(0) { $0 + $1.count }
                guard total > 0 else { return }
                AppLog.warn(.general, "⚠️ SyncChangeLogPeer: 应答拉取时有 \(total) 行缺身份键（对端定位不了）")
            }
            peer.onIncrementMissingIdentity = { [weak self] groups in
                Task { @MainActor in
                    self?.recordDataSync { summary in
                        for group in groups {
                            summary.tally.accumulate(.missingIdentity, entity: group.entity, count: group.count)
                        }
                    }
                }
                let total = groups.reduce(0) { $0 + $1.count }
                guard total > 0 else { return }
                AppLog.warn(.general, "⚠️ SyncChangeLogPeer: 推送增量时有 \(total) 行缺身份键（对端定位不了）")
            }
            peer.onPushIgnoredDeletes = { [weak self] count in
                Task { @MainActor in self?.recordDataSync { $0.tally.accumulate(.ignoredDelete, count: count) } }
                guard count > 0 else { return }
                AppLog.info(.general, "ℹ️ SyncChangeLogPeer: 忽略远端删除（行数=\(count)，删除不跨端传播）")
            }
            peer.onDecodeFailure = { error in
                AppLog.warn(.general, "⚠️ SyncChangeLogPeer: 载荷解码失败 \(error)")
            }
            dataSyncPeer = peer
            dataSyncPeerID = peerID
            AppLog.info(.general, "ℹ️ IOSPassiveSyncCenter: 数据同步端已装配（帧 8/9）")
        }
    }

#endif
