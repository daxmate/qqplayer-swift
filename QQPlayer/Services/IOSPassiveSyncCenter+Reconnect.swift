#if os(iOS)

    import Combine
    import Foundation

    // target: ios-only（iOS 被动同步中心分片：发现/重连/拆线；macOS 不编译）

    extension IOSPassiveSyncCenter {
        /// 订阅「曲库索引终态」事实：终态一到，把此前被前置门挡住的数据同步端补上
        /// （会话仍在时才动；判定只有一处 = `IndexingGate.isReadyForChangeLogSync`）。
        func observeIndexingTerminalState() {
            guard indexingTerminalStateCancellable == nil else { return }
            indexingTerminalStateCancellable = indexingState.indexingTerminalStatePublisher
                .sink { [weak self] in
                    Task { @MainActor in self?.refreshDataSyncAttachment() }
                }
        }

        // MARK: 一次尝试

        func beginAttempt() {
            cancelDiscovery()
            cancelReconnect()
            isWaitingBackoff = false
            // ⚠️ 故意**不**清 `attemptedTargets`：DNS-SD 逐条投递，若一台非同步主机
            // （如 Mac 上的 Python web 端，广播同一服务类型）先到，不清记忆就会每轮
            // 都先撞它、真正的桌面端永远排不到（2026-09-17 真机踩过）。用户手动
            // 「重连」时才重置（见 `reconnectNow`）。
            currentTarget = nil
            tearDownSession()
            reloadPairedHosts()

            guard !pairedHosts.isEmpty else {
                // 无已配对主机：不起浏览（省电），交设置页引导扫码
                state = .idle
                return
            }
            guard let identity = try? identityStore.loadOrCreateIdentity() else {
                state = .failed(.identityUnavailable)
                return
            }

            let token = UUID()
            attemptToken = token
            browser?.stopBrowsing()
            let browser = SyncBrowser(localIdentity: identity, trustStore: deviceStore)
            browser.onResultsChanged = { [weak self] hosts in
                Task { @MainActor in
                    guard let self, self.attemptToken == token else { return }
                    self.handleResults(hosts)
                }
            }
            browser.onBrowseFailure = { [weak self] _ in
                SyncConnectDiag.log("📡 浏览失败回调（按发现超时处理）")
                Task { @MainActor in
                    guard let self, self.attemptToken == token else { return }
                    self.handleDiscoveryTimeout()
                }
            }
            self.browser = browser
            state = .connecting(hostName: nil)
            browser.startBrowsing()
            scheduleDiscoveryTimeout(token: token)
        }

        private func handleResults(_ hosts: [SyncDiscoveredHost]) {
            guard isRunning, session == nil, !isWaitingBackoff, !state.isConnected else { return }
            let candidates = IOSPassiveReconnectLogic.targets(discovered: hosts, pairedHosts: pairedHosts)
            // 本轮候选全部试过 → 清空记忆重来（保证活性：对端换了名字/刚上线时仍能重试）
            var unattempted = candidates.filter { !attemptedTargets.contains(Self.key($0)) }
            if unattempted.isEmpty, !candidates.isEmpty {
                attemptedTargets.removeAll()
                unattempted = candidates
            }
            SyncConnectDiag.log(
                "🔍 discovered=[\(hosts.map(\.name).joined(separator: " | "))] "
                    + "candidates=[\(candidates.map(\.hostName).joined(separator: " | "))] "
                    + "unattempted=[\(unattempted.map(\.hostName).joined(separator: " | "))]"
            )
            guard let candidate = unattempted.first else {
                // 无候选：继续等 discoveryTimeout 判失败
                return
            }
            attemptedTargets.insert(Self.key(candidate))
            connect(to: candidate)
        }

        private func connect(to target: IOSPassiveSyncTarget) {
            guard let browser else { return }
            currentTarget = target
            state = .connecting(hostName: target.hostName)
            SyncConnectDiag.log(
                "🔗 connect target=\(target.hostName) peer=\(target.peerID.prefix(8)) "
                    + "endpoint=\(SyncConnectDiag.describe(target.endpoint))"
            )

            var config = SyncSessionConfiguration()
            config.clientDisplayName = clientName()
            let token = attemptToken
            let session = browser.connect(
                to: target.endpoint,
                expectedPeerDeviceID: target.peerID,
                candidate: nil, // 已配对重连：不带扫码候选 → 直通 ready（信任表 pinning 验证）
                config: config
            )
            // 链式挂接（SyncBrowser.connect 已设 onStateChange 做 channel 清理，
            // 绝不能覆盖）：存 prior → 先己后彼。
            let priorState = session.onStateChange
            session.onStateChange = { [weak self] phase in
                Task { @MainActor in
                    guard let self, self.attemptToken == token else { return }
                    self.handlePhase(phase)
                }
                priorState?(phase)
            }
            let priorClosed = session.onClosed
            session.onClosed = { [weak self] reason in
                Task { @MainActor in
                    guard let self, self.attemptToken == token else { return }
                    self.handleClosed(reason)
                }
                priorClosed?(reason)
            }
            self.session = session
        }

        // MARK: 会话推进

        private func handlePhase(_ phase: SyncSessionPhase) {
            guard isRunning, !isTearingDown, phase == .ready, let session, let target = currentTarget else { return }
            guard !state.isConnected else { return }
            cancelDiscovery()
            automaticAttempts = 0
            attemptedTargets.removeAll()
            attachPassiveHost(to: session)
            state = .connected(hostName: target.hostName, peerID: target.peerID)
        }

        private func handleClosed(_ reason: SyncSessionCloseReason) {
            guard !isTearingDown else { return }
            SyncConnectDiag.log("🛑 session closed reason=\(reason) target=\(currentTarget?.hostName ?? "-")")
            session = nil
            passiveHost = nil
            dataSyncPeer = nil
            dataSyncPeerID = nil
            dataSyncSession = nil
            playbackPositionSinkAttached = nil
            SyncWiringFactsStore.shared.clear()
            currentTarget = nil
            guard isRunning else { return }
            if let failure = SyncConnectLogic.failure(fromCloseReason: reason) {
                state = .failed(.connect(failure))
            }
            scheduleReconnect()
        }

        private func handleDiscoveryTimeout() {
            guard isRunning, !isWaitingBackoff, !state.isConnected else { return }
            guard !sessionHasPeer else { return }
            SyncConnectDiag.log("⏳ discovery timeout target=\(currentTarget?.hostName ?? "-") paired=\(pairedHosts.count)")
            cancelDiscovery()
            state = .failed(.connect(.hostNotFound(hostName: currentTarget?.hostName ?? pairedHosts.first?.displayName)))
            scheduleReconnect()
        }

        /// 是否已建立会话（浏览超时判定用：有会话就不算「没找到主机」）
        private var sessionHasPeer: Bool {
            session != nil
        }

        // MARK: 重连退避

        private func scheduleReconnect() {
            guard isRunning else { return }
            automaticAttempts += 1
            guard let delay = IOSPassiveReconnectPolicy.delayBeforeAttempt(automaticAttempts) else {
                // 上限用尽：保持 failed，交设置页「重连」手动兜底
                browser?.stopBrowsing()
                browser = nil
                return
            }
            isWaitingBackoff = true
            cancelDiscovery()
            let token = attemptToken
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self, self.isRunning, self.attemptToken == token else { return }
                    self.beginAttempt()
                }
            }
            reconnectWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        private func scheduleDiscoveryTimeout(token: UUID) {
            cancelDiscovery()
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self, self.attemptToken == token else { return }
                    self.handleDiscoveryTimeout()
                }
            }
            discoveryWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + SyncAutoConnectController.discoveryTimeout,
                execute: work
            )
        }

        func cancelDiscovery() {
            discoveryWork?.cancel()
            discoveryWork = nil
        }

        func cancelReconnect() {
            reconnectWork?.cancel()
            reconnectWork = nil
            isWaitingBackoff = false
        }

        // MARK: 清理

        func tearDownSession() {
            isTearingDown = true
            passiveHost?.detach()
            passiveHost = nil
            dataSyncPeer = nil
            dataSyncPeerID = nil
            dataSyncSession = nil
            playbackPositionSinkAttached = nil
            // 会话拆除：自检事实归零（不是缺口——没有会话就谈不上装配）。
            SyncWiringFactsStore.shared.clear()
            session?.cancel(reason: .userCancelled)
            session = nil
            isTearingDown = false
            attemptToken = UUID()
        }

        func reloadPairedHosts() {
            let devices = (try? deviceStore.all()) ?? []
            pairedHosts = SyncDeviceList.hosts(in: devices)
            pairedHostCount = pairedHosts.count
        }

        private static func key(_ target: IOSPassiveSyncTarget) -> String {
            "\(target.peerID)|\(target.hostName)"
        }
    }

#endif
