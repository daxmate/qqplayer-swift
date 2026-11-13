//
//  MacRecommendationSettingsView.swift
//  QQPlayer
//
//  推荐 v3：macOS「设置 → 推荐」分类。
//
//  - 口味画像权重（曲库 / 播放 / 收藏 / 新鲜度；写入时归一到和 1）。
//  - 三通道配额（种子艺人 / 相似艺人 / 风格探索；写入时归一到和 1）。
//  - Last.fm API key（钥匙串存储；界面只显示是否已保存，不回显明文）。
//  - 指令上下文轮数 / 相似艺人比例 / MusicBrainz 关系扩展（沿用 v2 设置）。
//
//  视图层不直连任何单例（数据读写全走 DeleteSettings / Keychain 封装）。
//

import SwiftUI

struct MacRecommendationSettingsView: View {
    @State private var settings = DeleteSettings.load()
    @State private var lastFMKeySaved = KeychainLastFMKeyStore().apiKey() != nil
    @State private var lastFMKeyDraft = ""
    @State private var lastFMKeyStatus: String?

    var body: some View {
        Form {
            profileWeightsSection
            channelQuotaSection
            lastFMSection
            iTunesSection
            requestSection
            relatedArtistSection
            artistRelationSection
        }
        .formStyle(.grouped)
        .onAppear {
            settings = DeleteSettings.load()
            lastFMKeySaved = KeychainLastFMKeyStore().apiKey() != nil
        }
    }

    // MARK: - 口味画像

    private var profileWeightsSection: some View {
        Section {
            weightRow("recommendation_weight_library", value: $settings.recommendationV3.weightLibrary)
                .settingsAnchor(MacSettingsCatalog.recommendationWeightLibrary)
            weightRow("recommendation_weight_play", value: $settings.recommendationV3.weightPlay)
                .settingsAnchor(MacSettingsCatalog.recommendationWeightPlay)
            weightRow("recommendation_weight_favorite", value: $settings.recommendationV3.weightFavorite)
                .settingsAnchor(MacSettingsCatalog.recommendationWeightFavorite)
            weightRow("recommendation_weight_recency", value: $settings.recommendationV3.weightRecency)
                .settingsAnchor(MacSettingsCatalog.recommendationWeightRecency)
        } header: {
            Text("recommendation_weights_title".localized)
        } footer: {
            Text("recommendation_weights_footer".localized)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func weightRow(_ titleKey: String, value: Binding<Double>) -> some View {
        HStack {
            Text(titleKey.localized)
            Slider(value: value, in: 0 ... 1, step: RecommendationProfileWeights.valueStep) { editing in
                guard !editing else { return }
                settings.recommendationV3.normalizeWeights()
                settings.save()
            }
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }

    // MARK: - 通道配额

    private var channelQuotaSection: some View {
        Section {
            quotaRow("recommendation_quota_seed", value: $settings.recommendationV3.quotaSeed)
                .settingsAnchor(MacSettingsCatalog.recommendationQuotaSeed)
            quotaRow("recommendation_quota_similar", value: $settings.recommendationV3.quotaSimilar)
                .settingsAnchor(MacSettingsCatalog.recommendationQuotaSimilar)
            quotaRow("recommendation_quota_explore", value: $settings.recommendationV3.quotaExplore)
                .settingsAnchor(MacSettingsCatalog.recommendationQuotaExplore)
        } header: {
            Text("recommendation_quotas_title".localized)
        } footer: {
            Text("recommendation_quotas_footer".localized)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func quotaRow(_ titleKey: String, value: Binding<Double>) -> some View {
        HStack {
            Text(titleKey.localized)
            Slider(value: value, in: 0 ... 1, step: RecommendationChannelQuotas.valueStep) { editing in
                guard !editing else { return }
                settings.recommendationV3.normalizeQuotas()
                settings.save()
            }
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }

    // MARK: - Last.fm

    private var lastFMSection: some View {
        Section {
            Toggle(isOn: $settings.recommendationV3.lastFMEnabled) {
                Text("recommendation_lastfm_enable".localized)
            }
            .settingsAnchor(MacSettingsCatalog.recommendationLastFMToggle)
            .onChange(of: settings.recommendationV3.lastFMEnabled) { _, _ in
                settings.save()
            }
            HStack {
                SecureField("recommendation_lastfm_placeholder".localized, text: $lastFMKeyDraft)
                    .textFieldStyle(.roundedBorder)
                Button("recommendation_lastfm_save".localized) {
                    saveLastFMKey()
                }
                .buttonStyle(.bordered)
                .disabled(lastFMKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if lastFMKeySaved {
                    Text("recommendation_lastfm_saved".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .settingsAnchor(MacSettingsCatalog.recommendationLastFMKey)
            if lastFMKeySaved {
                Button("recommendation_lastfm_clear".localized, role: .destructive) {
                    clearLastFMKey()
                }
                .buttonStyle(.borderless)
            }
            if let lastFMKeyStatus {
                Text(lastFMKeyStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("recommendation_lastfm_title".localized)
        } footer: {
            Text("recommendation_lastfm_footer".localized)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func saveLastFMKey() {
        let key = lastFMKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try KeychainLastFMKeyStore().save(key)
            lastFMKeySaved = true
            lastFMKeyDraft = ""
            lastFMKeyStatus = "recommendation_lastfm_saved_hint".localized
        } catch {
            lastFMKeyStatus = "recommendation_lastfm_save_failed".localized
        }
    }

    private func clearLastFMKey() {
        do {
            try KeychainLastFMKeyStore().save("")
            lastFMKeySaved = false
            lastFMKeyStatus = "recommendation_lastfm_cleared".localized
        } catch {
            lastFMKeyStatus = "recommendation_lastfm_save_failed".localized
        }
    }

    // MARK: - iTunes 元数据标准化

    private var iTunesSection: some View {
        Section {
            Stepper(
                value: $settings.recommendationV3.itunesLookupLimit,
                in: RecommendationV3Settings.itunesLookupLimitRange
            ) {
                HStack {
                    Text("recommendation_itunes_lookup_title".localized)
                    Spacer()
                    Text("\(settings.recommendationV3.itunesLookupLimit)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .settingsAnchor(MacSettingsCatalog.recommendationITunesLookup)
            .onChange(of: settings.recommendationV3.itunesLookupLimit) { _, newValue in
                settings.recommendationV3.itunesLookupLimit = RecommendationV3Settings.clampITunesLookupLimit(newValue)
                settings.save()
            }
        } footer: {
            Text("recommendation_itunes_lookup_footer".localized)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 指令

    private var requestSection: some View {
        Section {
            Stepper(value: $settings.recommendationChatRounds, in: DeleteSettings.recommendationChatRoundsRange) {
                HStack {
                    Text("recommendation_chat_rounds_title".localized)
                    Spacer()
                    Text("\(settings.recommendationChatRounds)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .settingsAnchor(MacSettingsCatalog.recommendationChatRounds)
            .onChange(of: settings.recommendationChatRounds) { _, newValue in
                settings.recommendationChatRounds = DeleteSettings.clampRecommendationChatRounds(newValue)
                settings.save()
            }
        } footer: {
            Text("recommendation_chat_rounds_footer".localized)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 相似艺人比例

    private var relatedArtistSection: some View {
        Section {
            HStack {
                Text("recommendation_related_share_title".localized)
                Spacer()
                Text("\(Int((settings.relatedArtistShare * 100).rounded()))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: $settings.relatedArtistShare,
                in: DeleteSettings.relatedArtistShareRange,
                step: DeleteSettings.relatedArtistShareStep
            )
            .settingsAnchor(MacSettingsCatalog.recommendationRelatedShare)
            .onChange(of: settings.relatedArtistShare) { _, newValue in
                settings.relatedArtistShare = DeleteSettings.clampRelatedArtistShare(newValue)
                settings.save()
            }
        } footer: {
            Text("recommendation_related_share_footer".localized)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - MusicBrainz 关系扩展

    private var artistRelationSection: some View {
        Section {
            Toggle(
                "recommendation_artist_relation_title".localized,
                isOn: $settings.recommendationArtistRelationExpansion
            )
            .settingsAnchor(MacSettingsCatalog.recommendationArtistRelation)
            .onChange(of: settings.recommendationArtistRelationExpansion) { _, _ in
                settings.save()
            }
        } footer: {
            Text("recommendation_artist_relation_footer".localized)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
