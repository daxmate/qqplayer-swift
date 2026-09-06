//
//  MacScrapeSettingsView.swift
//  QQPlayer
//
//  设置「刮削」分类面板（web ScrapeSettingsPanel.vue 子集移植，E1 刮削批 2026-09）：
//  - 重命名模板：文本输入 + 占位符提示（{artist}/{title}/{album}/{track}/{year}，
//    '/' = 子目录）+ 实时预览（取库中首曲渲染，web renamePreview 语义）
//  - 源优先级：netease/musicbrainz 上下移排序（持久化 scrapingSourceOrder）
//  - 批量刮削开关：batch_enabled 默认关（关时仅开关+解释）；开 → 显示
//    「一键补全整库 year+genre」按钮 + 限流说明，点击弹批量进度 sheet
//    （MacScrapeBatchProgressView library 模式）
//  - 存储：DeleteSettings scraping namespace（renameTemplate/sourceOrder/
//    batchEnabled），改动即 save() → .qqplayerSettingsDidChange 双向同步
//  - 本地化 key ×5（en/zh-Hans/zh-Hant/fr/ru）
//
//  QQPlayerMac target only。
//

import SwiftUI

struct MacScrapeSettingsView: View {
    /// App 强调色（macOS 上 Color.accentColor 跟随系统而非 App tint，统一读环境值）
    @Environment(\.appAccentColor) private var appAccentColor
    @State private var deleteSettings = DeleteSettings.load()
    @State private var showBatchProgress = false
    /// 重命名模板实时预览（库中首曲渲染；无示例曲目/渲染为空 → "—"）
    @State private var renamePreview = "—"

    var body: some View {
        Form {
            // 重命名模板（web「重命名规则」组：输入 + 占位符提示 + 实时预览）
            Section {
                TextField("", text: renameTemplateBinding, prompt: Text("{artist} - {title}"))
                    .textFieldStyle(.roundedBorder)
                Text("scraping_rename_template_hint".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Text("scraping_rename_preview".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(renamePreview)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(appAccentColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            } header: {
                Text("scraping_rename_template".localized)
            }

            // 源优先级（web「源优先级」组：netease/musicbrainz 上下移）
            Section {
                ForEach(Array(deleteSettings.scrapingSourceOrder.enumerated()), id: \.element) { index, source in
                    HStack(spacing: 10) {
                        Text(sourceDisplayName(source))
                            .font(.callout)
                        Spacer()
                        Text("\(index + 1)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1)
                            .background(Color.gray.opacity(0.15), in: Capsule())
                        moveButton(source: source, index: index, offset: -1, systemImage: "chevron.up")
                        moveButton(source: source, index: index, offset: 1, systemImage: "chevron.down")
                    }
                }
            } header: {
                Text("scraping_source_order".localized)
            }

            // 批量刮削（web「批量刮削」组：开关默认关 + 开启后一键整库按钮）
            Section {
                Toggle("scraping_batch_enabled".localized, isOn: batchEnabledBinding)
                if deleteSettings.scrapingBatchEnabled {
                    Button {
                        showBatchProgress = true
                    } label: {
                        Label("scraping_batch_run_library".localized, systemImage: "sparkles")
                    }
                    Text("scraping_batch_until".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } footer: {
                Text("scraping_batch_enabled_hint".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshRenamePreview()
        }
        // 与 MacLibraryView 双向同步：任何一处写入 DeleteSettings 都会发
        // .qqplayerSettingsDidChange，这里重读（模板预览随之刷新）
        .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
            deleteSettings = DeleteSettings.load()
            refreshRenamePreview()
        }
        .sheet(isPresented: $showBatchProgress) {
            MacScrapeBatchProgressView(paths: [], libraryMode: true)
        }
    }

    // MARK: - 重命名模板（改动即保存）

    private var renameTemplateBinding: Binding<String> {
        Binding(
            get: { deleteSettings.scrapingRenameTemplate },
            set: { newValue in
                var settings = deleteSettings
                settings.scrapingRenameTemplate = newValue
                settings.save()
                deleteSettings = settings
                refreshRenamePreview()
            }
        )
    }

    /// 实时预览：取库中首曲（artist+title 非空）按模板渲染（web renamePreview：
    /// 无示例曲目 / 渲染为空 → "—"）
    private func refreshRenamePreview() {
        guard let sample = firstSampleTrack() else {
            renamePreview = "—"
            return
        }
        let rendered = TagRenameLogic.renderFileName(
            template: deleteSettings.scrapingRenameTemplate,
            values: sample.values,
            ext: sample.ext
        )
        renamePreview = (rendered?.isEmpty == false) ? rendered! : "—"
    }

    private func firstSampleTrack() -> (values: TagRenameLogic.Values, ext: String)? {
        guard let tracks = try? DatabaseManager.shared.getAllTracks() else { return nil }
        for track in tracks {
            let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let artistName = (try? DatabaseManager.shared.getArtistDisplayName(
                forTrackStableId: track.stableId,
                fallbackArtistId: track.artistId
            )) ?? ""
            guard !artistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var albumTitle: String?
            var year: Int?
            if let albumId = track.albumId,
               let album = try? DatabaseManager.shared.getAlbum(byId: albumId) {
                albumTitle = album.title
                year = album.year
            }
            let ext = URL(fileURLWithPath: track.path).pathExtension
            return (
                TagRenameLogic.Values(
                    artist: artistName,
                    title: title,
                    album: albumTitle,
                    track: track.trackNo,
                    year: year
                ),
                ext.isEmpty ? "" : "." + ext
            )
        }
        return nil
    }

    // MARK: - 源优先级（上下移，持久化 scrapingSourceOrder）

    private var batchEnabledBinding: Binding<Bool> {
        Binding(
            get: { deleteSettings.scrapingBatchEnabled },
            set: { newValue in
                var settings = deleteSettings
                settings.scrapingBatchEnabled = newValue
                settings.save()
                deleteSettings = settings
            }
        )
    }

    private func sourceDisplayName(_ source: String) -> String {
        switch source {
        case "netease": return "source_netease".localized
        case "musicbrainz": return "source_musicbrainz".localized
        default: return source
        }
    }

    private func moveButton(source: String, index: Int, offset: Int, systemImage: String) -> some View {
        let target = index + offset
        let order = deleteSettings.scrapingSourceOrder
        return Button {
            moveSource(at: index, by: offset)
        } label: {
            Image(systemName: systemImage)
        }
        .buttonStyle(.borderless)
        .disabled(target < 0 || target >= order.count || order[target] == source)
    }

    private func moveSource(at index: Int, by offset: Int) {
        let target = index + offset
        guard deleteSettings.scrapingSourceOrder.indices.contains(index),
              deleteSettings.scrapingSourceOrder.indices.contains(target) else { return }
        var order = deleteSettings.scrapingSourceOrder
        order.swapAt(index, target)
        var settings = deleteSettings
        settings.scrapingSourceOrder = order
        settings.save()
        deleteSettings = settings
    }
}

#Preview {
    MacScrapeSettingsView()
}
