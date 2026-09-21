//
//  MacTagEditorView+CoverForm.swift
//  QQPlayer
//
//  `MacTagEditorView` 的封面列 / 表单列（2026-09-21 从 `MacTagEditorView.swift` 纯搬家，零行为/UI 变化）。
//
//  ⚠️ 可见性：被主片或其它分区文件引用的成员为 internal（原 `private`）。
//
import AppKit
import SwiftUI

extension MacTagEditorView {
    // MARK: 封面列

    /// 分片：跨文件可见（原 private）
    var coverColumn: some View {
        VStack(spacing: DesignTokens.space8) {
            coverPreview
            Text("tag_editor_cover".localized)
                .font(.caption2)
                .foregroundColor(.secondary)
            Button {
                downloadCandidateCover()
            } label: {
                Label("tag_editor_use_candidate_cover".localized, systemImage: "photo.badge.arrow.down")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(selectedCoverURL == nil || saving)
            .help("tag_editor_use_candidate_cover_help".localized)

            Button(role: .destructive) {
                coverState = .remove
            } label: {
                Label("tag_editor_remove_cover".localized, systemImage: "trash")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(saving)
        }
        .frame(width: 150)
    }

    @ViewBuilder
    private var coverPreview: some View {
        Group {
            switch coverState {
            case .keep:
                MacArtworkThumbnail(track: track, size: 132, cornerRadius: DesignTokens.radius10)
            case .replace(let data):
                if let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholderCover
                }
            case .remove:
                placeholderCover
            }
        }
        .frame(width: 132, height: 132)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radius10))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.radius10)
                .strokeBorder(Color.gray.opacity(0.25), lineWidth: 1)
        )
    }

    private var placeholderCover: some View {
        RoundedRectangle(cornerRadius: DesignTokens.radius10)
            .fill(Color.gray.opacity(0.15))
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: DesignTokens.font40))
                    .foregroundColor(.secondary)
            }
    }

    // MARK: 表单列

    /// 分片：跨文件可见（原 private）
    var formColumn: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space8) {
            field("title".localized, text: $formTitle, disabled: saving)
            field("artist".localized, text: $formArtist, disabled: saving)
            field("album".localized, text: $formAlbum, disabled: saving)
            HStack(spacing: DesignTokens.space10) {
                field("tag_editor_field_year".localized, text: $formYear, disabled: saving)
                field("tag_editor_field_genre".localized, text: $formGenre, disabled: saving)
            }
            HStack(spacing: DesignTokens.space10) {
                field("tag_editor_field_track".localized, text: $formTrack, disabled: saving)
                field("tag_editor_field_album_artist".localized, text: $formAlbumArtist, disabled: saving)
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, disabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.space4) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .disabled(disabled)
        }
    }
}
