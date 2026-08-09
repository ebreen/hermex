import Foundation

/// Resolves the effective app-group identifier shared by the app, the Share
/// Extension, and the Live Activity widget.
///
/// SideStore (and AltStore) re-signs an installed IPA with the installer's
/// profiles and remaps every app group to an installer-team-specific identifier.
/// The processed app records those values in `Info.plist` under `ALTAppGroups`.
/// SideStore constructs each remapped value as `<group identifier>.<team.identifier>`;
/// the resolver therefore has to match our configured base at a component
/// boundary rather than accepting arbitrary prefix or suffix text.
enum HermesAppGroupResolver {
    /// The build-time group identifier declared in `Config/Shared.xcconfig`.
    static let canonicalIdentifier = "group.no.gior.hermex"

    enum Error: Swift.Error, Equatable {
        /// `ALTAppGroups` is present but contains no valid remap for the
        /// configured group (SideStore processed a different set of groups).
        case unrelatedSideStoreGroups
        /// More than one `ALTAppGroups` entry corresponds to the configured
        /// group; writing to either would be arbitrary.
        case ambiguousMatchingGroups
        /// `ALTAppGroups` is present but is not an array of strings.
        case malformedSideStoreGroups
    }

    /// The effective group identifier: the SideStore-remapped counterpart when
    /// `ALTAppGroups` is present, otherwise the configured build-time value.
    ///
    /// SideStore's signing path appends exactly one team identifier component to
    /// each source group (`<base>.<team.identifier>`). Exactly one valid remap
    /// is required; zero or multiple fail visibly instead of silently writing to
    /// an arbitrary container. An exact base value is not a remap when the key
    /// is present because SideStore always appends the team component.
    ///
    /// - Parameters:
    ///   - infoDictionary: The processed app's Info.plist dictionary. Defaults
    ///     to `Bundle.main.infoDictionary`; injectable for tests.
    static func effectiveAppGroupIdentifier(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) throws -> String {
        let baseIdentifier = configuredBaseIdentifier(from: infoDictionary)

        guard let rawGroups = infoDictionary?["ALTAppGroups"] else {
            // A normal Xcode/local build has no SideStore remapping.
            return baseIdentifier
        }
        guard let groups = rawGroups as? [String] else {
            throw Error.malformedSideStoreGroups
        }
        if groups.isEmpty {
            throw Error.unrelatedSideStoreGroups
        }

        let matching = groups.filter {
            isValidRemappedIdentifier($0, baseIdentifier: baseIdentifier)
        }
        guard matching.count == 1 else {
            if matching.isEmpty {
                throw Error.unrelatedSideStoreGroups
            }
            throw Error.ambiguousMatchingGroups
        }

        // A related-looking but malformed entry must not be silently ignored
        // when a valid entry is also present.
        let hasMalformedRelatedEntry = groups.contains { candidate in
            candidate == baseIdentifier
                || (candidate.hasPrefix(baseIdentifier + ".")
                    && !isValidRemappedIdentifier(candidate, baseIdentifier: baseIdentifier))
        }
        if hasMalformedRelatedEntry {
            throw Error.unrelatedSideStoreGroups
        }

        guard groups.allSatisfy({
            isValidRemappedIdentifier($0, baseIdentifier: baseIdentifier)
        }) else {
            throw Error.unrelatedSideStoreGroups
        }

        return matching[0]
    }

    private static func configuredBaseIdentifier(from infoDictionary: [String: Any]?) -> String {
        guard let configured = infoDictionary?["HermesAppGroupIdentifier"] as? String,
              isValidGroupIdentifier(configured) else {
            return canonicalIdentifier
        }
        return configured
    }

    private static func isValidRemappedIdentifier(
        _ candidate: String,
        baseIdentifier: String
    ) -> Bool {
        let prefix = baseIdentifier + "."
        guard candidate.hasPrefix(prefix) else {
            return false
        }

        let teamComponent = candidate.dropFirst(prefix.count)
        return isValidIdentifierComponent(teamComponent)
    }

    private static func isValidGroupIdentifier(_ identifier: String) -> Bool {
        guard identifier == identifier.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }

        let components = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2, String(components[0]) == "group" else {
            return false
        }
        return components.dropFirst().allSatisfy { component in
            isValidIdentifierComponent(component)
        }
    }

    /// App-group and team identifiers use non-empty dot-separated ASCII
    /// identifier components. The remap parser passes only the text after the
    /// one required boundary, so any additional dot is rejected here.
    private static func isValidIdentifierComponent(_ component: Substring) -> Bool {
        guard !component.isEmpty else {
            return false
        }

        return component.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (value >= 48 && value <= 57) // 0-9
                || (value >= 65 && value <= 90) // A-Z
                || (value >= 97 && value <= 122) // a-z
                || value == 45 // hyphen
        }
    }
}
