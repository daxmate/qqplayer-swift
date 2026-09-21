//
//  MacTagEditorView+RenameSave.swift
//  QQPlayer
//
//  `MacTagEditorView` 的重命名段 / 重命名预览 / 保存 / 播放队列跟随（2026-09-21 从 `MacTagEditorView.swift` 纯搬家，零行为/UI 变化）。
//
//  ⚠️ 可见性：被主片或其它分区文件引用的成员为 internal（原 `private`）。
//
import AppKit
import SwiftUI

extension MacTagEditorView {
    // MARK: 重命名

    /// 分片：跨文件可见（原 private）
    var renameSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space6) {
            Toggle(isOn: $renameEnabled) {
                Text("tag_editor_rename_files".localized)
                    .font(.callout)
            }
            .disabled(saving)
            .onChange(of: renameEnabled) { _, _ in
                updateRenamePreview()
            }
            HStack(spacing: DesignTokens.space8) {
                Text("scraping_rename_preview".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(renamePreviewText.isEmpty ? "—" : renamePreviewText)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(renameEnabled ? appAccentColor : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .padding(.leading, DesignTokens.space2)
        }
        .onChange(of: formTitle) { _, _ in updateRenamePreview() }
        .onChange(of: formArtist) { _, _ in updateRenamePreview() }
        .onChange(of: formAlbum) { _, _ in updateRenamePreview() }
        .onChange(of: formYear) { _, _ in updateRenamePreview() }
        .onChange(of: formTrack) { _, _ in updateRenamePreview() }
    }

    /// 无可保存内容（全空 + 封面未动）→ 禁用保存（web「至少一个非空」语义的
    /// Mac 原生表达；封面操作/移除也算可保存）
    /// 分片：跨文件可见（原 private）
    var canSave: Bool {
        let textNonEmpty = [formTitle, formArtist, formAlbum, formGenre, formAlbumArtist]
            .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let yearNonEmpty = !formYear.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let trackNonEmpty = !formTrack.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let coverChanged: Bool = {
            switch coverState {
            case .keep: return false
            case .replace, .remove: return true
            }
        }()
        return textNonEmpty || yearNonEmpty || trackNonEmpty || coverChanged
    }

    // MARK: - 重命名预览

    /// 模板渲染目标文件名（含相对子目录路径）；渲染失败/空 → ""（不改名）
    /// 分片：跨文件可见（原 private）
    func renderedTargetName() -> String {
        let ext = URL(fileURLWithPath: track.path).pathExtension
        return TagRenameLogic.renderFileName(
            template: renameTemplate,
            values: TagRenameLogic.Values(
                artist: formArtist.isEmpty ? nil : formArtist,
                title: formTitle.isEmpty ? nil : formTitle,
                album: formAlbum.isEmpty ? nil : formAlbum,
                track: Int(formTrack),
                year: Int(formYear)
            ),
            ext: ext.isEmpty ? "" : "." + ext
        ) ?? ""
    }

    /// 分片：跨文件可见（原 private）
    func updateRenamePreview() {
        renamePreviewText = renderedTargetName()
    }

    // MARK: - 保存（web POST /api/tags 等价）

    /// 分片：跨文件可见（原 private）
    func save() {
        guard !saving, canSave else { return }
        saving = true
        saveError = nil
        let originalPath = track.path
        let request = buildRequest()
        let oldStableId = track.stableId

        // 写标签 + DB 迁移是阻塞 IO → 后台执行，完成后 hop 主线程
        Task.detached(priority: .userInitiated) {
            do {
                let result = try TagWriterService.writeTags(
                    to: URL(fileURLWithPath: originalPath),
                    request: request
                )
                if result.renamed {
                    // 改名 → moveTrack 迁移引用（幂等；文件已改名但迁移失败 → 提示重扫）
                    // 写操作唯一入口是 @MainActor 的 AppCoordinator → 从后台 hop 回主线程执行
                    try await MainActor.run {
                        try appCoordinator.moveTrack(
                            from: originalPath,
                            to: result.finalURL.path
                        )
                    }
                    let migrated = try LibraryReads.track(path: result.finalURL.path)
                    await MainActor.run {
                        finishSaveSuccess(renamed: true, oldStableId: oldStableId, migrated: migrated, finalPath: result.finalURL.path)
                    }
                } else {
                    await MainActor.run {
                        finishSaveSuccess(renamed: false, oldStableId: oldStableId, migrated: nil, finalPath: result.finalURL.path)
                    }
                }
            } catch {
                await MainActor.run {
                    finishSaveFailure(error)
                }
            }
        }
    }

    /// 构造写标签请求：非空文本才进 request；coverData/removeCover 按用户显式选择
    private func buildRequest() -> TagWriteRequest {
        var request = TagWriteRequest()
        request.title = trimmed(formTitle)
        request.artist = trimmed(formArtist)
        request.album = trimmed(formAlbum)
        request.genre = trimmed(formGenre)
        request.albumArtist = trimmed(formAlbumArtist)
        request.year = Int(formYear)
        request.trackNumber = Int(formTrack)
        request.renameTemplate = renameEnabled ? renameTemplate : nil
        switch coverState {
        case .keep:
            break
        case .replace(let data):
            request.coverData = data
        case .remove:
            request.removeCover = true
        }
        return request
    }

    private func trimmed(_ value: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    private func finishSaveSuccess(renamed: Bool, oldStableId: String, migrated: Track?, finalPath: String) {
        saving = false
        if renamed, let migrated {
            followRenamedTrackInPlayback(oldStableId: oldStableId, newTrack: migrated)
        }
        // 单文件入库同步：保存只改了文件，DB 里的标签与封面缓存仍是旧值 → 列表不刷新
        // （旧实现只发 LibraryFolderContentChanged，要等整库重扫扫到这首歌才更新）。
        // 这里直接对该文件跑一次 indexer 单文件处理：解析 → upsert DB →
        // forceRefreshArtwork（封面缓存）→ 完成后内部 post LibraryNeedsRefresh，
        // 所有列表容器（主库/歌单详情/自动歌单/专辑卡）立即重拉新值。
        Task {
            _ = await libraryIndexer.processExternalFile(URL(fileURLWithPath: finalPath))
            // DB 已同步到最新标签 → 把播放上下文（当前曲目/队列）替换成 DB 新行，
            // 未改名时播放页标题/歌手也立即跟随（改名场景已在上面用 migrated 处理，
            // 此处按 oldStableId 匹配为幂等 no-op）
            if let fresh = try? LibraryReads.track(path: finalPath) {
                followRenamedTrackInPlayback(oldStableId: oldStableId, newTrack: fresh)
            }
            // 兜底补发（processExternalFile 提前返回/指纹未变时也保证列表刷新）
            NotificationCenter.default.post(
                name: .libraryNeedsRefresh,
                object: nil
            )
        }
        // 成功反馈：短暂 flash 后自动关闭（web toast + close 语义）
        withAnimation { savedFlash = true }
        activeTasks["savedFlash"] = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                dismiss()
            }
        }
    }

    private func finishSaveFailure(_ error: Error) {
        saving = false
        if let tagError = error as? TagWriterError,
           case .unsupportedFormat = tagError {
            showUnsupportedAlert = true
            return
        }
        // 写失败/迁移失败 → 红字真实原因
        if case let TagWriterError.writeFailed(reason) = error {
            saveError = "tag_editor_save_failed".localized + ": " + reason
        } else if case TagWriterError.fileNotReadable = error {
            saveError = "tag_editor_save_failed".localized + ": " + (error.localizedDescription)
        } else {
            // moveTrack 抛错等：文件可能已改名但 DB 未迁移 → 提示重扫
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            saveError = "tag_editor_db_migrate_failed".localized(with: detail)
        }
    }

    /// 播放队列路径跟随（web「改名后目标歌曲路径跟随，不打断播放」语义）：编辑对象若在播放队列/正在播放 → 用迁移后的新 Track 替换（含新 stableId），
    /// 不调 loadTrack/playTrack —— 已加载的音频继续播，下次切到它用新路径加载。
    @MainActor
    private func followRenamedTrackInPlayback(oldStableId: String, newTrack: Track) {
        let player = playerEngine
        if player.currentTrack?.stableId == oldStableId {
            player.currentTrack = newTrack
        }
        if player.playbackQueue.contains(where: { $0.stableId == oldStableId }) {
            player.playbackQueue = player.playbackQueue.map {
                $0.stableId == oldStableId ? newTrack : $0
            }
        }
        if player.originalQueue.contains(oldStableId) {
            player.originalQueue = player.originalQueue.map {
                $0 == oldStableId ? newTrack.stableId : $0
            }
        }
        player.normalizeIndexAndTrack()
    }
}
