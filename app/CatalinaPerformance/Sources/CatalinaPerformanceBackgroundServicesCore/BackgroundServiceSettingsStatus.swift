import Foundation

public enum BackgroundServiceSettingsStatusError: Error, Equatable {
    case symbolicLinkRejected
    case fileTooLarge
    case unsupportedSchema(Int)
    case invalidStatus
}

public struct BackgroundServiceSettingsCategoryStatus: Codable, Equatable {
    public let category: BackgroundServiceCategory
    public let state: BackgroundServiceCategoryState
    public let note: String?

    public init(category: BackgroundServiceCategory, state: BackgroundServiceCategoryState, note: String?) {
        self.category = category
        self.state = state
        self.note = note
    }
}

public struct BackgroundServiceSettingsStatus: Codable, Equatable {
    public static let currentSchemaVersion = 1
    public static let maximumFileSize = 256 * 1024

    public let schemaVersion: Int
    public let categories: [BackgroundServiceSettingsCategoryStatus]

    public init(schemaVersion: Int = BackgroundServiceSettingsStatus.currentSchemaVersion, categories: [BackgroundServiceSettingsCategoryStatus]) {
        self.schemaVersion = schemaVersion
        self.categories = categories
    }

    public static func load(from url: URL, fileManager: FileManager = .default) throws -> BackgroundServiceSettingsStatus {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        if values.isSymbolicLink == true {
            throw BackgroundServiceSettingsStatusError.symbolicLinkRejected
        }
        if let size = values.fileSize, size > maximumFileSize {
            throw BackgroundServiceSettingsStatusError.fileTooLarge
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maximumFileSize else {
            throw BackgroundServiceSettingsStatusError.fileTooLarge
        }
        do {
            let status = try JSONDecoder().decode(BackgroundServiceSettingsStatus.self, from: data)
            guard status.schemaVersion == currentSchemaVersion else {
                throw BackgroundServiceSettingsStatusError.unsupportedSchema(status.schemaVersion)
            }
            let allowedCategories: Set<BackgroundServiceCategory> = [.softwareUpdate, .appStoreUpdates]
            guard status.categories.allSatisfy({ allowedCategories.contains($0.category) }) else {
                throw BackgroundServiceSettingsStatusError.invalidStatus
            }
            return status
        } catch let error as BackgroundServiceSettingsStatusError {
            throw error
        } catch {
            throw BackgroundServiceSettingsStatusError.invalidStatus
        }
    }
}
