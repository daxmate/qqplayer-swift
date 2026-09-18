//
//  SyncListenerTests.swift
//  QQPlayerTests
//
//  同步 Host 监听层的**纯参数 / 纯状态**测试（2026-09-19 补覆盖缺口 P2-3）：
//  - `SyncTCPParameters.make()`：noDelay 不变量（锁 2026-09-18 文件传输提速）
//  - `SyncConnectDiag.describe(_:)`：endpoint 四态可读（hostPort / service / unix / url）
//  - `SyncListener.stop()`：幂等（未监听 / 连调两次）
//  - `NWPeerChannel.closeTransport()`：关闭通知只发一次（`notifiedClosed` 语义）
//
//  **有意不测（试过，代码在历史提交里）**：`SyncConnectDiag.log()` 的 iOS 落盘与环形截断。
//  落点路径写死在 App 容器 `Documents/sync-diag.log`，且是全进程共享单文件——测试内
//  无法确定性观察：真机日志写入、其它同步套件并发写同一文件，都会让「刚写的那行就是
//  最后一行」「5s 内一定出现」这类断言偶发变红（实测两次：一次 hasSuffix 失败、
//  一次等待超时）。要稳定测它，得先给生产加一个可注入的日志路径 seam（另开一条），
//  在此之前**宁可不测，也不留 flaky 用例**（同仓库 `flaky-test-determinism` 口径）。
//
//  为什么这几条值钱：`SyncListener.swift:29-32` 注释记着**已发生过的失效形状**
//  ——「参数强转失败会静默返回 nil，看起来『设了』实际没设」。2026-09-18 的提速正踩
//  同一个坑（用户反馈「只传 3 首也要等一会儿」），此前没有任何测试锁 `noDelay == true`。
//  本文件就是那条不变量 + 同族纯逻辑的回归网。
//
//  **不测**（`SyncListener.swift:9-10` 已声明接受）：`accept(_:)` / Bonjour 广播 /
//  握手本体 —— 需真机验证，单测只覆盖不依赖真实连接的部分。
//

import Foundation
import Network
import Testing

@testable import QQPlayer

// MARK: - TCP 参数（提速不变量）

@Suite("SyncTCPParameters：同步链路 TCP 参数唯一入口")
struct SyncTCPParametersTests {
    /// 读回参数对象里的 TCP 槽位。
    ///
    /// `NWParameters` **没有实例级 `tcp` 属性**（`NWParameters.tcp` 是 class var，
    /// 表示「系统默认 TCP 参数」）——只能从 protocol stack 取 `transportProtocol`。
    /// 这也正是生产注释里说的坑：想读槽位只能强转，强转失败静默给 nil。
    private func tcpOptions(of parameters: NWParameters) -> NWProtocolTCP.Options? {
        parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options
    }

    /// 判断参数对象上是否挂了 TLS（`NWParameters` 同样**没有实例级 `tls` 属性**；
    /// 显式 `NWParameters(tls: nil, tcp:)` 与 `NWParameters(tls: Options(), tcp:)` 的
    /// 可观测差异就在 applicationProtocols 里有没有 `NWProtocolTLS.Options`）。
    private func hasTLS(_ parameters: NWParameters) -> Bool {
        parameters.defaultProtocolStack.applicationProtocols.contains { $0 is NWProtocolTLS.Options }
    }

    @Test("noDelay == true：停等协议每块一次 ack 往返，关 Nagle 是提速的前提（2026-09-18）")
    func noDelayIsEnabled() throws {
        let parameters = SyncTCPParameters.make()
        let tcp = try #require(tcpOptions(of: parameters), "参数对象上没有 TCP 槽位 → 等于没设")
        #expect(tcp.noDelay == true)
    }

    @Test("参数真的挂上去了：与系统默认 TCP 参数可区分（防「看起来设了实际没设」）")
    func noDelayIsActuallyAppliedNotSilentlyDropped() throws {
        let ours = try #require(tcpOptions(of: SyncTCPParameters.make()))
        let systemDefault = try #require(tcpOptions(of: NWParameters.tcp))

        #expect(ours.noDelay == true)
        // 反例对照：系统默认 noDelay = false。两者不同 → 本断言真的在测「有没有设」，
        // 而不是在测「NWParameters 的默认值恰好是什么」。
        #expect(systemDefault.noDelay == false)
    }

    @Test("tls 槽位为空：同步链路自带握手加密，不得叠上 TLS")
    func tlsIsNotInstalled() {
        #expect(hasTLS(SyncTCPParameters.make()) == false)
        // 反向对照：显式开 TLS 时同一判据必须能看见（否则本断言等于什么都没锁）。
        let withTLS = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
        #expect(hasTLS(withTLS) == true)
    }
}

// MARK: - endpoint 描述

@Suite("SyncConnectDiag.describe：endpoint 可读描述")
struct SyncConnectDiagDescribeTests {
    @Test("hostPort：主机 + 端口")
    func hostPort() {
        let output = SyncConnectDiag.describe(.hostPort(host: "10.0.0.7", port: 52_000))
        #expect(output == "hostPort(10.0.0.7:52000)")
    }

    @Test("hostPort：域名形式主机（Bonjour 解析后的常见形态）")
    func hostPortWithName() {
        let output = SyncConnectDiag.describe(.hostPort(host: "MacBook.local", port: 1))
        #expect(output == "hostPort(MacBook.local:1)")
    }

    @Test("service：name/type/domain 齐全，interface 为 nil 时显式写 nil（不省略）")
    func serviceWithoutInterface() {
        let output = SyncConnectDiag.describe(
            .service(name: "Mac", type: "_qqplayer-sync._tcp", domain: "local.", interface: nil)
        )
        #expect(output == "service(name=Mac type=_qqplayer-sync._tcp domain=local. if=nil)")
    }

    @Test("unix：socket 路径")
    func unix() {
        #expect(SyncConnectDiag.describe(.unix(path: "/tmp/qqp.sock")) == "unix(/tmp/qqp.sock)")
    }

    @Test("url：URL 形态")
    func url() throws {
        let endpoint = NWEndpoint.url(try #require(URL(string: "http://192.168.1.9:8080/path")))
        #expect(SyncConnectDiag.describe(endpoint) == "url(http://192.168.1.9:8080/path)")
    }

    @Test("四态输出非空且互不相同（诊断行不能退化成一堆空串）")
    func outputsAreDistinctAndReadable() {
        let outputs = [
            SyncConnectDiag.describe(.hostPort(host: "10.0.0.7", port: 52_000)),
            SyncConnectDiag.describe(
                .service(name: "Mac", type: "_qqplayer-sync._tcp", domain: "local.", interface: nil)
            ),
            SyncConnectDiag.describe(.unix(path: "/tmp/qqp.sock")),
            SyncConnectDiag.describe(.url(URL(string: "http://192.168.1.9:8080/path")!)),
        ]
        #expect(outputs.allSatisfy { !$0.isEmpty })
        #expect(Set(outputs).count == outputs.count)
    }
}

// MARK: - 监听器生命周期

@Suite("SyncListener：生命周期纯状态（不碰 Bonjour/NWListener）")
struct SyncListenerLifecycleTests {
    private func makeListener() -> SyncListener {
        SyncListener(
            localIdentity: SyncIdentity.generate(),
            trustStore: MemoryTrustStore(),
            deviceName: "测试 Mac"
        )
    }

    @Test("stop() 幂等：未启动时连调两次不崩，isRunning 恒 false")
    func stopIsIdempotentWhenNeverStarted() {
        let listener = makeListener()
        #expect(listener.isRunning == false)

        listener.stop()
        #expect(listener.isRunning == false)

        listener.stop()
        #expect(listener.isRunning == false)
    }
}

// MARK: - 通道关闭幂等

@Suite("NWPeerChannel：关闭通知只发一次")
struct NWPeerChannelCloseTests {
    /// 只构造不 start 的 NWConnection（不产生任何真实连接），
    /// 足以走通 `closeTransport()` 的幂等收尾路径。
    private func makeChannel(queue: DispatchQueue) -> NWPeerChannel {
        let connection = NWConnection(host: "127.0.0.1", port: 9, using: SyncTCPParameters.make())
        return NWPeerChannel(connection: connection, queue: queue)
    }

    /// 回调来自通道串行队列，用锁保护的盒子收集（不直接捕获局部 var）。
    private final class StateRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var states: [NWConnection.State] = []

        func record(_ state: NWConnection.State) {
            lock.lock()
            defer { lock.unlock() }
            states.append(state)
        }

        var observed: [NWConnection.State] {
            lock.lock()
            defer { lock.unlock() }
            return states
        }
    }

    @Test("closeTransport() 连调两次 → onStateUpdate(.cancelled) 恰好一次")
    func closeNotifiesCancelledExactlyOnce() {
        let queue = DispatchQueue(label: "com.daxmate.qqplayer.tests.nwpeerchannel")
        let channel = makeChannel(queue: queue)
        let recorder = StateRecorder()
        channel.onStateUpdate = { recorder.record($0) }

        channel.closeTransport()
        channel.closeTransport()
        queue.sync {} // 排空通道串行队列：两次关闭都已执行完

        let observed = recorder.observed
        let cancelledCount = observed.filter {
            if case .cancelled = $0 { return true }
            return false
        }.count
        #expect(cancelledCount == 1, "重复通知会让 UI 设备列表把已关会话当新事件处理")
        #expect(observed.count == 1)
    }
}
