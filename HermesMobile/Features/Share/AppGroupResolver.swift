import Foundation

/// Resolves the effective app-group identifier shared by the app, the Share
/// Extension, and the Live Activity widget.
///
/// SideStore (and AltStore) re-signs an installed IPA with the installer's
/// profiles and REMAPS every app group to an installer-specific identifier.
/// The remapped values are written into the processed app's `Info.plist` under
/// the `ALTAppGroups` key, and the extension/profile-side entitlements use the
/// same remapped values. Writing to the build-time canonical group after a
/// SideStore install would create a separate container that the extension
/// never sees, silently breaking share-draft handoff — so when `ALTAppGroups`
/// is present we must resolve the remapped counterpart of our own group.
enum HermesAppGroupResolver {
    /// The build-time group identifier declared in `Config/Shared.xcconfig`.
    static let canonicalIdentifier = "group.no.gior.hermex"

    enum Error: Swift.Error, Equatable {
        /// `ALTAppGroups` is present but contains no entry that corresponds to
        /// the canonical group (SideStore processed a different set of groups).
        case unrelatedSideStoreGroups
        /// More than one `ALTAppGroups` entry corresponds to the canonical
        /// group; writing to either would be arbitrary.
        case ambiguousMatchingGroups
        /// `ALTAppGroups` is present but is not an array of strings.
        case malformedSideStoreGroups
    }

    /// The effective group identifier: the SideStore-remapped counterpart when
    /// `ALTAppGroups` is present, otherwise the canonical build-time value.
    ///
    /// A remapped entry "corresponds" to the canonical group when its value
    /// ends with the canonical identifier (SideStore prefixes its own
    /// installer namespace to the original group id). Exactly one matching
    /// entry is required; zero or multiple fail visibly instead of silently
    /// writing to an arbitrary container.
    ///
    /// - Parameters:
    ///   - infoDictionary: The processed app's Info.plist dictionary. Defaults
    ///     to `Bundle.main.infoDictionary`; injectable for tests.
    static func effectiveAppGroupIdentifier(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) throws -> String {
        guard let rawGroups = infoDictionary?["ALTAppGroups"] else {
            // A normal Xcode/local build has no SideStore remapping.
            return canonicalIdentifier
        }
        guard let groups = rawGroups as? [String], !groups.isEmpty else {
            throw Error.malformedSideStoreGroups
        }
        let matching = groups.filter { $0.hasSuffix(canonicalIdentifier) }
        guard matching.count == 1 else {
            if matching.isEmpty {
                throw Error.unrelatedSideStoreGroups
            }
            throw Error.ambiguousMatchingGroups
        }
        return matching[0]
    }
}
