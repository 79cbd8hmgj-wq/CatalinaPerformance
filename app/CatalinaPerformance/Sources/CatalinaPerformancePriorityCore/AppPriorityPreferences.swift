import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public enum AppPriorityPreferences {
    public static let enabledKey = "advanced.appPriority.enabled"
    public static let selectedApplicationKey = "advanced.appPriority.selectedApplication"

    public static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [enabledKey: false])
    }

    public static func load(from defaults: UserDefaults = .standard) -> AppPrioritySelection {
        let enabled = defaults.bool(forKey: enabledKey)
        var application: AppPriorityApplication?
        if let encoded = defaults.data(forKey: selectedApplicationKey) {
            application = try? JSONDecoder().decode(AppPriorityApplication.self, from: encoded)
        }
        return AppPrioritySelection(enabled: enabled, application: application)
    }

    public static func save(_ selection: AppPrioritySelection, to defaults: UserDefaults = .standard) throws {
        defaults.set(selection.enabled, forKey: enabledKey)
        if let application = selection.application {
            defaults.set(try JSONEncoder().encode(application), forKey: selectedApplicationKey)
        } else {
            defaults.removeObject(forKey: selectedApplicationKey)
        }
    }
}

public extension AppPrioritySelection {
    func writeAtomically(to destinationURL: URL, fileManager: FileManager = .default) throws {
        let directory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [
            .posixPermissions: NSNumber(value: Int16(0o700))
        ])

        let temporaryURL = directory.appendingPathComponent(".selection.json.tmp")
        try? fileManager.removeItem(at: temporaryURL)

        do {
            let data = try JSONEncoder().encode(self)
            try data.write(to: temporaryURL, options: [])
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: temporaryURL.path)

            let renameResult = temporaryURL.path.withCString { sourcePointer in
                destinationURL.path.withCString { destinationPointer in
                    rename(sourcePointer, destinationPointer)
                }
            }
            if renameResult != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: destinationURL.path])
            }
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: destinationURL.path)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}
