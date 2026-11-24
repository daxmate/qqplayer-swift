//
//  MacTrackDetailSheet.swift
//  QQPlayer
//
//  macOS 曲目「歌曲详情」sheet（2026-11-16，用户拍板）。
//
//  QQPlayerMac target only（见 project.pbxproj 成员例外表）。
//
//  设计约束：
//  - **只读**；不写库、不改标签。
//  - 数据组装唯一入口 = MacTrackDetailModel（Services/MacTrackDetailModel.swift，双 target
//    共享、可在 iOS 测试 target 单测）。本视图只做呈现 + 本地化兜底。
//  - 封面走 MacArtworkThumbnail（既有封面加载唯一入口），不新写解码。
//  - 「编辑标签 / 去刮削」直接呈现既有 MacTagEditorView（复用其刮削 + 保存逻辑，不复制）。
//  - 刮削来源 / 匹配状态 / 最后刮削时间：本批不展示（无 DB 列，用户拍板方案 A，不做迁移）。
//

import SwiftUI

struct MacTrackDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    let track: Track
    @State private var model: MacTrackDetailModel
    @State private var showTagEditor = false

    @MainActor
    init(track: Track) {
        self.track = track
        _model = State(initialValue: MacTrackDetailModel(track: track))
    }

    var body: some View {
        VStack(spacing: DesignTokens.space0) {
            header
            Divider()
            Form {
                scrapedSection
                fileSection
                playbackSection
            }
            .formStyle(.grouped)
            .macSheetGlassListBackground()
        }
        .frame(width: 560, height: 640)
        .macSheetGlass()
        .task { await model.load() }
        .sheet(isPresented: $showTagEditor) {
            MacTagEditorView(track: track)
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: DesignTokens.space12) {
            MacArtworkThumbnail(track: track, size: 76, cornerRadius: DesignTokens.radius8)

            VStack(alignment: .leading, spacing: DesignTokens.space4) {
                Text(track.displayTitle)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text(model.snapshot.artistName ?? "track_detail_unknown".localized)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: DesignTokens.space8) {
                    if let album = model.snapshot.albumTitle, !album.isEmpty {
                        Text(album)
                    } else {
                        Text("track_detail_not_scraped".localized)
                            .foregroundStyle(.tertiary)
                    }
                    if let year = model.snapshot.year {
                        Text(String(year))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: DesignTokens.space8)

            VStack(alignment: .trailing, spacing: DesignTokens.space8) {
                Button("track_detail_edit_tags".localized) {
                    showTagEditor = true
                }
                Button("track_detail_close".localized) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, DesignTokens.space16)
        .padding(.vertical, DesignTokens.space12)
    }

    // MARK: - 分区

    private var scrapedSection: some View {
        Section("track_detail_section_scraped".localized) {
            valueRow("artist", model.snapshot.artistName)
            valueRow("album", model.snapshot.albumTitle)
            valueRow("track_detail_album_artist", model.snapshot.albumArtist)
            valueRow("track_detail_year", model.snapshot.year.map(String.init))
            valueRow("tag_editor_field_genre", track.displayGenre)
            valueRow("track_detail_track_number", model.trackNumberText)
            valueRow("duration", model.durationText)
            LabeledContent("track_detail_lyrics".localized) {
                Text(model.snapshot.hasLyrics ? "track_detail_lyrics_available".localized : "track_detail_lyrics_missing".localized)
                    .foregroundStyle(.secondary)
            }
            if !model.snapshot.lyricsPreview.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignTokens.space4) {
                        ForEach(Array(model.snapshot.lyricsPreview.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, DesignTokens.space4)
                }
                .frame(maxHeight: 120)
            }
            if model.isUnscraped {
                HStack(spacing: DesignTokens.space8) {
                    Label("track_detail_not_scraped".localized, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("track_detail_go_scrape".localized) {
                        showTagEditor = true
                    }
                }
            }
        }
    }

    private var fileSection: some View {
        Section("track_detail_section_file".localized) {
            LabeledContent("track_detail_path".localized) {
                Text(track.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .multilineTextAlignment(.trailing)
            }
            valueRow("track_detail_file_size", model.fileSizeText)
            valueRow("track_detail_format", model.fileFormatText)
            valueRow("track_detail_sample_rate", model.sampleRateText)
            valueRow("track_detail_bit_depth", model.bitDepthText)
            valueRow("track_detail_channels", model.channelsText)
        }
    }

    private var playbackSection: some View {
        Section("track_detail_section_playback".localized) {
            valueRow("track_detail_play_count", model.playCountText)
            if model.snapshot.history.hasEverPlayed {
                valueRow("track_detail_last_played", model.lastPlayedText)
                valueRow("track_detail_total_played", model.totalPlayedText)
            } else {
                LabeledContent("track_detail_last_played".localized) {
                    Text("track_detail_never_played".localized)
                        .foregroundStyle(.secondary)
                }
            }
            if !model.snapshot.history.recentPlays.isEmpty {
                Text("track_detail_recent_plays".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(model.snapshot.history.recentPlays.enumerated()), id: \.offset) { _, play in
                    HStack {
                        Text(MacTrackDetailModel.formatPlayedAt(play.playedAt) ?? "track_detail_unknown".localized)
                        Spacer()
                        Text(MacTrackDetailModel.formatDuration(ms: Int(play.playDurationMs)) ?? "track_detail_unknown".localized)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }

    // MARK: - 行

    private func valueRow(_ titleKey: String, _ value: String?) -> some View {
        LabeledContent(titleKey.localized) {
            if let value, !value.isEmpty {
                Text(value)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text("track_detail_unknown".localized)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
