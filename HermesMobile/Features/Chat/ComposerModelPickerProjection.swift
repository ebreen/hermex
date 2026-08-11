import Foundation

/// Slice 5 prerequisite surface. Behavior is defined by the following RED
/// tests and implemented in the subsequent GREEN commit.
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
    let usefulRowPresent: Bool

    var compactMenuRows: [ModelCatalogOption] { [] }
    var sheetGroups: [ModelCatalogGroup] { [] }

    init(
        modelGroups: [ModelCatalogGroup],
        selectedModelID: String? = nil,
        selectedModelProviderID: String? = nil,
        favoriteModelKeys: [ModelFavoriteKey] = [],
        recentModelKeys: [ModelFavoriteKey] = [],
        savedCustomOptions: [ModelCatalogOption] = []
    ) {
        catalogGroups = modelGroups
        currentCustomRows = []
        savedCustomRows = []
        favoriteRows = []
        recentRows = []
        catalogRows = []
        selectedCatalogOption = nil
        sheetRows = []
        compactRows = []
        usefulRowPresent = false
    }
}
