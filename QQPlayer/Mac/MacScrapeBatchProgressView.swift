//
//  MacScrapeBatchProgressView.swift
//  QQPlayer
//
//  批量刮削进度 sheet（两入口复用：曲库右键多选 paths 模式 / 设置「刮削」里
//  library 模式，E1 刮削批 2026-09）。跑批用 ScrapeBatchService.runBatch 固定签名。
//
//  布局：模式说明（paths 刮选中文件 / library 整库补 year+genre）+ 逐首结果
//  滚动列表（文件名 + written 写成的字段 / skipped、failed + reason）+ 进度计数
//  （batch_running + 进度条）+ 取消（running 中）+ 汇总（written/skipped/failed
//  计数 + truncated「仅前 100 首」提示）。
//
//  - batchEnabled=false 时 sheet 内显示未开启提示（batch_disabled_hint），不调
//    runBatch（服务层另有 .disabled 双保险）
//  - progress 回调在后台 executor 触发 → hop 回 MainActor 再落表（Task 入队 FIFO
//    保序；收尾再等队列排空，避免汇总先于最后几行出现）
//  - 取消/关闭 sheet（含 Esc）→ .task 自动取消 → runBatch 在检查点抛
//    CancellationError → 静默退出，不展示错误
//  - 批量写完后 runBatch 统一发 LibraryFolderContentChanged（列表/曲库刷新）
//
//  QQPlayerMac target only。
//

import SwiftUI

struct MacScrapeBatchProgressView: View {
    /// paths 模式：目标文件绝对路径数组；library 模式传 []（runBatch 自查库）
    let paths: [String]
    /// true = 一键整库（设置入口）；false = 右键多选（曲库入口）
    let libraryMode: Bool

    @Environment(\.appAccentColor) private var appAccentColor
    @Environment(\.dismiss) private var dismiss

    /// sheet 状态机（starting 一闪而过 → disabled/running → finished/failed）
    private enum Phase {
        case starting
        case disabled
        case running
        case finished
        case failed(String)
    }

    @State private var phase: Phase = .starting
    /// 逐首结果（progress 回调 hop 落表，顺序 = 处理顺序）
    @State private var results: [ScrapeBatchResult] = []
    /// 本批计划总数（上限 100；library 模式按库中待补曲目预估）
    @State private var plannedTotal = 0
    /// 目标超过 100 首被截断（收尾提示「仅前 100 首」）
    @State private var truncated = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 500)
        .task { await run() }
    }

    // MARK: - Header（标题 + 模式说明）

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: libraryMode ? "books.vertical" : "tag")
                .font(.system(size: 15))
                .foregroundColor(appAccentColor)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(libraryMode ? "scraping_batch_run_library".localized : "context_batch_scrape".localized)
                    .font(.headline)
                Text(libraryMode ? "batch_mode_library".localized : "batch_mode_paths".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if case .running = phase {
                Button {
                    dismiss() // 关闭 → onDisappear → .task 取消 → runBatch 停止
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("batch_cancel_help".localized)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Content（逐首结果列表 / 提示态）

    @ViewBuilder
    private var content: some View {
        if case .disabled = phase {
            hintPane(
                icon: "tag.slash",
                text: "batch_disabled_hint".localized,
                color: .secondary
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(results, id: \.path) { result in
                        resultRow(result)
                    }
                }
                .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func hintPane(icon: String, text: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundColor(color)
            Text(text)
                .font(.callout)
                .foregroundColor(color)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func resultRow(_ result: ScrapeBatchResult) -> some View {
        HStack(alignment: .top, spacing: 8) {
            statusIcon(result.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: result.path).lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(statusDetail(result))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(Color.gray.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }

    private func statusIcon(_ status: String) -> some View {
        let color: Color
        let icon: String
        switch status {
        case "written":
            color = .green
            icon = "checkmark.circle.fill"
        case "skipped":
            color = .orange
            icon = "minus.circle.fill"
        default:
            color = .red
            icon = "xmark.circle.fill"
        }
        return Image(systemName: icon)
            .foregroundColor(color)
            .font(.system(size: 13))
            .padding(.top, 1)
    }

    /// written → 写成的字段（本地化字段名）；skipped/failed → reason（web 同文案）
    private func statusDetail(_ result: ScrapeBatchResult) -> String {
        if result.status == "written" {
            let names = result.writtenFields.map { fieldLocalizedName($0) }
            return names.joined(separator: " · ")
        }
        return result.reason.isEmpty ? "—" : result.reason
    }

    private func fieldLocalizedName(_ field: String) -> String {
        switch field {
        case "title": return "title".localized
        case "artist": return "artist".localized
        case "album": return "album".localized
        case "year": return "tag_editor_field_year".localized
        case "genre": return "tag_editor_field_genre".localized
        default: return field
        }
    }

    // MARK: - Footer（进度+取消 / 汇总+完成 / 提示态关闭）

    @ViewBuilder
    private var footer: some View {
        switch phase {
        case .running:
            HStack(spacing: 10) {
                Text("batch_running".localized(with: plannedTotal))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                ProgressView(value: Double(results.count), total: Double(max(plannedTotal, 1)))
                    .frame(width: 130)
                Text("\(results.count) / \(plannedTotal)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                Spacer()
                Button("cancel".localized) {
                    dismiss() // 关闭 → .task 取消 → runBatch 停止
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        case .finished:
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    summaryLine
                    if truncated {
                        Text("batch_truncated".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Button("done".localized) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        case .failed(let message):
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
                Spacer()
                Button("done".localized) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        default:
            // starting / disabled：只留一个关闭按钮
            HStack {
                Spacer()
                Button("done".localized) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    /// 汇总行（文案来自 batch_summary，参数顺序 written/skipped/failed）
    private var summaryLine: some View {
        let written = results.filter { $0.status == "written" }.count
        let skipped = results.filter { $0.status == "skipped" }.count
        let failed = results.filter { $0.status == "failed" }.count
        return HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            Text("batch_summary".localized(with: written, skipped, failed))
                .font(.callout)
                .fontWeight(.medium)
        }
    }

    // MARK: - 执行

    /// 打开即自动开始（batchEnabled=false → 提示态，不调 runBatch）。
    /// .task 随视图消失自动取消 → runBatch 检查点抛 CancellationError。
    @MainActor
    private func run() async {
        // 双保险：设置关 → 提示不跑（服务层 .disabled 兜底，这里直接不进 runBatch）
        guard DeleteSettings.load().scrapingBatchEnabled else {
            phase = .disabled
            return
        }

        let files = paths
        let library = libraryMode
        // 计划总数（上限 100；library 模式按当前库待补曲目预估——runBatch 内部
        // 会再查一次，进度条总量只是展示用）
        plannedTotal = min(
            await estimatedTargetCount(files: files, libraryMode: library),
            ScrapeLogic.batchLimit
        )
        // 无目标 → 直接空汇总（跳过无意义的空跑）
        guard plannedTotal > 0 else {
            phase = .finished
            return
        }

        phase = .running
        do {
            let returned = try await ScrapeBatchService.runBatch(
                paths: files,
                libraryMode: library,
                batchEnabled: true
            ) { result in
                // progress 回调在后台 executor → hop 回 MainActor 落表
                Task { @MainActor in
                    results.append(result)
                }
            }
            guard !Task.isCancelled else { return }
            // 等最后一批 hop 落表（Task 入队 FIFO；runBatch 返回前全部入队完毕）
            while results.count < returned.results.count {
                await Task.yield()
            }
            guard !Task.isCancelled else { return }
            // 以返回值为准整体落表（与流式追加一致，杜绝竞态缺行）
            results = returned.results
            truncated = returned.truncated
            phase = .finished
        } catch {
            // 取消（用户点取消/关闭/Esc）→ 静默退出，不展示错误
            guard !Task.isCancelled else { return }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .failed(message)
        }
    }

    private func estimatedTargetCount(files: [String], libraryMode: Bool) async -> Int {
        if libraryMode {
            return (try? DatabaseManager.shared.getTracksMissingYearOrGenre().count) ?? 0
        }
        return files.count
    }
}
