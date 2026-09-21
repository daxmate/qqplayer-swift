//
//  EnvironmentLoader.swift
//  QQPlayer
//
//  Environment variable loader for API keys and configuration
//

import Foundation

class EnvironmentLoader: @unchecked Sendable {
    static let shared = EnvironmentLoader()

    private var environmentVariables: [String: String] = [:]

    private init() {
        loadEnvironmentVariables()
    }

    private func loadEnvironmentVariables() {
        // First, try to load from .env file in the app bundle
        if let envPath = Bundle.main.path(forResource: ".env", ofType: nil) {
            loadFromFile(path: envPath)
        }

        // 注意：不再尝试 "bundlePath/../../../.env" 项目根路径——DerivedData 构建下
        // 该路径解析到构建产物内部而非源码目录，永远失效（死路径，2026-08-30 审计清尾）。
        // 开发期请用环境变量注入（loadFromSystemEnvironment 已支持）。

        // Finally, load from actual environment variables (overrides file values)
        loadFromSystemEnvironment()
    }

    private func loadFromFile(path: String) {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            AppLog.warn(.general, "📄 EnvironmentLoader: Could not read .env file at \(path)")
            return
        }

        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Parse KEY=VALUE format
            let components = trimmed.components(separatedBy: "=")
            if components.count >= 2 {
                let key = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = components.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespacesAndNewlines)

                // Remove quotes if present
                let cleanValue = value.hasPrefix("\"") && value.hasSuffix("\"") ?
                    String(value.dropFirst().dropLast()) : value

                environmentVariables[key] = cleanValue
                AppLog.info(.general, "🔑 EnvironmentLoader: Loaded \(key) from .env file")
            }
        }
    }

    private func loadFromSystemEnvironment() {
        // Load system environment variables (these override .env file values)
        for (key, value) in ProcessInfo.processInfo.environment {
            if key.hasPrefix("SPOTIFY_") || key.hasPrefix("DISCOGS_") {
                environmentVariables[key] = value
                AppLog.info(.general, "🌍 EnvironmentLoader: Loaded \(key) from system environment")
            }
        }
    }

    /// Get an environment variable value
    func getValue(for key: String) -> String? {
        return environmentVariables[key]
    }

    /// Get an environment variable value with a fallback
    func getValue(for key: String, fallback: String) -> String {
        return environmentVariables[key] ?? fallback
    }

    /// Check if a key exists
    func hasKey(_ key: String) -> Bool {
        return environmentVariables[key] != nil
    }

    /// Get all loaded keys (for debugging)
    func getAllKeys() -> [String] {
        return Array(environmentVariables.keys).sorted()
    }
}

// MARK: - API Key Helpers

extension EnvironmentLoader {
    // Spotify API Keys (optional — missing keys disable the feature, never crash)
    var spotifyClientId: String? {
        getValue(for: "SPOTIFY_CLIENT_ID")
    }

    var spotifyClientSecret: String? {
        getValue(for: "SPOTIFY_CLIENT_SECRET")
    }

    // Discogs API Keys (optional — missing keys disable the feature, never crash)
    var discogsConsumerKey: String? {
        getValue(for: "DISCOGS_CONSUMER_KEY")
    }

    var discogsConsumerSecret: String? {
        getValue(for: "DISCOGS_CONSUMER_SECRET")
    }
}
