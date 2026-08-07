import Foundation

public struct CatalinaVisualPerformanceCatalog: Equatable {
    public static let current = CatalinaVisualPerformanceCatalog(version: 1, entries: [
        VisualSettingCatalogEntry(
            id: .finderAnimations,
            displayName: "Finder animations",
            domain: "com.apple.finder",
            key: "DisableAllAnimations",
            acceptedExistingTypes: [.boolean],
            appliedValue: .boolean(true),
            applicability: .always,
            refreshBehavior: .deferredComponentRefresh
        ),
        VisualSettingCatalogEntry(
            id: .dockLaunchAnimation,
            displayName: "Dock launch animation",
            domain: "com.apple.dock",
            key: "launchanim",
            acceptedExistingTypes: [.boolean],
            appliedValue: .boolean(false),
            applicability: .always,
            refreshBehavior: .deferredComponentRefresh
        ),
        VisualSettingCatalogEntry(
            id: .missionControlTransitions,
            displayName: "Mission Control transitions",
            domain: "com.apple.dock",
            key: "expose-animation-duration",
            acceptedExistingTypes: [.floatingPoint, .integer],
            appliedValue: .floatingPoint(0.1),
            applicability: .always,
            refreshBehavior: .deferredComponentRefresh
        ),
        VisualSettingCatalogEntry(
            id: .windowOpeningAnimations,
            displayName: "Window-opening animations",
            domain: "NSGlobalDomain",
            key: "NSAutomaticWindowAnimationsEnabled",
            acceptedExistingTypes: [.boolean],
            appliedValue: .boolean(false),
            applicability: .always,
            refreshBehavior: .immediate
        ),
        VisualSettingCatalogEntry(
            id: .reduceMotion,
            displayName: "Reduce Motion",
            domain: "com.apple.universalaccess",
            key: "reduceMotion",
            acceptedExistingTypes: [.boolean],
            appliedValue: .boolean(true),
            applicability: .always,
            refreshBehavior: .immediate
        ),
        VisualSettingCatalogEntry(
            id: .reduceTransparency,
            displayName: "Reduce Transparency",
            domain: "com.apple.universalaccess",
            key: "reduceTransparency",
            acceptedExistingTypes: [.boolean],
            appliedValue: .boolean(true),
            applicability: .always,
            refreshBehavior: .immediate
        ),
        VisualSettingCatalogEntry(
            id: .minimizeEffect,
            displayName: "Minimize effect",
            domain: "com.apple.dock",
            key: "mineffect",
            acceptedExistingTypes: [.string],
            appliedValue: .string("scale"),
            applicability: .always,
            refreshBehavior: .deferredComponentRefresh
        ),
        VisualSettingCatalogEntry(
            id: .dockAutoHideDelay,
            displayName: "Dock auto-hide delay",
            domain: "com.apple.dock",
            key: "autohide-delay",
            acceptedExistingTypes: [.floatingPoint, .integer],
            appliedValue: .floatingPoint(0),
            applicability: .dockAutoHideEnabled,
            refreshBehavior: .deferredComponentRefresh
        ),
        VisualSettingCatalogEntry(
            id: .dockAutoHideAnimation,
            displayName: "Dock auto-hide animation",
            domain: "com.apple.dock",
            key: "autohide-time-modifier",
            acceptedExistingTypes: [.floatingPoint, .integer],
            appliedValue: .floatingPoint(0),
            applicability: .dockAutoHideEnabled,
            refreshBehavior: .deferredComponentRefresh
        )
    ])

    public let version: Int
    public let entries: [VisualSettingCatalogEntry]

    public init(version: Int, entries: [VisualSettingCatalogEntry]) {
        self.version = version
        self.entries = entries
    }

    public subscript(id: VisualSettingID) -> VisualSettingCatalogEntry? {
        return entries.first(where: { $0.id == id })
    }
}
