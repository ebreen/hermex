import Foundation

/// The canonical, pure picker policy shared by the sheet and compact menu.
///
/// This type deliberately contains no SwiftUI state, persistence, or networking.
/// It resolves saved keys against the latest catalog while retaining missing
/// selections as fallback options, then builds canonical sheet rows and the
/// actual compact-menu row union from the same deterministic policy.
struct ComposerModelPickerProjection: Equatable, Sendable {
    let catalogGroups: [ModelCatalogGroup]
    let currentCustomRows: [ModelCatalogOption]
    let savedCustomRows: [ModelCatalogOption]
    let favoriteRows: [ModelCatalogOption]
    let recentRows: [ModelCatalogOption]
    let catalogRows: [ModelCatalogOption]
    let selectedCatalogOption: ModelCatalogOption?
    let sheetRows: [ModelCatalogOption]
    let compactRows: [ModelCatalogOption]
    /// Whether a non-catalog model row is already available before a collapsed
    /// catalog section is opened. This is the input used by auto-expansion.
    let usefulRowPresent: Bool

    /// The compact menu keeps its existing behavior: Favorites and Recent are
    /// separate sections, while the inline Model section contains only the
    /// current exact selection or its custom fallback.
    var compactMenuRows: [ModelCatalogOption] {
        let selected = selectedCatalogOption ?? currentCustomRows.first
        guard let selected else { return [] }
        let excluded = Set(favoriteRows.map(\.favoriteKey) + recentRows.map(\.favoriteKey))
        return excluded.contains(selected.favoriteKey) ? [] : [selected]
    }

    /// The groups rendered by the full sheet. Every favorite/recent/custom
    /// fallback is placed in a named group before catalog rows, and each key is
    /// emitted at most once across all groups. Empty catalog groups are retained
    /// so a valid-empty section is not confused with a failed catalog.
    var sheetGroups: [ModelCatalogGroup] {
        var claimed = Set<ModelFavoriteKey>()
        var result: [ModelCatalogGroup] = []

        func appendGroup(
            id: String,
            name: String,
            options: [ModelCatalogOption]
        ) {
            let unique = options.filter { claimed.insert($0.favoriteKey).inserted }
            guard !unique.isEmpty else { return }
            result.append(ModelCatalogGroup(id: id, name: name, providerID: nil, models: unique))
        }

        appendGroup(
            id: "current-custom-model",
            name: "Current Custom",
            options: currentCustomRows
        )
        appendGroup(
            id: "favorite-models",
            name: "Favorites",
            options: favoriteRows
        )
        appendGroup(
            id: "recent-models",
            name: "Recent",
            options: recentRows
        )
        appendGroup(
            id: "saved-custom-models",
            name: "Saved Custom",
            options: savedCustomRows
        )

        for group in catalogGroups {
            let models = group.models.filter { claimed.insert($0.favoriteKey).inserted }
            result.append(
                ModelCatalogGroup(
                    id: group.id,
                    name: group.name,
                    providerID: group.providerID,
                    models: models
                )
            )
        }

        return result
    }

    init(
        modelGroups: [ModelCatalogGroup],
        selectedModelID: String? = nil,
        selectedModelProviderID: String? = nil,
        favoriteModelKeys: [ModelFavoriteKey] = [],
        recentModelKeys: [ModelFavoriteKey] = [],
        savedCustomOptions: [ModelCatalogOption] = []
    ) {
        let canonicalGroups = Self.canonicalGroups(modelGroups)
        let allCatalogOptions = canonicalGroups.flatMap(\.models)
        let catalogKeys = Set(allCatalogOptions.map(\.favoriteKey))
        var optionsByKey: [ModelFavoriteKey: ModelCatalogOption] = [:]
        for option in allCatalogOptions where optionsByKey[option.favoriteKey] == nil {
            optionsByKey[option.favoriteKey] = option
        }

        let selected = allCatalogOptions.firstMatchingSelection(
            modelID: selectedModelID,
            providerID: selectedModelProviderID
        )
        let currentFallback: [ModelCatalogOption]
        if selected == nil,
           let modelID = Self.nonEmpty(selectedModelID) {
            currentFallback = [
                ModelCatalogOption(
                    id: modelID,
                    displayName: modelID,
                    providerID: Self.nonEmpty(selectedModelProviderID)
                )
            ]
        } else {
            currentFallback = []
        }

        let favorites = Self.resolvedRows(
            keys: favoriteModelKeys,
            optionsByKey: optionsByKey
        )
        let favoriteKeySet = Set(Self.uniqueKeys(favoriteModelKeys))
        let recents = Self.resolvedRows(
            keys: recentModelKeys.filter { favoriteKeySet.contains($0) == false },
            optionsByKey: optionsByKey
        )

        let currentKeys = Set(currentFallback.map(\.favoriteKey))
        let recentKeySet = Set(recents.map(\.favoriteKey))
        let saved = Self.uniqueOptions(savedCustomOptions).filter { option in
            let key = option.favoriteKey
            return catalogKeys.contains(key) == false
                && currentKeys.contains(key) == false
                && favoriteKeySet.contains(key) == false
                && recentKeySet.contains(key) == false
        }

        var claimed = Set<ModelFavoriteKey>()
        func canonicalRows(_ rows: [ModelCatalogOption]) -> [ModelCatalogOption] {
            rows.filter { claimed.insert($0.favoriteKey).inserted }
        }

        let canonicalCurrent = canonicalRows(currentFallback)
        let canonicalFavorites = canonicalRows(favorites)
        let canonicalRecents = canonicalRows(recents)
        let canonicalSaved = canonicalRows(saved)
        let canonicalCatalog = canonicalGroups.flatMap(\.models)
            .filter { claimed.insert($0.favoriteKey).inserted }

        self.catalogGroups = canonicalGroups
        self.currentCustomRows = canonicalCurrent
        self.savedCustomRows = canonicalSaved
        self.favoriteRows = canonicalFavorites
        self.recentRows = canonicalRecents
        self.catalogRows = canonicalCatalog
        self.selectedCatalogOption = selected
        let compactSelection = selected ?? canonicalCurrent.first
        let compactExcludedKeys = Set(canonicalFavorites.map(\.favoriteKey) + canonicalRecents.map(\.favoriteKey))
        var canonicalCompactMenu: [ModelCatalogOption] = []
        if let compactSelection,
           !compactExcludedKeys.contains(compactSelection.favoriteKey) {
            canonicalCompactMenu = [compactSelection]
        }

        self.sheetRows = canonicalCurrent + canonicalFavorites + canonicalRecents + canonicalSaved + canonicalCatalog
        self.compactRows = canonicalFavorites + canonicalRecents + canonicalCompactMenu
        self.usefulRowPresent = !(canonicalCurrent + canonicalFavorites + canonicalRecents + canonicalSaved).isEmpty
    }

    private static func canonicalGroups(_ groups: [ModelCatalogGroup]) -> [ModelCatalogGroup] {
        var groupIndex: [String: Int] = [:]
        var result: [ModelCatalogGroup] = []

        for group in groups {
            let groupKey = "\(group.id)\u{1F}\(group.providerID ?? "")"
            let models = uniqueOptions(group.models)
            let extraModels = uniqueOptions(group.extraModels)

            if let index = groupIndex[groupKey] {
                let existing = result[index]
                result[index] = ModelCatalogGroup(
                    id: existing.id,
                    name: existing.name,
                    providerID: existing.providerID,
                    models: uniqueOptions(existing.models + models),
                    extraModels: uniqueOptions(existing.extraModels + extraModels)
                )
            } else {
                groupIndex[groupKey] = result.count
                result.append(
                    ModelCatalogGroup(
                        id: group.id,
                        name: group.name,
                        providerID: group.providerID,
                        models: models,
                        extraModels: extraModels
                    )
                )
            }
        }

        return result
    }

    private static func uniqueOptions(_ options: [ModelCatalogOption]) -> [ModelCatalogOption] {
        var seen = Set<ModelFavoriteKey>()
        return options.filter { seen.insert($0.favoriteKey).inserted }
    }

    private static func uniqueKeys(_ keys: [ModelFavoriteKey]) -> [ModelFavoriteKey] {
        var seen = Set<ModelFavoriteKey>()
        return keys.filter { seen.insert($0).inserted }
    }

    private static func resolvedRows(
        keys: [ModelFavoriteKey],
        optionsByKey: [ModelFavoriteKey: ModelCatalogOption]
    ) -> [ModelCatalogOption] {
        uniqueKeys(keys).map { key in
            optionsByKey[key]
                ?? ModelCatalogOption(id: key.modelID, displayName: key.modelID, providerID: key.providerID)
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
