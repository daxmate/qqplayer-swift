//
//  MacTagEditorView+Scrape.swift
//  QQPlayer
//
//  `MacTagEditorView` 的刮削行 / 候选区 / 刮削逻辑 / 候选封面下载（2026-09-21 从 `MacTagEditorView.swift` 纯搬家，零行为/UI 变化）。
//
//  ⚠️ 可见性：被主片或其它分区文件引用的成员为 internal（原 `private`）。
//
import AppKit
import SwiftUI

extension MacTagEditorView {
    // MARK: 刮削行

    /// 分片：跨文件可见（原 private）
    var scrapeRow: some View {
        HStack(spacing: DesignTokens.space8) {
            switch scrapeState {
            case .idle:
                emptyRow
            case .searching:
                HStack(spacing: DesignTokens.space6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("tag_editor_scraping".localized)
                        .foregroundColor(.secondary)
                }
            case .done:
                HStack(spacing: DesignTokens.space6) {
                    Image(systemName: "sparkles")
                        .foregroundColor(appAccentColor)
                    if !scrapeQuery.isEmpty {
                        Text(scrapeQuery)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer()
                    Button("tag_editor_scrape_again".localized) {
                        Task { await runScrape() }
                    }
                    .buttonStyle(.borderless)
                    .disabled(saving)
                }
            case .failed(let message):
                HStack(spacing: DesignTokens.space6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.red)
                    Text(message)
                        .foregroundColor(.red)
                        .lineLimit(1)
                    Spacer()
                    Button("tag_editor_scrape_again".localized) {
                        Task { await runScrape() }
                    }
                    .buttonStyle(.borderless)
                    .disabled(saving)
                }
            }
            Spacer()
        }
        .font(.caption)
        .padding(.vertical, DesignTokens.space2)
    }

    private var emptyRow: some View {
        Text("tag_editor_scrape_again".localized)
            .foregroundColor(.secondary)
            .onTapGesture {
                Task { await runScrape() }
            }
    }

    // MARK: 候选区（netease / musicbrainz 两组，展示顺序跟随设置 scrapingSourceOrder）

    @ViewBuilder
    /// 分片：跨文件可见（原 private）
    var candidatesSection: some View {
        if scrapeState != .idle && scrapeState != .searching {
            if neteaseCandidates.isEmpty && musicbrainzCandidates.isEmpty {
                VStack(spacing: DesignTokens.space6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: DesignTokens.font22))
                        .foregroundColor(.secondary)
                    Text("tag_editor_no_candidates".localized)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignTokens.space16)
            } else {
                VStack(alignment: .leading, spacing: DesignTokens.space10) {
                    ForEach(orderedSources, id: \.self) { source in
                        switch source {
                        case "musicbrainz":
                            candidateGroup(
                                title: "source_musicbrainz".localized,
                                icon: "brain.head.profile",
                                candidates: musicbrainzCandidates,
                                source: "musicbrainz"
                            )
                        default: // "netease"
                            candidateGroup(
                                title: "source_netease".localized,
                                icon: "cloud",
                                candidates: neteaseCandidates,
                                source: "netease"
                            )
                        }
                    }
                }
            }
        }
    }

    /// 源展示顺序 = 设置 scrapingSourceOrder（默认 netease 优先）；设置含未知源时过滤
    private var orderedSources: [String] {
        let known: Set<String> = ["netease", "musicbrainz"]
        let order = DeleteSettings.load().scrapingSourceOrder
        return order.filter { known.contains($0) }
    }

    private func candidateGroup(
        title: String,
        icon: String,
        candidates: [ScrapeCandidate],
        source: String
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.space6) {
            HStack(spacing: DesignTokens.space4) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
            }
            .foregroundColor(appAccentColor)
            if candidates.isEmpty {
                Text("tag_editor_no_candidates".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, DesignTokens.space4)
            } else {
                ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                    Button {
                        pick(candidate, source: source)
                    } label: {
                        MacTagEditorCandidateRow(candidate: candidate)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 刮削（web POST /api/tags/scrape 等价）

    /// 分片：跨文件可见（原 private）
    func runScrape() async {
        // query = 文件 title（解析失败回落文件名 stem）
        let query = ScrapeLogic.searchQuery(
            title: initialMetadata?.title,
            fileName: track.path
        )
        scrapeQuery = query
        scrapeState = .searching
        neteaseCandidates = []
        musicbrainzCandidates = []
        let artist = initialMetadata?.artist ?? ""
        let sources = await ScrapeBatchService.scrapeSources(query: query, artist: artist)
        guard !Task.isCancelled else { return }
        neteaseCandidates = sources.netease
        musicbrainzCandidates = sources.musicbrainz
        scrapeState = .done
    }

    /// 点选候选 → 填充表单（web pick 语义：候选有值才填，空值清空对应字段；
    /// 封面记录到 selectedCoverURL，需用户显式「使用候选封面」才下载）
    private func pick(_ candidate: ScrapeCandidate, source: String) {
        formTitle = candidate.title ?? ""
        formArtist = candidate.artist ?? ""
        formAlbum = candidate.album ?? ""
        if let year = candidate.year {
            formYear = String(year)
        } else {
            formYear = ""
        }
        if let genre = candidate.genre, !genre.isEmpty {
            formGenre = genre
        } else {
            formGenre = ""
        }
        if let track = candidate.track {
            formTrack = String(track)
        } else {
            formTrack = ""
        }
        formAlbumArtist = candidate.albumArtist ?? ""
        selectedCoverURL = candidate.coverURL
        // 点选候选 = 自动采用候选封面（web 语义对齐：点选即记录并使用 cover_url，
        // 不需要额外按钮）。先回到文件现状，有 coverURL → 自动下载暂存（成功替换
        // 预览；失败留 keep 并在表单底部红字提示，可手动「使用候选封面」重试）；
        // 无 coverURL → 保持文件现状。
        coverState = .keep
        if let coverURL = candidate.coverURL {
            downloadCandidateCover(from: coverURL)
        }
        updateRenamePreview()

        // 网易云候选且表单 year 空 → 静默补年份（POST /api/tags/album-year 等价；
        // 异步 + 静默失败，不阻塞点选）
        if source == "netease", let id = candidate.id, formYear.isEmpty {
            activeTasks["albumYear"]?.cancel()
            let songID = Int(id)
            activeTasks["albumYear"] = Task {
                let year = await NeteaseOnlineClient().albumYear(songID: songID ?? 0)
                guard !Task.isCancelled else { return }
                if let year, formYear.isEmpty {
                    formYear = String(year)
                    updateRenamePreview()
                }
            }
        }
    }

    /// 下载候选封面 → Data 暂存（保存时才写入文件）。点选候选行自动调用；
    /// 「使用候选封面」按钮作为失败后的手动重试。
    /// 分片：跨文件可见（原 private）
    func downloadCandidateCover(from url: URL? = nil) {
        guard let url = url ?? selectedCoverURL, !saving else { return }
        let taskKey = "coverDownload"
        activeTasks[taskKey]?.cancel()
        activeTasks[taskKey] = Task {
            let data = try? await Self.downloadCoverData(from: url)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if let data {
                    coverState = .replace(data)
                    saveError = nil
                } else {
                    saveError = "tag_editor_cover_download_failed".localized
                }
            }
        }
    }

    /// 封面下载（JPEG/PNG 校验，web tag_editor.fetch_cover 语义）
    private static func downloadCoverData(from url: URL) async throws -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("QQPlayer/1.0 (https://github.com/daxmate/qqplayer)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
              !data.isEmpty,
              data.starts(with: [0xFF, 0xD8, 0xFF]) || data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
            return nil
        }
        return data
    }
}
