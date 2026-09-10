//
//  AppCoordinatorModels.swift
//  QQPlayer
//
//  AppCoordinator 配套顶层类型：Dictionary 工具扩展、协调器错误枚举。
//  M3-2：iCloudStatus 枚举随 iCloud 状态机退役删除。
//

extension Dictionary {
    func compactMapKeys<T>(_ transform: (Key) throws -> T?) rethrows -> [T: Value] {
        var result: [T: Value] = [:]
        for (key, value) in self {
            if let transformedKey = try transform(key) {
                result[transformedKey] = value
            }
        }
        return result
    }
}

enum AppCoordinatorError: Error {
    case databaseError
    case indexingError
    case playlistNotFound

    var localizedDescription: String {
        switch self {
        case .databaseError:
            return "Database error occurred."
        case .indexingError:
            return "Error indexing music library."
        case .playlistNotFound:
            return "Playlist not found."
        }
    }
}
