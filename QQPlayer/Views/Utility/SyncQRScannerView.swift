//
//  SyncQRScannerView.swift
//  QQPlayer
//
//  局域网同步（S2, M1-UI）iOS 扫码配对页：
//  1. AVCaptureSession 扫 Host 二维码 → 文本 → SyncPairingFlow.qrEvent
//     组装事件 → PairingStateMachine.handle（协议版本/ID/公钥/指纹/一次性
//     nonce 校验全在机器内，失败展示 failed 原因）
//  2. awaitingConfirmation → SyncPairConfirmCardView 确认页 → 用户确认
//     userConfirmedOnClient → approved → 本端落库 host 记录（publicKey 有值，
//     直接 DeviceStore.upsert role=.host）
//  3. 主机侧批准在 M2a 网络握手前无法发生：本页到 client approved + 本地
//     落库即止，成功文案不承诺双向配对完成。
//
//  状态机实例由本页持有（每进入一次扫描 = 一次配对流程）；nonce 过期由
//  expireCheck 驱动（页面停留期间展示 awaiting 超时提示由 M2a 补计时器，
//  本里程碑 expired 态仅经确认时机器内建检查可达——保持机器事件面完整）。
//

import AVFoundation
import SwiftUI

/// iOS 扫码配对页。
struct SyncQRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = SyncScannerController()
    @State private var machine = PairingStateMachine()
    @State private var flow: SyncScanFlow = .scanning
    @State private var processing = false
    private let deviceStore = DeviceStore()

    var body: some View {
        Group {
            switch flow {
            case .scanning:
                scanningBody
            case let .awaitingConfirm(candidate):
                confirmBody(candidate)
            case let .outcome(outcome):
                SyncPairOutcomeView(
                    symbol: outcome.symbol,
                    title: outcome.title,
                    message: outcome.message,
                    actionTitle: outcome.actionTitle,
                    onAction: { handleOutcomeAction(outcome) },
                    symbolColor: outcome.symbolColor
                )
            }
        }
        .navigationTitle("sync_scan_qr".localized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(Localized.done) { dismiss() }
            }
        }
        .onAppear {
            controller.onCode = { text in handleScanned(text) }
            controller.start()
        }
        .onDisappear {
            controller.stop()
        }
    }

    // MARK: - 扫描态

    private var scanningBody: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                SyncCameraPreview(session: controller.session)
                    .ignoresSafeArea()
                if controller.denied {
                    cameraDeniedOverlay
                } else if !controller.isRunning {
                    ProgressView()
                        .tint(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 340)

            VStack(alignment: .leading, spacing: 10) {
                Label("sync_scan_hint".localized, systemImage: "qrcode.viewfinder")
                    .font(.callout)
                Text("sync_scan_subhint".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
    }

    private var cameraDeniedOverlay: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.fill")
                .font(.system(size: 36))
                .foregroundStyle(.white.opacity(0.9))
            Text("sync_camera_denied".localized)
                .font(.callout)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("sync_open_settings".localized) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
            .tint(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.75))
    }

    // MARK: - 确认态

    private func confirmBody(_ candidate: PeerCandidate) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("sync_confirm_pair_title".localized)
                    .font(.headline)
                SyncPairConfirmCardView(
                    candidate: candidate,
                    awaitingPublicKey: false,
                    onConfirm: { confirm(candidate) },
                    onCancel: { cancelAndRescan() }
                )
            }
            .padding(16)
        }
    }

    // MARK: - 动作

    /// 扫到文本：解析 → 状态机 → 呈现（awaiting 卡 / failed 原因）。
    @MainActor
    private func handleScanned(_ text: String) {
        guard !processing else { return }
        processing = true
        controller.pause()

        do {
            let payload = try SyncQRCodec.decode(text)
            let alreadyPaired = (try? deviceStore.byPeerID(payload.deviceID)) != nil
            machine.handle(.receivedQR(payload, at: Date().timeIntervalSince1970, alreadyPaired: alreadyPaired))
        } catch {
            flow = .outcome(.invalidQRCode)
            return
        }

        switch machine.state {
        case let .awaitingConfirmation(candidate):
            flow = .awaitingConfirm(candidate)
        case let .failed(failure):
            flow = .outcome(.failed(failure))
        default:
            flow = .outcome(.invalidQRCode)
        }
    }

    /// 用户确认 → approved → 本地落库 host（本端信任建立；主机侧批准待 M2a）。
    @MainActor
    private func confirm(_ candidate: PeerCandidate) {
        machine.handle(.userConfirmedOnClient(at: Date().timeIntervalSince1970))
        guard case let .approved(approved) = machine.state else {
            if case let .expired(expired) = machine.state {
                flow = .outcome(.expired(expired.displayName))
            }
            return
        }
        let device = PeerDevice(
            candidate: approved,
            role: .host,
            pairedAt: Int64(Date().timeIntervalSince1970)
        )
        do {
            try deviceStore.upsert(device)
            flow = .outcome(.addedAwaitingHost(name: approved.displayName))
        } catch {
            flow = .outcome(.storeFailed(error.localizedDescription))
        }
    }

    @MainActor
    private func cancelAndRescan() {
        machine.handle(.cancel)
        resetToScan()
    }

    @MainActor
    private func handleOutcomeAction(_ outcome: SyncPairOutcome) {
        switch outcome {
        case .addedAwaitingHost, .manualApprovedAwaitingHost, .storeFailed:
            dismiss()
        case .invalidQRCode, .failed, .expired:
            resetToScan()
        }
    }

    @MainActor
    private func resetToScan() {
        machine = PairingStateMachine()
        flow = .scanning
        processing = false
        controller.resume()
    }
}

// MARK: - 页面流程状态

/// 扫码页流程（驱动 UI 呈现；状态机是真源，此处为视图快照）。
enum SyncScanFlow: Equatable {
    case scanning
    case awaitingConfirm(PeerCandidate)
    case outcome(SyncPairOutcome)
}

/// 扫码/手输配对结果（成功/失败原因，均已本地化好文案的展示值）。
/// 扫码与手输两页共用；区分「已落库待主机批准」与「手输待连接补全」。
enum SyncPairOutcome: Equatable {
    /// 扫码 approved：已落库 host 记录，等待主机侧批准（M2a）
    case addedAwaitingHost(name: String)
    /// 手输 approved：无公钥未落库，等待主机批准 + 首次连接补全公钥（M2）
    case manualApprovedAwaitingHost(name: String)
    case invalidQRCode
    case failed(PairingFailure)
    case expired(String)
    case storeFailed(String)

    var symbol: String {
        switch self {
        case .addedAwaitingHost, .manualApprovedAwaitingHost: return "checkmark.circle.fill"
        case .invalidQRCode, .storeFailed: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        case .expired: return "clock.badge.xmark"
        }
    }

    var symbolColor: Color {
        switch self {
        case .addedAwaitingHost, .manualApprovedAwaitingHost: return .green
        case .invalidQRCode, .storeFailed, .expired: return .orange
        case .failed: return .red
        }
    }

    var title: String {
        switch self {
        case .addedAwaitingHost, .manualApprovedAwaitingHost: return "sync_added_title".localized
        case .invalidQRCode: return "sync_scan_failed_title".localized
        case let .failed(failure): return failure.localizedKey.localized
        case .expired: return "sync_expired_title".localized
        case .storeFailed: return "sync_store_failed_title".localized
        }
    }

    var message: String {
        switch self {
        case let .addedAwaitingHost(name):
            // 明确不承诺双向完成：主机侧批准需 M2a 连接后由主机用户确认
            return "sync_added_awaiting_host".localized(with: name)
        case let .manualApprovedAwaitingHost(name):
            return "sync_manual_added_awaiting_host".localized(with: name)
        case .invalidQRCode:
            return "sync_invalid_qr_message".localized
        case let .failed(failure):
            return failure.localizedKey.localized
        case .expired:
            return "sync_expired_message".localized
        case let .storeFailed(detail):
            return detail
        }
    }

    var actionTitle: String? {
        switch self {
        case .addedAwaitingHost, .manualApprovedAwaitingHost, .storeFailed: return Localized.done
        case .invalidQRCode, .failed, .expired: return "sync_scan_again".localized
        }
    }
}

// MARK: - 相机控制器

/// 相机权限 + AVCaptureSession 生命周期（delegate 回调任意线程 → 主线程上抛）。
/// 整个控制器主线程隔离：session 配置/@Published 状态只在 MainActor 触碰。
@MainActor
final class SyncScannerController: NSObject, ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var denied = false

    /// 扫到二维码文本（主线程回调）
    var onCode: (@MainActor (String) -> Void)?

    let session = AVCaptureSession()
    private let metadataQueue = DispatchQueue(label: "sync.scanner.metadata")

    /// 启动相机（主线程调用）。未授权时先请求；拒绝则展示引导。
    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.configureAndRun()
                    } else {
                        self.denied = true
                    }
                }
            }
        default:
            denied = true
        }
    }

    /// 暂停（扫到码/确认页）；暂停期间预览冻结。
    func pause() {
        guard session.isRunning else { return }
        session.stopRunning()
        isRunning = false
    }

    /// 恢复扫描。
    func resume() {
        guard !session.isRunning, !denied else { return }
        session.startRunning()
        isRunning = session.isRunning
    }

    func stop() {
        onCode = nil
        pause()
    }

    private func configureAndRun() {
        guard session.inputs.isEmpty else {
            resume()
            return
        }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else {
            denied = true
            return
        }
        guard session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: metadataQueue)
        if output.availableMetadataObjectTypes.contains(.qr) {
            output.metadataObjectTypes = [.qr]
        }
        resume()
    }
}

extension SyncScannerController: AVCaptureMetadataOutputObjectsDelegate {
    /// 回调在 metadataQueue（任意线程）：只取码值，主线程上抛。
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue
        else { return }
        Task { @MainActor [weak self] in
            self?.onCode?(value)
        }
    }
}

// MARK: - 相机预览

/// AVCaptureVideoPreviewLayer 桥接。
struct SyncCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> SyncPreviewView {
        let view = SyncPreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: SyncPreviewView, context: Context) {}
}

final class SyncPreviewView: UIView {
    override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
