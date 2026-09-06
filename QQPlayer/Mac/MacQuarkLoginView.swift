//
//  MacQuarkLoginView.swift
//  QQPlayer
//
//  夸克网盘扫码登录 sheet（web 版 QuarkLoginModal.vue 语义对齐，E2 批2b；
//  QQPlayerMac target only）。歌曲海下载遇到未登录（downloadInfo 401）时由
//  MacOnlineSearchView 弹此面板。
//
//  语义（逐条对齐 QuarkLoginModal.vue）：
//  - 打开即 QuarkClient().loginQRCode() → 二维码内容直接是 weblogin URL 字符串
//    （QuarkQRCode.contentURL，无需再组装）→ CIFilter CIQRCodeGenerator 生成展示
//  - 2s 轮询 loginStatus（QuarkClient 单次查询；本视图负责循环）：waiting 继续 /
//    ok → 自动关面板回调 onLoggedIn(nickname) / expired → 显示刷新按钮 /
//    error → 显示重试按钮（web 用通用文案，具体原因打日志）
//  - 倒计时秒数来自 expiresIn（web DEFAULT_TTL 同语义）；归零 = 过期态
//  - 视图消失/关闭即取消轮询与倒计时（Task cancel）
//  - 登录成功时 QuarkClient 已把会话 Cookie 持久化到文件，后续 GequhaiClient/
//    QuarkClient 请求自动带上（cookie 归文件管，实例间互通）
//

import AppKit
import CoreImage
import SwiftUI

/// 夸克扫码登录面板（sheet 形态，参照 web QuarkLoginModal.vue）
struct MacQuarkLoginView: View {
    /// App 强调色（macOS 上 Color.accentColor 跟随系统而非 App tint，统一读环境值）
    @Environment(\.appAccentColor) private var appAccentColor
    @Environment(\.dismiss) private var dismiss

    /// 登录成功回调（nickname 可能为空）
    let onLoggedIn: (String?) -> Void

    private let quarkClient = QuarkClient()

    @State private var phase: Phase = .fetching
    @State private var qrImage: NSImage?
    @State private var secondsLeft = 0
    @State private var pollTask: Task<Void, Never>?
    @State private var tickTask: Task<Void, Never>?

    /// 面板状态机（web QuarkLoginModal 状态语义收敛：拉码中/等待扫码/过期/异常）
    private enum Phase {
        case fetching          // 拉码中（转圈占位）
        case waiting           // 等待扫码：展示二维码 + 倒计时
        case expired           // 二维码已过期：刷新按钮重拉
        case failed            // 拉码/轮询异常：重试按钮
    }

    private static let pollInterval: TimeInterval = 2   // web POLL_MS = 2000

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(spacing: 10) {
                qrArea
                Text("quark_login_scan_hint".localized)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                statusArea
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .frame(width: 320)
        .onAppear {
            fetchQRCode()
        }
        .onDisappear {
            cancelTimers()
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "qrcode")
                .foregroundColor(appAccentColor)
            Text("quark_login_title".localized)
                .font(.headline)
            Spacer()
            Button {
                cancelTimers()
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("close".localized)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    // MARK: - 二维码区

    @ViewBuilder
    private var qrArea: some View {
        Group {
            switch phase {
            case .fetching:
                ProgressView()
            case .waiting:
                if let qrImage {
                    Image(nsImage: qrImage)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: 190, height: 190)
                } else {
                    ProgressView()
                }
            case .expired:
                statusIcon("clock.badge.exclamationmark", tint: .orange)
            case .failed:
                statusIcon("exclamationmark.triangle", tint: .red)
            }
        }
        .frame(width: 190, height: 190)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(0.25), lineWidth: 1)
        }
    }

    private func statusIcon(_ systemName: String, tint: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemName)
                .font(.system(size: 30))
                .foregroundColor(tint)
        }
    }

    // MARK: - 状态文案区

    @ViewBuilder
    private var statusArea: some View {
        switch phase {
        case .waiting:
            // 倒计时（≤30s 转橙色提醒，web countdown.warn 语义）
            Text("quark_login_countdown".localized(with: secondsLeft))
                .font(.caption)
                .foregroundColor(secondsLeft <= 30 ? .orange : Color.secondary)
                .monospacedDigit()
        case .expired:
            VStack(spacing: 8) {
                Text("quark_login_expired".localized)
                    .font(.callout)
                    .foregroundColor(.secondary)
                Button("quark_login_refresh".localized) {
                    fetchQRCode()
                }
            }
        case .failed:
            VStack(spacing: 8) {
                Text("quark_login_error".localized)
                    .font(.callout)
                    .foregroundColor(.secondary)
                Button("retry".localized) {
                    fetchQRCode()
                }
            }
        case .fetching:
            EmptyView()
        }
    }

    // MARK: - 拉码 / 轮询 / 倒计时

    /// 拉新二维码（首次打开 / 过期刷新 / 错误重试共用）：取消旧任务 → 拉码 →
    /// 生成展示 → 启动 2s 轮询 + 1s 倒计时。已在等待扫码且有活动轮询时幂等跳过
    /// （防 onAppear 重复触发打断扫码）。
    private func fetchQRCode() {
        if case .waiting = phase, pollTask != nil {
            return
        }
        cancelTimers()
        phase = .fetching
        qrImage = nil
        let qr = quarkClient
        Task {
            do {
                let code = try await qr.loginQRCode()
                guard !Task.isCancelled else { return }
                phase = .waiting
                secondsLeft = code.expiresIn
                qrImage = Self.makeQRImage(content: code.contentURL)
                startPolling(qrID: code.qrID)
                startCountdown()
            } catch {
                guard !Task.isCancelled else { return }
                print("❌ [夸克扫码登录] 拉取二维码失败: \(error)")
                phase = .failed
            }
        }
    }

    /// 2s 轮询扫码状态（web POLL_MS 对齐；单次查询语义在 QuarkClient）
    private func startPolling(qrID: String) {
        pollTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
                    let status = try await quarkClient.loginStatus(qrID: qrID)
                    guard !Task.isCancelled else { return }
                    switch status.state {
                    case .ok:
                        cancelTimers()
                        onLoggedIn(status.nickname)
                        dismiss()
                        return
                    case .expired:
                        cancelTimers()
                        phase = .expired
                        return
                    case .error:
                        print("❌ [夸克扫码登录] 轮询异常: \(status.message ?? "")")
                        cancelTimers()
                        phase = .failed
                        return
                    case .waiting:
                        continue
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    print("❌ [夸克扫码登录] 轮询请求失败: \(error)")
                    cancelTimers()
                    phase = .failed
                    return
                }
            }
        }
    }

    /// 1s 倒计时（web countdownTimer 语义）；归零 → 过期态（等用户点刷新重拉）
    private func startCountdown() {
        tickTask = Task {
            while !Task.isCancelled && secondsLeft > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                secondsLeft -= 1
                if secondsLeft <= 0 {
                    cancelTimers()
                    phase = .expired
                    return
                }
            }
        }
    }

    private func cancelTimers() {
        pollTask?.cancel()
        pollTask = nil
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: - 二维码生成（CIFilter，macOS 内置）

    /// 内容字符串 → 二维码 NSImage。白底 + 整数倍放大（CIQRCodeGenerator 输出
    /// 是内容长度决定的版本尺寸，整数倍缩放保持模块均匀），黑块锐利无锯齿。
    private static func makeQRImage(content: String, minPixels: CGFloat = 360) -> NSImage? {
        guard let data = content.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ciImage = filter.outputImage else { return nil }

        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = max(1, ceil(minPixels / max(extent.width, extent.height)))
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let outputSize = NSSize(width: extent.width * scale, height: extent.height * scale)

        // 经典 lockFocus 绘制：白底 + 整数倍缩放后的二维码（坐标/翻转由 AppKit
        // 统一处理，避免裸 CGContext 绘制的翻转歧义）
        let image = NSImage(size: outputSize)
        image.lockFocus()
        defer { image.unlockFocus() }
        NSColor.white.setFill()
        NSRect(origin: .zero, size: outputSize).fill()
        let ciContext = CIContext(options: [.useSoftwareRenderer: true])
        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        let drawn = NSImage(cgImage: cgImage, size: outputSize)
        NSGraphicsContext.current?.imageInterpolation = .none
        drawn.draw(
            in: NSRect(origin: .zero, size: outputSize),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        return image
    }
}
