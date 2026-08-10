import CryptoKit
import Foundation

enum MemorySection: String, CaseIterable, Decodable, Encodable, Equatable, Identifiable {
    case memory
    case user
    case soul

    var id: String { rawValue }
}

struct MemoryResponse: Decodable, Equatable {
    let memory: String?
    let user: String?
    let soul: String?
    let memoryPath: String?
    let userPath: String?
    let soulPath: String?
    let memoryMtime: Double?
    let userMtime: Double?
    let soulMtime: Double?
    let projectContext: String?
    let projectContextName: String?
    let projectContextPath: String?
    let projectContextWorkspace: String?
    let projectContextMtime: Double?
    let projectContextShadowed: Bool?
    let externalNotesEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case memory
        case user
        case soul
        case memoryPath
        case userPath
        case soulPath
        case memoryMtime
        case userMtime
        case soulMtime
        case projectContext
        case projectContextName
        case projectContextPath
        case projectContextWorkspace
        case projectContextMtime
        case projectContextShadowed
        case externalNotesEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        memory = try container.decodeIfPresent(String.self, forKey: .memory)
        user = try container.decodeIfPresent(String.self, forKey: .user)
        soul = try container.decodeIfPresent(String.self, forKey: .soul)
        memoryPath = try container.decodeIfPresent(String.self, forKey: .memoryPath)
        userPath = try container.decodeIfPresent(String.self, forKey: .userPath)
        soulPath = try container.decodeIfPresent(String.self, forKey: .soulPath)
        memoryMtime = try container.decodeFlexibleDoubleIfPresent(forKey: .memoryMtime)
        userMtime = try container.decodeFlexibleDoubleIfPresent(forKey: .userMtime)
        soulMtime = try container.decodeFlexibleDoubleIfPresent(forKey: .soulMtime)
        projectContext = try container.decodeIfPresent(String.self, forKey: .projectContext)
        projectContextName = try container.decodeIfPresent(String.self, forKey: .projectContextName)
        projectContextPath = try container.decodeIfPresent(String.self, forKey: .projectContextPath)
        projectContextWorkspace = try container.decodeIfPresent(
            String.self,
            forKey: .projectContextWorkspace
        )
        projectContextMtime = try container.decodeFlexibleDoubleIfPresent(forKey: .projectContextMtime)
        // Upstream (routes.py @ 312d3fab, verified live 2026-07-03) returns a *list* of
        // shadowed-file objects here; the API docs describe a boolean flag. Accept both:
        // `true` or a non-empty list means the active document shadows another file.
        if let flag = try? container.decode(Bool.self, forKey: .projectContextShadowed) {
            projectContextShadowed = flag
        } else if let list = try? container.nestedUnkeyedContainer(forKey: .projectContextShadowed) {
            projectContextShadowed = (list.count ?? 0) > 0
        } else {
            projectContextShadowed = nil
        }
        externalNotesEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .externalNotesEnabled)) ?? nil
    }
}

struct MemoryWriteResponse: Decodable, Equatable {
    let ok: Bool?
    let section: MemorySection?
    let path: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case section
        case path
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok)
        if let rawSection = try container.decodeIfPresent(String.self, forKey: .section) {
            section = MemorySection(rawValue: rawSection)
        } else {
            section = nil
        }
        path = try container.decodeIfPresent(String.self, forKey: .path)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

// MARK: - Raw memory API (Hermex #19, v1)

/// Fixed raw Memory selectors (§19): only these four sources exist; no arbitrary
/// workspace or path input is ever accepted.
enum MemoryRawSource: CaseIterable, Equatable {
    case memory
    case user
    case soul
    case projectContext

    /// Exact wire value for the `source` query parameter.
    var wireValue: String {
        switch self {
        case .memory: return "memory"
        case .user: return "user"
        case .soul: return "soul"
        case .projectContext: return "project_context"
        }
    }

    /// Canonical basename the envelope must carry for this source.
    var canonicalName: String {
        switch self {
        case .memory: return "MEMORY.md"
        case .user: return "USER.md"
        case .soul: return "SOUL.md"
        case .projectContext: return "AGENTS.md"
        }
    }
}

/// SHA-256 checksum carried by the raw envelope (§11).
struct MemoryRawChecksum: Equatable {
    let algorithm: String
    let value: String
}

/// Byte-faithful raw Memory envelope (§11).
///
/// The decoder retains the exact source `Data` (never a `String` reconstruction):
/// invalid UTF-8, NUL bytes, lone CRs, and BOMs survive untouched. It rejects
/// noncanonical base64, verifies `byte_length`, the SHA-256 `checksum.value`,
/// the exact lowercase `source_version`, the fixed source/name/schema/content
/// type, and the quoted `"repr-sha256:<64 lowercase hex>"` representation ETag
/// (which is never confused with `source_version`).
struct MemoryRawResponse {
    let source: String
    let name: String
    let schemaVersion: Int
    let contentType: String
    let byteEncoding: String
    let byteLength: Int
    let checksum: MemoryRawChecksum
    let sourceVersion: String
    let etag: String
    /// The original source bytes, retained exactly as received.
    let data: Data

    init(data: Data, etag: String) throws {
        try Self.validateRepresentationETag(etag)

        let envelope: MemoryRawEnvelope
        do {
            envelope = try JSONDecoder().decode(MemoryRawEnvelope.self, from: data)
        } catch {
            throw MemoryRawError.invalidEnvelope
        }

        // Canonical padded RFC 4648 base64 only: standard alphabet, no
        // whitespace/line wrapping, padding exactly matching byte_length (§11).
        guard envelope.byteEncoding == "base64" else {
            throw MemoryRawError.invalidEnvelope
        }
        let decoded = try Self.decodeCanonicalBase64(envelope.data, byteLength: envelope.byteLength)

        // SHA-256 over the original source bytes must equal checksum.value.
        guard envelope.checksum.algorithm == "sha-256" else {
            throw MemoryRawError.invalidEnvelope
        }
        let computed = Self.sha256Hex(of: decoded)
        guard computed == envelope.checksum.value else {
            throw MemoryRawError.checksumMismatch(computed: computed, received: envelope.checksum.value)
        }

        // source_version is the exact lowercase source-byte identity.
        let expectedSourceVersion = "sha256:\(computed)"
        guard envelope.sourceVersion == expectedSourceVersion else {
            throw MemoryRawError.sourceVersionMismatch(
                expected: expectedSourceVersion,
                received: envelope.sourceVersion
            )
        }

        // Fixed selector envelope: source ∈ {memory, user, soul, project_context}
        // with the canonical basename for that source, schema_version 1, and the
        // fixed content type (§11/§19).
        guard let source = MemoryRawSource.allCases.first(where: { $0.wireValue == envelope.source }),
              envelope.name == source.canonicalName,
              envelope.schemaVersion == 1,
              envelope.contentType == "text/markdown" else {
            throw MemoryRawError.invalidEnvelope
        }

        self.source = envelope.source
        self.name = envelope.name
        self.schemaVersion = envelope.schemaVersion
        self.contentType = envelope.contentType
        self.byteEncoding = envelope.byteEncoding
        self.byteLength = envelope.byteLength
        self.checksum = MemoryRawChecksum(
            algorithm: envelope.checksum.algorithm,
            value: envelope.checksum.value
        )
        self.sourceVersion = envelope.sourceVersion
        self.etag = etag
        self.data = decoded
    }

    // MARK: Validation helpers

    private static func validateRepresentationETag(_ etag: String) throws {
        // Exact quoted form "repr-sha256:<64 lowercase hex>" (§11); deliberately
        // distinct from the unquoted "sha256:…" source_version.
        guard etag.range(
            of: #"^"repr-sha256:[0-9a-f]{64}"$"#,
            options: .regularExpression
        ) != nil else {
            throw MemoryRawError.invalidETag(received: etag)
        }
    }

    private static func decodeCanonicalBase64(_ encoded: String, byteLength: Int) throws -> Data {
        // Standard alphabet only, up to two trailing padding characters.
        guard encoded.count % 4 == 0,
              encoded.range(
                of: "^[A-Za-z0-9+/]*={0,2}$",
                options: .regularExpression
              ) != nil else {
            throw MemoryRawError.nonCanonicalBase64
        }

        // Padding must be exactly what byte_length implies: none for len % 3 == 0,
        // "==" for len % 3 == 1, "=" for len % 3 == 2 (§11 canonical form).
        let paddingCount = encoded.hasSuffix("==") ? 2 : (encoded.hasSuffix("=") ? 1 : 0)
        let expectedPadding: Int
        switch byteLength % 3 {
        case 1: expectedPadding = 2
        case 2: expectedPadding = 1
        default: expectedPadding = 0
        }
        guard paddingCount == expectedPadding else {
            throw MemoryRawError.nonCanonicalBase64
        }

        // Strict decode; decode and re-encode must reproduce the received padded
        // string exactly (§19). Foundation is lenient about missing padding and
        // non-zero trailing bits, so the round-trip is the canonicality check.
        guard let decoded = Data(base64Encoded: encoded),
              decoded.base64EncodedString() == encoded else {
            throw MemoryRawError.nonCanonicalBase64
        }

        guard decoded.count == byteLength else {
            throw MemoryRawError.byteLengthMismatch(declared: byteLength, decoded: decoded.count)
        }
        return decoded
    }

    private static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Raw envelope errors (Hermex #19). Client-path and decoder-path failures are
/// distinct from the generic `APIError`; V1 adds none of them to
/// `CacheFallbackPolicy`.
enum MemoryRawError: Error, Equatable {
    case invalidETag(received: String)
    case nonCanonicalBase64
    case byteLengthMismatch(declared: Int, decoded: Int)
    case checksumMismatch(computed: String, received: String)
    case invalidEnvelope
    case sourceVersionMismatch(expected: String, received: String)
    case sourceMismatch(requested: String, received: String)
    case unexpectedNotModified
}

/// Tolerant wire envelope (§11): unknown additive fields are ignored.
private struct MemoryRawEnvelope: Decodable {
    let schemaVersion: Int
    let source: String
    let name: String
    let contentType: String
    let byteLength: Int
    let byteEncoding: String
    let data: String
    let checksum: MemoryRawEnvelopeChecksum
    let sourceVersion: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case source
        case name
        case contentType = "content_type"
        case byteLength = "byte_length"
        case byteEncoding = "byte_encoding"
        case data
        case checksum
        case sourceVersion = "source_version"
    }
}

private struct MemoryRawEnvelopeChecksum: Decodable {
    let algorithm: String
    let value: String
}
