// MemoryRawReaderTests.swift
//
// Hermex #19 RED (tests-only): byte-faithful raw Memory API reader.
//
// Binding contract: /tmp/hermex-memory-raw-api-issue-v6.md §19 (Hermex #19
// handoff), §11 (byte-faithful envelope), and §13 (normative wire fixture,
// SHA-256 e1d6c0c17695f7f21bc69ba5780cab50bd699fedc9d89b1131170b50b324f7a5).
// Live issue: ebreen/hermex#19 "Add byte-faithful raw Memory reading".
// Frozen base: origin/master 682c33cc893a2c03fe7c25c8d8e08de8a6ebd3fe.
//
// RED expectation on the frozen code: every reader symbol referenced below
// (MemoryRawSource, MemoryRawChecksum, MemoryRawResponse, MemoryRawError,
// APIClient.rawMemory) is absent from the repo at the frozen SHA (verified by
// repo-wide grep: 0 occurrences outside this file), so the native run is a
// compile RED limited to "cannot find 'X' in scope" diagnostics confined to
// this file. No production declaration is added here.
//
// V1 reader slice scope (§19): the fixture's nine canonical 200 byte cases and
// the exact bodyless 304 are embedded verbatim; the raw decoder must reject
// noncanonical base64, verify byte_length, SHA-256 checksum.value, exact
// lowercase source-byte source_version, source/name/schema/content type, and
// retain the original Data; a 200 ETag must validate as the quoted exact
// "repr-sha256:<64 lowercase hex>" representation tag, never confused with
// source_version; login's configured auth cookie must be stored by URLSession
// and sent on the following raw request; the raw request must not add a
// trusted identity, API key, profile cookie, or arbitrary workspace/path; V1
// sends no If-None-Match, keeps no offline/persistent cache, adds nothing to
// CacheFallbackPolicy, and treats a bodyless 304 without a retained identity
// as a protocol error on the explicit raw path.
//
// Deferred to later slices: the raw read-only UI projection surface (§19 last
// paragraph), conditional If-None-Match request support, and PBX registration
// of this file (repo convention: a separate build/registration slice, cf.
// issue/17-registration).
//
// Determinism discipline: no sleeps, no wall-clock reads, no randomness, no
// shared mutable statics; every test releases all state before returning
// (tearDown clears MockURLProtocol.requestHandler) and is safe under parallel
// worker execution.

import CryptoKit
import XCTest

@testable import HermesMobile

// MARK: - Normative fixture (§13; the full JSON is committed in the WebUI fork
// as tests/fixtures/memory_raw_v1.json — this file embeds the byte cases and
// the 304 fixture verbatim)

private struct MemoryRawFixtureCase {
    let id: String
    let sourceBase64: String
    let sourceByteLength: Int
    let sourceSHA256: String
    let sourceVersion: String
    let bodyBase64: String
    let bodyByteLength: Int
    let representationSHA256: String
    let etag: String
}

private struct MemoryRaw304Fixture {
    let caseID: String
    let etag: String
    let date: String
    let cacheControl: String
    let absentHeaders: [String]
}

private enum MemoryRawFixture {
    /// SHA-256 of the verified §13 fixture file
    /// /tmp/memory_raw_v1_complete_response_cases.json.
    static let fileSHA256 = "e1d6c0c17695f7f21bc69ba5780cab50bd699fedc9d89b1131170b50b324f7a5"
    static let endpoint = "/api/memory/raw"
    static let schemaVersion = 1
    static let contentType = "text/markdown"
    static let canonicalSource = "memory"
    static let canonicalName = "MEMORY.md"
    static let byteEncoding = "base64"

    static let cases: [MemoryRawFixtureCase] = [
                MemoryRawFixtureCase(
            id: "empty",
            sourceBase64: "",
            sourceByteLength: 0,
            sourceSHA256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            sourceVersion: "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            bodyBase64: "eyJieXRlX2VuY29kaW5nIjoiYmFzZTY0IiwiYnl0ZV9sZW5ndGgiOjAsImNoZWNrc3VtIjp7ImFsZ29yaXRobSI6InNoYS0yNTYiLCJ2YWx1ZSI6ImUzYjBjNDQyOThmYzFjMTQ5YWZiZjRjODk5NmZiOTI0MjdhZTQxZTQ2NDliOTM0Y2E0OTU5OTFiNzg1MmI4NTUifSwiY29udGVudF90eXBlIjoidGV4dC9tYXJrZG93biIsImRhdGEiOiIiLCJuYW1lIjoiTUVNT1JZLm1kIiwic2NoZW1hX3ZlcnNpb24iOjEsInNvdXJjZSI6Im1lbW9yeSIsInNvdXJjZV92ZXJzaW9uIjoic2hhMjU2OmUzYjBjNDQyOThmYzFjMTQ5YWZiZjRjODk5NmZiOTI0MjdhZTQxZTQ2NDliOTM0Y2E0OTU5OTFiNzg1MmI4NTUifQ==",
            bodyByteLength: 340,
            representationSHA256: "8829176d33e19efc10eeea806dd5db96585b82b2d6e122d1d949948e2059b31d",
            etag: "\"repr-sha256:8829176d33e19efc10eeea806dd5db96585b82b2d6e122d1d949948e2059b31d\"",
        ),
        MemoryRawFixtureCase(
            id: "lf",
            sourceBase64: "IyBOb3RlCmxpbmUK",
            sourceByteLength: 12,
            sourceSHA256: "bb89a6e8128d049f4225932f9de463fef2e992c8a439b20ebb17b3792ddac3d2",
            sourceVersion: "sha256:bb89a6e8128d049f4225932f9de463fef2e992c8a439b20ebb17b3792ddac3d2",
            bodyBase64: "eyJieXRlX2VuY29kaW5nIjoiYmFzZTY0IiwiYnl0ZV9sZW5ndGgiOjEyLCJjaGVja3N1bSI6eyJhbGdvcml0aG0iOiJzaGEtMjU2IiwidmFsdWUiOiJiYjg5YTZlODEyOGQwNDlmNDIyNTkzMmY5ZGU0NjNmZWYyZTk5MmM4YTQzOWIyMGViYjE3YjM3OTJkZGFjM2QyIn0sImNvbnRlbnRfdHlwZSI6InRleHQvbWFya2Rvd24iLCJkYXRhIjoiSXlCT2IzUmxDbXhwYm1VSyIsIm5hbWUiOiJNRU1PUlkubWQiLCJzY2hlbWFfdmVyc2lvbiI6MSwic291cmNlIjoibWVtb3J5Iiwic291cmNlX3ZlcnNpb24iOiJzaGEyNTY6YmI4OWE2ZTgxMjhkMDQ5ZjQyMjU5MzJmOWRlNDYzZmVmMmU5OTJjOGE0MzliMjBlYmIxN2IzNzkyZGRhYzNkMiJ9",
            bodyByteLength: 357,
            representationSHA256: "8f85cc4d4f79e33cf20327f216df9ddaba87799b17c033ade0620848d24036db",
            etag: "\"repr-sha256:8f85cc4d4f79e33cf20327f216df9ddaba87799b17c033ade0620848d24036db\"",
        ),
        MemoryRawFixtureCase(
            id: "crlf",
            sourceBase64: "IyBOb3RlDQpsaW5lDQo=",
            sourceByteLength: 14,
            sourceSHA256: "d9c02d2bfdce68cdbd1b16b0efe7df7a7b48f85738e59f56cda4876c0b9a8107",
            sourceVersion: "sha256:d9c02d2bfdce68cdbd1b16b0efe7df7a7b48f85738e59f56cda4876c0b9a8107",
            bodyBase64: "eyJieXRlX2VuY29kaW5nIjoiYmFzZTY0IiwiYnl0ZV9sZW5ndGgiOjE0LCJjaGVja3N1bSI6eyJhbGdvcml0aG0iOiJzaGEtMjU2IiwidmFsdWUiOiJkOWMwMmQyYmZkY2U2OGNkYmQxYjE2YjBlZmU3ZGY3YTdiNDhmODU3MzhlNTlmNTZjZGE0ODc2YzBiOWE4MTA3In0sImNvbnRlbnRfdHlwZSI6InRleHQvbWFya2Rvd24iLCJkYXRhIjoiSXlCT2IzUmxEUXBzYVc1bERRbz0iLCJuYW1lIjoiTUVNT1JZLm1kIiwic2NoZW1hX3ZlcnNpb24iOjEsInNvdXJjZSI6Im1lbW9yeSIsInNvdXJjZV92ZXJzaW9uIjoic2hhMjU2OmQ5YzAyZDJiZmRjZTY4Y2RiZDFiMTZiMGVmZTdkZjdhN2I0OGY4NTczOGU1OWY1NmNkYTQ4NzZjMGI5YTgxMDcifQ==",
            bodyByteLength: 361,
            representationSHA256: "4663201cd67c35e6118af34da733f0275aadb81e6b043d24c705061d0a678038",
            etag: "\"repr-sha256:4663201cd67c35e6118af34da733f0275aadb81e6b043d24c705061d0a678038\"",
        ),
        MemoryRawFixtureCase(
            id: "lone_cr",
            sourceBase64: "IyBOb3RlDWxpbmUN",
            sourceByteLength: 12,
            sourceSHA256: "966c64841082d9f9a29e7e20aa17c772b70fb8890c802dd5fd2472103914ee11",
            sourceVersion: "sha256:966c64841082d9f9a29e7e20aa17c772b70fb8890c802dd5fd2472103914ee11",
            bodyBase64: "eyJieXRlX2VuY29kaW5nIjoiYmFzZTY0IiwiYnl0ZV9sZW5ndGgiOjEyLCJjaGVja3N1bSI6eyJhbGdvcml0aG0iOiJzaGEtMjU2IiwidmFsdWUiOiI5NjZjNjQ4NDEwODJkOWY5YTI5ZTdlMjBhYTE3Yzc3MmI3MGZiODg5MGM4MDJkZDVmZDI0NzIxMDM5MTRlZTExIn0sImNvbnRlbnRfdHlwZSI6InRleHQvbWFya2Rvd24iLCJkYXRhIjoiSXlCT2IzUmxEV3hwYm1VTiIsIm5hbWUiOiJNRU1PUlkubWQiLCJzY2hlbWFfdmVyc2lvbiI6MSwic291cmNlIjoibWVtb3J5Iiwic291cmNlX3ZlcnNpb24iOiJzaGEyNTY6OTY2YzY0ODQxMDgyZDlmOWEyOWU3ZTIwYWExN2M3NzJiNzBmYjg4OTBjODAyZGQ1ZmQyNDcyMTAzOTE0ZWUxMSJ9",
            bodyByteLength: 357,
            representationSHA256: "1068b80a49dc96f2d9c93bba23a70bad38951866444a292538a71c94216efcc2",
            etag: "\"repr-sha256:1068b80a49dc96f2d9c93bba23a70bad38951866444a292538a71c94216efcc2\"",
        ),
        MemoryRawFixtureCase(
            id: "bom",
            sourceBase64: "77u/IyBCT00K",
            sourceByteLength: 9,
            sourceSHA256: "23187f7066404a1546c697c434ea62a35dc86ed07b6829e134fe19365bcc3fde",
            sourceVersion: "sha256:23187f7066404a1546c697c434ea62a35dc86ed07b6829e134fe19365bcc3fde",
            bodyBase64: "eyJieXRlX2VuY29kaW5nIjoiYmFzZTY0IiwiYnl0ZV9sZW5ndGgiOjksImNoZWNrc3VtIjp7ImFsZ29yaXRobSI6InNoYS0yNTYiLCJ2YWx1ZSI6IjIzMTg3ZjcwNjY0MDRhMTU0NmM2OTdjNDM0ZWE2MmEzNWRjODZlZDA3YjY4MjllMTM0ZmUxOTM2NWJjYzNmZGUifSwiY29udGVudF90eXBlIjoidGV4dC9tYXJrZG93biIsImRhdGEiOiI3N3UvSXlCQ1QwMEsiLCJuYW1lIjoiTUVNT1JZLm1kIiwic2NoZW1hX3ZlcnNpb24iOjEsInNvdXJjZSI6Im1lbW9yeSIsInNvdXJjZV92ZXJzaW9uIjoic2hhMjU2OjIzMTg3ZjcwNjY0MDRhMTU0NmM2OTdjNDM0ZWE2MmEzNWRjODZlZDA3YjY4MjllMTM0ZmUxOTM2NWJjYzNmZGUifQ==",
            bodyByteLength: 352,
            representationSHA256: "1755e3b0f02ec588da364ad35e2d901f36d2047108833f515b2e8fa79f73a149",
            etag: "\"repr-sha256:1755e3b0f02ec588da364ad35e2d901f36d2047108833f515b2e8fa79f73a149\"",
        ),
        MemoryRawFixtureCase(
            id: "nul",
            sourceBase64: "cHJlAHBvc3QK",
            sourceByteLength: 9,
            sourceSHA256: "1ccf85868308046c00e130e5324747546191811d022188d2bcbd3f4270ee9eed",
            sourceVersion: "sha256:1ccf85868308046c00e130e5324747546191811d022188d2bcbd3f4270ee9eed",
            bodyBase64: "eyJieXRlX2VuY29kaW5nIjoiYmFzZTY0IiwiYnl0ZV9sZW5ndGgiOjksImNoZWNrc3VtIjp7ImFsZ29yaXRobSI6InNoYS0yNTYiLCJ2YWx1ZSI6IjFjY2Y4NTg2ODMwODA0NmMwMGUxMzBlNTMyNDc0NzU0NjE5MTgxMWQwMjIxODhkMmJjYmQzZjQyNzBlZTllZWQifSwiY29udGVudF90eXBlIjoidGV4dC9tYXJrZG93biIsImRhdGEiOiJjSEpsQUhCdmMzUUsiLCJuYW1lIjoiTUVNT1JZLm1kIiwic2NoZW1hX3ZlcnNpb24iOjEsInNvdXJjZSI6Im1lbW9yeSIsInNvdXJjZV92ZXJzaW9uIjoic2hhMjU2OjFjY2Y4NTg2ODMwODA0NmMwMGUxMzBlNTMyNDc0NzU0NjE5MTgxMWQwMjIxODhkMmJjYmQzZjQyNzBlZTllZWQifQ==",
            bodyByteLength: 352,
            representationSHA256: "949af6110e095baa340b7c9d14a1c04eb7b57efe2fa9f482e8bfe1e7faf7423a",
            etag: "\"repr-sha256:949af6110e095baa340b7c9d14a1c04eb7b57efe2fa9f482e8bfe1e7faf7423a\"",
        ),
        MemoryRawFixtureCase(
            id: "missing_final_newline",
            sourceBase64: "IyBubyBmaW5hbCBuZXdsaW5l",
            sourceByteLength: 18,
            sourceSHA256: "16046c0bd0f30645a7b41b84c5b68d75fecf52a5148605683a248ac6ad267c1f",
            sourceVersion: "sha256:16046c0bd0f30645a7b41b84c5b68d75fecf52a5148605683a248ac6ad267c1f",
            bodyBase64: "eyJieXRlX2VuY29kaW5nIjoiYmFzZTY0IiwiYnl0ZV9sZW5ndGgiOjE4LCJjaGVja3N1bSI6eyJhbGdvcml0aG0iOiJzaGEtMjU2IiwidmFsdWUiOiIxNjA0NmMwYmQwZjMwNjQ1YTdiNDFiODRjNWI2OGQ3NWZlY2Y1MmE1MTQ4NjA1NjgzYTI0OGFjNmFkMjY3YzFmIn0sImNvbnRlbnRfdHlwZSI6InRleHQvbWFya2Rvd24iLCJkYXRhIjoiSXlCdWJ5Qm1hVzVoYkNCdVpYZHNhVzVsIiwibmFtZSI6Ik1FTU9SWS5tZCIsInNjaGVtYV92ZXJzaW9uIjoxLCJzb3VyY2UiOiJtZW1vcnkiLCJzb3VyY2VfdmVyc2lvbiI6InNoYTI1NjoxNjA0NmMwYmQwZjMwNjQ1YTdiNDFiODRjNWI2OGQ3NWZlY2Y1MmE1MTQ4NjA1NjgzYTI0OGFjNmFkMjY3YzFmIn0=",
            bodyByteLength: 365,
            representationSHA256: "a38d5f2b2204f703b84f035c906eddc4fb840234954705f56e65d52ae7aa5260",
            etag: "\"repr-sha256:a38d5f2b2204f703b84f035c906eddc4fb840234954705f56e65d52ae7aa5260\"",
        ),
        MemoryRawFixtureCase(
            id: "unicode",
            sourceBase64: "Y2Fmw6kg8J+agAo=",
            sourceByteLength: 11,
            sourceSHA256: "23cd04297e92673be523c5657020447b0534fad4ac4d3b6614d3d8588a378f53",
            sourceVersion: "sha256:23cd04297e92673be523c5657020447b0534fad4ac4d3b6614d3d8588a378f53",
            bodyBase64: "eyJieXRlX2VuY29kaW5nIjoiYmFzZTY0IiwiYnl0ZV9sZW5ndGgiOjExLCJjaGVja3N1bSI6eyJhbGdvcml0aG0iOiJzaGEtMjU2IiwidmFsdWUiOiIyM2NkMDQyOTdlOTI2NzNiZTUyM2M1NjU3MDIwNDQ3YjA1MzRmYWQ0YWM0ZDNiNjYxNGQzZDg1ODhhMzc4ZjUzIn0sImNvbnRlbnRfdHlwZSI6InRleHQvbWFya2Rvd24iLCJkYXRhIjoiWTJGbXc2a2c4SithZ0FvPSIsIm5hbWUiOiJNRU1PUlkubWQiLCJzY2hlbWFfdmVyc2lvbiI6MSwic291cmNlIjoibWVtb3J5Iiwic291cmNlX3ZlcnNpb24iOiJzaGEyNTY6MjNjZDA0Mjk3ZTkyNjczYmU1MjNjNTY1NzAyMDQ0N2IwNTM0ZmFkNGFjNGQzYjY2MTRkM2Q4NTg4YTM3OGY1MyJ9",
            bodyByteLength: 357,
            representationSHA256: "b26821d86dc4e0353267812dc0e1a979e674286cf6b158f2c085a0403ea50bc2",
            etag: "\"repr-sha256:b26821d86dc4e0353267812dc0e1a979e674286cf6b158f2c085a0403ea50bc2\"",
        ),
        MemoryRawFixtureCase(
            id: "malformed_utf8",
            sourceBase64: "b2v//go=",
            sourceByteLength: 5,
            sourceSHA256: "cd34063e5c82c2c222b1b641bd2e21679e47a1c7d8f049b8a3058940fbcf351c",
            sourceVersion: "sha256:cd34063e5c82c2c222b1b641bd2e21679e47a1c7d8f049b8a3058940fbcf351c",
            bodyBase64: "eyJieXRlX2VuY29kaW5nIjoiYmFzZTY0IiwiYnl0ZV9sZW5ndGgiOjUsImNoZWNrc3VtIjp7ImFsZ29yaXRobSI6InNoYS0yNTYiLCJ2YWx1ZSI6ImNkMzQwNjNlNWM4MmMyYzIyMmIxYjY0MWJkMmUyMTY3OWU0N2ExYzdkOGYwNDliOGEzMDU4OTQwZmJjZjM1MWMifSwiY29udGVudF90eXBlIjoidGV4dC9tYXJrZG93biIsImRhdGEiOiJiMnYvL2dvPSIsIm5hbWUiOiJNRU1PUlkubWQiLCJzY2hlbWFfdmVyc2lvbiI6MSwic291cmNlIjoibWVtb3J5Iiwic291cmNlX3ZlcnNpb24iOiJzaGEyNTY6Y2QzNDA2M2U1YzgyYzJjMjIyYjFiNjQxYmQyZTIxNjc5ZTQ3YTFjN2Q4ZjA0OWI4YTMwNTg5NDBmYmNmMzUxYyJ9",
            bodyByteLength: 348,
            representationSHA256: "24ad644e8b0ce074bc0f9faea3fee4fbc36a6776613d5addb316d83775d5e8f6",
            etag: "\"repr-sha256:24ad644e8b0ce074bc0f9faea3fee4fbc36a6776613d5addb316d83775d5e8f6\"",
        ),
    ]

    /// Exact authenticated bodyless 304 for the `lf` case (§13 conditional_304).
    static let conditional304 = MemoryRaw304Fixture(
        caseID: "lf",
        etag: "\"repr-sha256:8f85cc4d4f79e33cf20327f216df9ddaba87799b17c033ade0620848d24036db\"",
        date: "Wed, 01 Jan 2025 00:00:00 GMT",
        cacheControl: "private, no-store",
        absentHeaders: ["Content-Length", "Content-Type", "Content-Encoding", "Vary", "Trailer"]
    )
}

// MARK: - Helpers

/// Independent canonical envelope serializer (§11 shape) used only for tamper
/// and client-path fixtures. The canonical bodies themselves are decoded from
/// the embedded fixture's exact base64 — never rebuilt here.
private func makeEnvelope(
    dataBase64: String,
    byteLength: Int,
    checksumAlgorithm: String = "sha-256",
    checksumValue: String,
    sourceVersion: String,
    byteEncoding: String = "base64",
    source: String = "memory",
    name: String = "MEMORY.md",
    contentType: String = "text/markdown",
    schemaVersion: Int = 1,
    extraKeys: [String: Any] = [:]
) -> Data {
    var object: [String: Any] = [
        "byte_encoding": byteEncoding,
        "byte_length": byteLength,
        "checksum": ["algorithm": checksumAlgorithm, "value": checksumValue],
        "content_type": contentType,
        "data": dataBase64,
        "name": name,
        "schema_version": schemaVersion,
        "source": source,
        "source_version": sourceVersion
    ]
    for (key, value) in extraKeys {
        object[key] = value
    }
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func decodeFixtureBody(_ fixture: MemoryRawFixtureCase) -> Data {
    Data(base64Encoded: fixture.bodyBase64)!
}

private func fixtureCase(_ id: String) throws -> MemoryRawFixtureCase {
    try XCTUnwrap(MemoryRawFixture.cases.first { $0.id == id })
}

private func rawTestResponse(
    for request: URLRequest,
    body: Data,
    status: Int = 200,
    etag: String?,
    extraHeaders: [String: String] = [:]
) -> (HTTPURLResponse, Data) {
    var headers = extraHeaders
    if let etag {
        headers["ETag"] = etag
    }
    let response = HTTPURLResponse(
        url: request.url!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: headers
    )!
    return (response, body)
}

/// Canonical 200 response for one of the nine fixture cases.
private func raw200Response(for request: URLRequest, caseID: String) throws -> (HTTPURLResponse, Data) {
    let fixture = try fixtureCase(caseID)
    return rawTestResponse(for: request, body: decodeFixtureBody(fixture), etag: fixture.etag)
}

/// 200 response carrying the lf source bytes under a different envelope
/// source/name (used to prove per-source envelope verification).
private func raw200EnvelopeResponse(
    for request: URLRequest,
    source: String,
    name: String,
    etag: String
) throws -> (HTTPURLResponse, Data) {
    let lf = try fixtureCase("lf")
    let body = makeEnvelope(
        dataBase64: lf.sourceBase64,
        byteLength: lf.sourceByteLength,
        checksumValue: lf.sourceSHA256,
        sourceVersion: lf.sourceVersion,
        source: source,
        name: name
    )
    return rawTestResponse(for: request, body: body, etag: etag)
}

/// File-local copy of the repo's async-throw assertion pattern (the shared one
/// is private to APIClientKanbanTests.swift).
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error, but none was thrown")
    } catch {
        errorHandler(error)
    }
}

private extension SHA256Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Tests

final class MemoryRawReaderTests: APIClientTestCase {

    // MARK: Fixture integrity

    func testFixtureCasesAreSelfConsistent() throws {
        for fixture in MemoryRawFixture.cases {
            let sourceData = try XCTUnwrap(Data(base64Encoded: fixture.sourceBase64), fixture.id)
            XCTAssertEqual(sourceData.count, fixture.sourceByteLength, fixture.id)
            XCTAssertEqual(SHA256.hash(data: sourceData).hexString, fixture.sourceSHA256, fixture.id)
            XCTAssertEqual(fixture.sourceVersion, "sha256:\(fixture.sourceSHA256)", fixture.id)

            let bodyData = try XCTUnwrap(Data(base64Encoded: fixture.bodyBase64), fixture.id)
            XCTAssertEqual(bodyData.count, fixture.bodyByteLength, fixture.id)
            XCTAssertEqual(SHA256.hash(data: bodyData).hexString, fixture.representationSHA256, fixture.id)
            XCTAssertEqual(fixture.etag, "\"repr-sha256:\(fixture.representationSHA256)\"", fixture.id)

            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any], fixture.id)
            XCTAssertEqual(json["schema_version"] as? Int, MemoryRawFixture.schemaVersion, fixture.id)
            XCTAssertEqual(json["source"] as? String, MemoryRawFixture.canonicalSource, fixture.id)
            XCTAssertEqual(json["name"] as? String, MemoryRawFixture.canonicalName, fixture.id)
            XCTAssertEqual(json["content_type"] as? String, MemoryRawFixture.contentType, fixture.id)
            XCTAssertEqual(json["byte_length"] as? Int, fixture.sourceByteLength, fixture.id)
            XCTAssertEqual(json["byte_encoding"] as? String, MemoryRawFixture.byteEncoding, fixture.id)
            XCTAssertEqual(json["source_version"] as? String, fixture.sourceVersion, fixture.id)
            XCTAssertEqual(json["data"] as? String, fixture.sourceBase64, fixture.id)
            let checksum = try XCTUnwrap(json["checksum"] as? [String: Any], fixture.id)
            XCTAssertEqual(checksum["algorithm"] as? String, "sha-256", fixture.id)
            XCTAssertEqual(checksum["value"] as? String, fixture.sourceSHA256, fixture.id)
        }
    }

    // MARK: Decoder — byte-faithful canonical bodies

    func testDecodesEveryCanonicalFixtureCaseByteFaithfully() throws {
        for fixture in MemoryRawFixture.cases {
            let raw = try MemoryRawResponse(data: decodeFixtureBody(fixture), etag: fixture.etag)
            XCTAssertEqual(raw.source, MemoryRawFixture.canonicalSource, fixture.id)
            XCTAssertEqual(raw.name, MemoryRawFixture.canonicalName, fixture.id)
            XCTAssertEqual(raw.schemaVersion, MemoryRawFixture.schemaVersion, fixture.id)
            XCTAssertEqual(raw.contentType, MemoryRawFixture.contentType, fixture.id)
            XCTAssertEqual(raw.byteEncoding, MemoryRawFixture.byteEncoding, fixture.id)
            XCTAssertEqual(raw.byteLength, fixture.sourceByteLength, fixture.id)
            XCTAssertEqual(raw.checksum.algorithm, "sha-256", fixture.id)
            XCTAssertEqual(raw.checksum.value, fixture.sourceSHA256, fixture.id)
            XCTAssertEqual(raw.sourceVersion, fixture.sourceVersion, fixture.id)
            XCTAssertEqual(raw.etag, fixture.etag, fixture.id)
            let expectedSource = try XCTUnwrap(Data(base64Encoded: fixture.sourceBase64), fixture.id)
            XCTAssertEqual(raw.data, expectedSource, fixture.id)
        }
    }

    func testRetainsEmptySourceBytesExactly() throws {
        let fixture = try fixtureCase("empty")
        let raw = try MemoryRawResponse(data: decodeFixtureBody(fixture), etag: fixture.etag)
        XCTAssertTrue(raw.data.isEmpty)
        XCTAssertEqual(raw.byteLength, 0)
        XCTAssertEqual(
            raw.checksum.value,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func testRetainsNulBytesExactly() throws {
        let fixture = try fixtureCase("nul")
        let raw = try MemoryRawResponse(data: decodeFixtureBody(fixture), etag: fixture.etag)
        // "pre\0post\n": the NUL byte survives untouched.
        XCTAssertEqual(Array(raw.data), [0x70, 0x72, 0x65, 0x00, 0x70, 0x6F, 0x73, 0x74, 0x0A])
    }

    func testRetainsMalformedUTF8BytesExactly() throws {
        let fixture = try fixtureCase("malformed_utf8")
        let raw = try MemoryRawResponse(data: decodeFixtureBody(fixture), etag: fixture.etag)
        // "ok\xff\xfe\n": never a String, never redacted — bytes only.
        XCTAssertEqual(Array(raw.data), [0x6F, 0x6B, 0xFF, 0xFE, 0x0A])
    }

    func testRetainsUnicodeBytesExactly() throws {
        let fixture = try fixtureCase("unicode")
        let raw = try MemoryRawResponse(data: decodeFixtureBody(fixture), etag: fixture.etag)
        // "café 🚀\n" as UTF-8 bytes.
        XCTAssertEqual(Array(raw.data), [0x63, 0x61, 0x66, 0xC3, 0xA9, 0x20, 0xF0, 0x9F, 0x9A, 0x80, 0x0A])
    }

    func testRetainsCRLFAndLoneCRLineEndingsExactly() throws {
        let crlf = try fixtureCase("crlf")
        let loneCR = try fixtureCase("lone_cr")
        XCTAssertEqual(
            Array(try MemoryRawResponse(data: decodeFixtureBody(crlf), etag: crlf.etag).data),
            Array("# Note\r\nline\r\n".utf8)
        )
        XCTAssertEqual(
            Array(try MemoryRawResponse(data: decodeFixtureBody(loneCR), etag: loneCR.etag).data),
            Array("# Note\rline\r".utf8)
        )
    }

    // MARK: Decoder — representation ETag

    func testRepresentationETagIsDistinctFromSourceVersion() throws {
        let fixture = try fixtureCase("lf")
        let raw = try MemoryRawResponse(data: decodeFixtureBody(fixture), etag: fixture.etag)
        // The strong representation tag is over the canonical 200 body…
        XCTAssertEqual(
            raw.etag,
            "\"repr-sha256:8f85cc4d4f79e33cf20327f216df9ddaba87799b17c033ade0620848d24036db\""
        )
        // …and is never confused with the source-byte identity.
        XCTAssertEqual(
            raw.sourceVersion,
            "sha256:bb89a6e8128d049f4225932f9de463fef2e992c8a439b20ebb17b3792ddac3d2"
        )
        XCTAssertNotEqual(raw.etag, raw.sourceVersion)
    }

    func testRejectsMalformedRepresentationETags() throws {
        let fixture = try fixtureCase("lf")
        let body = decodeFixtureBody(fixture)
        let malformed: [String] = [
            "",
            "repr-sha256:8f85cc4d4f79e33cf20327f216df9ddaba87799b17c033ade0620848d24036db",
            "\"sha256:bb89a6e8128d049f4225932f9de463fef2e992c8a439b20ebb17b3792ddac3d2\"",
            "\"repr-md5:8f85cc4d4f79e33cf20327f216df9ddaba87799b17c033ade0620848d24036db\"",
            "\"repr-sha256:8F85CC4D4F79E33CF20327F216DF9DDABA87799B17C033ADE0620848D24036DB\"",
            "\"repr-sha256:8f85cc4d4f79e33cf20327f216df9ddaba87799b17c033ade0620848d24036d\""
        ]
        for etag in malformed {
            XCTAssertThrowsError(try MemoryRawResponse(data: body, etag: etag), etag) { error in
                guard case MemoryRawError.invalidETag(let received) = error else {
                    XCTFail("expected invalidETag for \(etag), got \(error)")
                    return
                }
                XCTAssertEqual(received, etag)
            }
        }
    }

    // MARK: Decoder — tolerant decoding of unknown additive fields

    func testToleratesUnknownAdditiveEnvelopeFields() throws {
        let fixture = try fixtureCase("lf")
        let body = makeEnvelope(
            dataBase64: fixture.sourceBase64,
            byteLength: fixture.sourceByteLength,
            checksumValue: fixture.sourceSHA256,
            sourceVersion: fixture.sourceVersion,
            extraKeys: ["future_envelope_field": ["nested": true]]
        )
        let raw = try MemoryRawResponse(data: body, etag: fixture.etag)
        XCTAssertEqual(raw.sourceVersion, fixture.sourceVersion)
        XCTAssertEqual(raw.data, try XCTUnwrap(Data(base64Encoded: fixture.sourceBase64)))
    }

    // MARK: Decoder — rejection of noncanonical and tampered envelopes

    func testRejectsNonCanonicalBase64() throws {
        let fixture = try fixtureCase("lf")
        let tampered: [String] = [
            "IyBOb3RlCmxpbmU", // unpadded (15 chars)
            "IyBOb3RlCmxpbmUK\n", // embedded newline
            "IyBOb3RlCmxpbmU=" // misplaced padding
        ]
        for dataBase64 in tampered {
            let body = makeEnvelope(
                dataBase64: dataBase64,
                byteLength: fixture.sourceByteLength,
                checksumValue: fixture.sourceSHA256,
                sourceVersion: fixture.sourceVersion
            )
            XCTAssertThrowsError(try MemoryRawResponse(data: body, etag: fixture.etag), dataBase64) { error in
                guard case MemoryRawError.nonCanonicalBase64 = error else {
                    XCTFail("expected nonCanonicalBase64 for \(dataBase64), got \(error)")
                    return
                }
            }
        }
    }

    func testRejectsByteLengthMismatch() throws {
        let fixture = try fixtureCase("lf")
        let body = makeEnvelope(
            dataBase64: fixture.sourceBase64,
            byteLength: 999,
            checksumValue: fixture.sourceSHA256,
            sourceVersion: fixture.sourceVersion
        )
        XCTAssertThrowsError(try MemoryRawResponse(data: body, etag: fixture.etag)) { error in
            guard case MemoryRawError.byteLengthMismatch(let declared, let decoded) = error else {
                XCTFail("expected byteLengthMismatch, got \(error)")
                return
            }
            XCTAssertEqual(declared, 999)
            XCTAssertEqual(decoded, 12)
        }
    }

    func testRejectsChecksumMismatch() throws {
        let fixture = try fixtureCase("lf")
        let body = makeEnvelope(
            dataBase64: fixture.sourceBase64,
            byteLength: fixture.sourceByteLength,
            checksumValue: "0000000000000000000000000000000000000000000000000000000000000000",
            sourceVersion: fixture.sourceVersion
        )
        XCTAssertThrowsError(try MemoryRawResponse(data: body, etag: fixture.etag)) { error in
            guard case MemoryRawError.checksumMismatch(let computed, let received) = error else {
                XCTFail("expected checksumMismatch, got \(error)")
                return
            }
            XCTAssertEqual(computed, fixture.sourceSHA256)
            XCTAssertEqual(received, "0000000000000000000000000000000000000000000000000000000000000000")
        }
    }

    func testRejectsUppercaseChecksumHex() throws {
        let fixture = try fixtureCase("lf")
        let body = makeEnvelope(
            dataBase64: fixture.sourceBase64,
            byteLength: fixture.sourceByteLength,
            checksumValue: "BB89A6E8128D049F4225932F9DE463FEF2E992C8A439B20EBB17B3792DDAC3D2",
            sourceVersion: fixture.sourceVersion
        )
        XCTAssertThrowsError(try MemoryRawResponse(data: body, etag: fixture.etag)) { error in
            guard case MemoryRawError.checksumMismatch(let computed, let received) = error else {
                XCTFail("expected checksumMismatch, got \(error)")
                return
            }
            XCTAssertEqual(computed, fixture.sourceSHA256)
            XCTAssertEqual(received, "BB89A6E8128D049F4225932F9DE463FEF2E992C8A439B20EBB17B3792DDAC3D2")
        }
    }

    func testRejectsChecksumAlgorithmOtherThanSHA256() throws {
        let fixture = try fixtureCase("lf")
        let body = makeEnvelope(
            dataBase64: fixture.sourceBase64,
            byteLength: fixture.sourceByteLength,
            checksumAlgorithm: "SHA-256",
            checksumValue: fixture.sourceSHA256,
            sourceVersion: fixture.sourceVersion
        )
        XCTAssertThrowsError(try MemoryRawResponse(data: body, etag: fixture.etag)) { error in
            guard case MemoryRawError.invalidEnvelope = error else {
                XCTFail("expected invalidEnvelope, got \(error)")
                return
            }
        }
    }

    func testRejectsSourceVersionMismatch() throws {
        let fixture = try fixtureCase("lf")
        let tampered: [String] = [
            "sha256:0000000000000000000000000000000000000000000000000000000000000000",
            "SHA256:bb89a6e8128d049f4225932f9de463fef2e992c8a439b20ebb17b3792ddac3d2"
        ]
        for sourceVersion in tampered {
            let body = makeEnvelope(
                dataBase64: fixture.sourceBase64,
                byteLength: fixture.sourceByteLength,
                checksumValue: fixture.sourceSHA256,
                sourceVersion: sourceVersion
            )
            XCTAssertThrowsError(try MemoryRawResponse(data: body, etag: fixture.etag), sourceVersion) { error in
                guard case MemoryRawError.sourceVersionMismatch(let expected, let received) = error else {
                    XCTFail("expected sourceVersionMismatch for \(sourceVersion), got \(error)")
                    return
                }
                XCTAssertEqual(expected, "sha256:\(fixture.sourceSHA256)")
                XCTAssertEqual(received, sourceVersion)
            }
        }
    }

    func testRejectsByteEncodingOtherThanBase64() throws {
        let fixture = try fixtureCase("lf")
        let body = makeEnvelope(
            dataBase64: fixture.sourceBase64,
            byteLength: fixture.sourceByteLength,
            checksumValue: fixture.sourceSHA256,
            sourceVersion: fixture.sourceVersion,
            byteEncoding: "hex"
        )
        XCTAssertThrowsError(try MemoryRawResponse(data: body, etag: fixture.etag)) { error in
            guard case MemoryRawError.invalidEnvelope = error else {
                XCTFail("expected invalidEnvelope, got \(error)")
                return
            }
        }
    }

    func testRejectsEnvelopeSourceOutsideFixedSelectors() throws {
        let fixture = try fixtureCase("lf")
        for source in ["MEMORY", "memory ", "external_notes"] {
            let body = makeEnvelope(
                dataBase64: fixture.sourceBase64,
                byteLength: fixture.sourceByteLength,
                checksumValue: fixture.sourceSHA256,
                sourceVersion: fixture.sourceVersion,
                source: source
            )
            XCTAssertThrowsError(try MemoryRawResponse(data: body, etag: fixture.etag), source) { error in
                guard case MemoryRawError.invalidEnvelope = error else {
                    XCTFail("expected invalidEnvelope for \(source), got \(error)")
                    return
                }
            }
        }
    }

    func testRejectsPathLikeOrEmptyName() throws {
        let fixture = try fixtureCase("lf")
        for name in ["", "../MEMORY.md", "memories/MEMORY.md"] {
            let body = makeEnvelope(
                dataBase64: fixture.sourceBase64,
                byteLength: fixture.sourceByteLength,
                checksumValue: fixture.sourceSHA256,
                sourceVersion: fixture.sourceVersion,
                name: name
            )
            XCTAssertThrowsError(try MemoryRawResponse(data: body, etag: fixture.etag), name) { error in
                guard case MemoryRawError.invalidEnvelope = error else {
                    XCTFail("expected invalidEnvelope for name \(name), got \(error)")
                    return
                }
            }
        }
    }

    func testRejectsSchemaVersionOtherThanOne() throws {
        let fixture = try fixtureCase("lf")
        let body = makeEnvelope(
            dataBase64: fixture.sourceBase64,
            byteLength: fixture.sourceByteLength,
            checksumValue: fixture.sourceSHA256,
            sourceVersion: fixture.sourceVersion,
            schemaVersion: 2
        )
        XCTAssertThrowsError(try MemoryRawResponse(data: body, etag: fixture.etag)) { error in
            guard case MemoryRawError.invalidEnvelope = error else {
                XCTFail("expected invalidEnvelope, got \(error)")
                return
            }
        }
    }

    func testRejectsContentTypeOtherThanTextMarkdown() throws {
        let fixture = try fixtureCase("lf")
        let body = makeEnvelope(
            dataBase64: fixture.sourceBase64,
            byteLength: fixture.sourceByteLength,
            checksumValue: fixture.sourceSHA256,
            sourceVersion: fixture.sourceVersion,
            contentType: "text/plain"
        )
        XCTAssertThrowsError(try MemoryRawResponse(data: body, etag: fixture.etag)) { error in
            guard case MemoryRawError.invalidEnvelope = error else {
                XCTFail("expected invalidEnvelope, got \(error)")
                return
            }
        }
    }

    // MARK: Client path — endpoint, query, and request shape

    func testRawMemoryBuildsExactPathQueryAndHeaders() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/memory/raw")
            let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(queryItems, [URLQueryItem(name: "source", value: "memory")])
            // V1 is unconditional: no If-None-Match is ever sent.
            XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
            // No trusted identity / API key / profile-cookie auth is added by
            // the raw client; auth is the session cookie from the login flow.
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Api-Key"))
            return try raw200Response(for: request, caseID: "lf")
        }

        let raw = try await client.rawMemory(source: .memory)

        XCTAssertEqual(raw.source, "memory")
        XCTAssertEqual(raw.name, "MEMORY.md")
        XCTAssertEqual(raw.schemaVersion, 1)
        XCTAssertEqual(raw.contentType, "text/markdown")
        XCTAssertEqual(raw.byteEncoding, "base64")
        XCTAssertEqual(raw.byteLength, 12)
        XCTAssertEqual(
            raw.checksum,
            MemoryRawChecksum(
                algorithm: "sha-256",
                value: "bb89a6e8128d049f4225932f9de463fef2e992c8a439b20ebb17b3792ddac3d2"
            )
        )
        XCTAssertEqual(
            raw.sourceVersion,
            "sha256:bb89a6e8128d049f4225932f9de463fef2e992c8a439b20ebb17b3792ddac3d2"
        )
        XCTAssertEqual(raw.data, try XCTUnwrap(Data(base64Encoded: "IyBOb3RlCmxpbmUK")))
        XCTAssertEqual(
            raw.etag,
            "\"repr-sha256:8f85cc4d4f79e33cf20327f216df9ddaba87799b17c033ade0620848d24036db\""
        )
    }

    func testRawMemoryCoversAllFourFixedSources() async throws {
        let expected: [(MemoryRawSource, String, String)] = [
            (.memory, "memory", "MEMORY.md"),
            (.user, "user", "USER.md"),
            (.soul, "soul", "SOUL.md"),
            (.projectContext, "project_context", "AGENTS.md")
        ]
        XCTAssertEqual(MemoryRawSource.allCases.count, 4)

        for (source, wireValue, expectedName) in expected {
            let client = makeClient { request in
                let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                XCTAssertEqual(queryItems, [URLQueryItem(name: "source", value: wireValue)])
                return try raw200EnvelopeResponse(
                    for: request,
                    source: wireValue,
                    name: expectedName,
                    etag: MemoryRawFixture.conditional304.etag
                )
            }

            let raw = try await client.rawMemory(source: source)

            XCTAssertEqual(raw.source, wireValue)
            XCTAssertEqual(raw.name, expectedName)
            XCTAssertEqual(raw.data, try XCTUnwrap(Data(base64Encoded: "IyBOb3RlCmxpbmUK")))
        }
    }

    func testRawMemorySendsSessionIDOnlyForProjectContext() async throws {
        let projectClient = makeClient { request in
            let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(queryItems, [
                URLQueryItem(name: "source", value: "project_context"),
                URLQueryItem(name: "session_id", value: "session-123")
            ])
            return try raw200EnvelopeResponse(
                for: request,
                source: "project_context",
                name: "AGENTS.md",
                etag: MemoryRawFixture.conditional304.etag
            )
        }
        let projectRaw = try await projectClient.rawMemory(source: .projectContext, sessionID: "session-123")
        XCTAssertEqual(projectRaw.name, "AGENTS.md")

        // A sessionID is never sent for the other fixed sources.
        let memoryClient = makeClient { request in
            let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(queryItems, [URLQueryItem(name: "source", value: "memory")])
            return try raw200Response(for: request, caseID: "lf")
        }
        let memoryRaw = try await memoryClient.rawMemory(source: .memory, sessionID: "session-123")
        XCTAssertEqual(memoryRaw.name, "MEMORY.md")
    }

    // MARK: Client path — envelope and ETag verification

    func testRawMemoryRejectsEnvelopeSourceMismatch() async throws {
        let client = makeClient { request in
            return try raw200EnvelopeResponse(
                for: request,
                source: "user",
                name: "USER.md",
                etag: MemoryRawFixture.conditional304.etag
            )
        }
        await XCTAssertThrowsErrorAsync(try await client.rawMemory(source: .memory)) { error in
            guard case MemoryRawError.sourceMismatch(let requested, let received) = error else {
                XCTFail("expected sourceMismatch, got \(error)")
                return
            }
            XCTAssertEqual(requested, "memory")
            XCTAssertEqual(received, "user")
        }
    }

    func testRawMemoryRequiresValidETagHeaderOn200() async throws {
        let fixture = try fixtureCase("lf")
        let body = decodeFixtureBody(fixture)

        let missingETag = makeClient { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json; charset=utf-8"]
                )!,
                body
            )
        }
        await XCTAssertThrowsErrorAsync(try await missingETag.rawMemory(source: .memory)) { error in
            guard case MemoryRawError.invalidETag(let received) = error else {
                XCTFail("expected invalidETag, got \(error)")
                return
            }
            XCTAssertEqual(received, "")
        }

        let malformedETag = makeClient { request in
            rawTestResponse(
                for: request,
                body: body,
                etag: "8f85cc4d4f79e33cf20327f216df9ddaba87799b17c033ade0620848d24036db"
            )
        }
        await XCTAssertThrowsErrorAsync(try await malformedETag.rawMemory(source: .memory)) { error in
            guard case MemoryRawError.invalidETag = error else {
                XCTFail("expected invalidETag, got \(error)")
                return
            }
        }
    }

    // MARK: Client path — 304 on the explicit raw path

    func testRawMemoryTreatsBodyless304AsProtocolError() async throws {
        let client = makeClient { request in
            // Exact §13 conditional_304 wire shape: bodyless, no
            // Content-Length/Content-Type, current ETag/Date/Cache-Control.
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 304,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "ETag": MemoryRawFixture.conditional304.etag,
                    "Date": MemoryRawFixture.conditional304.date,
                    "Cache-Control": MemoryRawFixture.conditional304.cacheControl
                ]
            )!
            return (response, Data())
        }
        await XCTAssertThrowsErrorAsync(try await client.rawMemory(source: .memory)) { error in
            guard case MemoryRawError.unexpectedNotModified = error else {
                XCTFail("expected unexpectedNotModified on the explicit raw path (not APIError.http), got \(error)")
                return
            }
        }
    }

    func testRawMemoryTreats304WithContentLengthAsProtocolError() async throws {
        // The client must not expect (or require) a 304 Content-Length either way.
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 304,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "ETag": MemoryRawFixture.conditional304.etag,
                    "Content-Length": "0"
                ]
            )!
            return (response, Data())
        }
        await XCTAssertThrowsErrorAsync(try await client.rawMemory(source: .memory)) { error in
            guard case MemoryRawError.unexpectedNotModified = error else {
                XCTFail("expected unexpectedNotModified, got \(error)")
                return
            }
        }
    }

    // MARK: Client path — V1 has no cache fallback

    func testRawMemoryNetworkErrorThrowsWithoutCacheFallback() async throws {
        let client = makeClient { request in
            throw URLError(.notConnectedToInternet)
        }
        await XCTAssertThrowsErrorAsync(try await client.rawMemory(source: .memory)) { error in
            guard case APIError.network = error else {
                XCTFail("expected APIError.network (V1 has no cache fallback), got \(error)")
                return
            }
        }
    }

    func testRawProtocolErrorsAreNotCacheFallbackCandidates() {
        // §19: #19 V1 does not add raw data to CacheFallbackPolicy.
        XCTAssertFalse(CacheFallbackPolicy.shouldUseCache(for: MemoryRawError.unexpectedNotModified))
        XCTAssertFalse(CacheFallbackPolicy.shouldUseCache(for: MemoryRawError.nonCanonicalBase64))
        XCTAssertFalse(CacheFallbackPolicy.shouldUseCache(for: MemoryRawError.invalidETag(received: "")))
    }

    // MARK: Login session cookie flow (§19 native URLSession requirement)

    func testLoginSessionCookieIsStoredAndSentOnFollowingRawRequest() async throws {
        let cookieStorage = HTTPCookieStorage()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.httpCookieStorage = cookieStorage
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        let session = URLSession(configuration: configuration)

        var loginRequestSeen = false
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/api/auth/login" {
                loginRequestSeen = true
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Set-Cookie": "hermes_session=raw-v1-session-token; Path=/; HttpOnly"]
                )!
                return (response, Data(#"{"ok":true}"#.utf8))
            }

            XCTAssertEqual(request.url?.path, "/api/memory/raw")
            let cookieHeader = request.value(forHTTPHeaderField: "Cookie") ?? ""
            XCTAssertTrue(
                cookieHeader.contains("hermes_session=raw-v1-session-token"),
                "raw request must send the stored login session cookie; Cookie header was: \(cookieHeader)"
            )
            return try raw200Response(for: request, caseID: "lf")
        }

        let client = APIClient(baseURL: URL(string: "https://example.test")!, session: session)
        _ = try await client.login(password: "secret")
        let raw = try await client.rawMemory(source: .memory)

        XCTAssertTrue(loginRequestSeen)
        XCTAssertEqual(raw.source, "memory")
        XCTAssertEqual(raw.name, "MEMORY.md")
        XCTAssertEqual(raw.data, try XCTUnwrap(Data(base64Encoded: "IyBOb3RlCmxpbmUK")))
        XCTAssertEqual(raw.etag, MemoryRawFixture.conditional304.etag)
    }
}
