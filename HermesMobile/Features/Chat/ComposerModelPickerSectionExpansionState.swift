import Foundation

struct ComposerModelPickerSectionExpansionState {
    private var expandedGroupIDs: Set<String> = []
    private var collapsedSearchGroupIDs: Set<String> = []
    private var searchQuery = ""
    private var isUserControlled = false
    private var didAutoExpand = false

    mutating func updateSearchText(_ searchText: String) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != searchQuery else { return }

        searchQuery = query
        collapsedSearchGroupIDs.removeAll()
    }

    func isExpanded(groupID: String) -> Bool {
        if searchQuery.isEmpty {
            return expandedGroupIDs.contains(groupID)
        }

        return !collapsedSearchGroupIDs.contains(groupID)
    }

    mutating func setExpanded(_ isExpanded: Bool, groupID: String) {
        isUserControlled = true

        if searchQuery.isEmpty {
            if isExpanded {
                expandedGroupIDs.insert(groupID)
            } else {
                expandedGroupIDs.remove(groupID)
            }
        } else if isExpanded {
            collapsedSearchGroupIDs.remove(groupID)
        } else {
            collapsedSearchGroupIDs.insert(groupID)
        }
    }

    /// Expands only the first non-empty catalog group when no useful fallback
    /// row is available. Automatic expansion is one-shot and is permanently
    /// fenced by any user toggle.
    mutating func autoExpandFirstNonEmptyGroup(
        in groups: [ModelCatalogGroup],
        usefulRowPresent: Bool
    ) {
        guard !isUserControlled,
              !didAutoExpand,
              searchQuery.isEmpty,
              !usefulRowPresent,
              let group = groups.first(where: { !$0.models.isEmpty })
        else {
            return
        }

        expandedGroupIDs.insert(group.id)
        didAutoExpand = true
    }
}
