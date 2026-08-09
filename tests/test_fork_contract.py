"""Repository contract checks for the fork-owned Improvements bounded context.

This suite intentionally uses only the Python standard library so every pull
request, including a documentation-only PR from a fork, can run it on Ubuntu.
"""

from __future__ import annotations

import hashlib
import os
import re
import tempfile
import unittest
from collections import Counter
from pathlib import Path


ROOT = Path(
    os.environ.get("HERMEX_CONTRACT_ROOT", Path(__file__).resolve().parents[1])
).resolve()
CONTRACT = ROOT / "docs" / "improvements-contract.md"
CANONICAL_DOCS = (
    ROOT / "CONTEXT.md",
    ROOT / "PROJECT_SPEC.md",
    ROOT / "PROJECT_INTENT.md",
    ROOT / "AGENTS.md",
    ROOT / "CONTRIBUTING.md",
)
AGENT_GUIDANCE = tuple(sorted((ROOT / "docs" / "agents").glob("*.md")))
PR_CI_EXECUTABLE_SHA256 = "05609045c481858d7ca1fe483db52f11d72ec88fc061f3165ea94c48c307e2ec"
CONTRACT_CI_EXECUTABLE_SHA256 = "962889f05c30f363ef5d75eb28f3e9dc64375da95dd8687b4d13b465442e1d23"
UPSTREAM_WATCH_EXECUTABLE_SHA256 = "8b107d6ea011acbf886751b1827fcbd95762dcf29445d1660174c3ad256def8a"
PROTECTED_WORKFLOW_SHA256 = {
    "contract-ci.yml": CONTRACT_CI_EXECUTABLE_SHA256,
    "pr-ci.yml": PR_CI_EXECUTABLE_SHA256,
    "upstream-watch.yml": UPSTREAM_WATCH_EXECUTABLE_SHA256,
}
UPSTREAM_APP_REPOSITORY = "https://github.com/uzairansaruzi/hermex"
HISTORICAL_UPSTREAM_ISSUES = {"140", "141", "142", "143", "146", "147", "148"}
INHERITED_TEAM_ID = "6GYD9" + "C9N6R"
INHERITED_BUNDLE_ID = "com." + "uzairansar.hermesmobile"
INHERITED_URL_SCHEME = "hermes-" + "agent"
INHERITED_OWNER_DOMAIN = "uzair" + "ansar.com"
INHERITED_SHARE_SUFFIX = "share" + "extension"
INHERITED_WIDGET_SUFFIX = "liveactivity" + "widget"
INHERITED_RUNTIME_IDENTITY_PATTERNS = (
    re.compile(
        re.escape(INHERITED_URL_SCHEME.encode())
        + rb"(?=://|(?:\$\(APP_URL_SCHEME_SUFFIX\))?[\"'])"
    ),
    re.compile(re.escape(INHERITED_OWNER_DOMAIN.encode())),
    re.compile(
        rb"\$\(APP_BUNDLE_IDENTIFIER\)\."
        + rb"(?:"
        + re.escape(INHERITED_SHARE_SUFFIX.encode())
        + rb"|"
        + re.escape(INHERITED_WIDGET_SUFFIX.encode())
        + rb")"
    ),
)

MAINTAINED_GUIDANCE = tuple(
    dict.fromkeys(
        (
            *sorted(ROOT.glob("*.md")),
            *sorted((ROOT / "docs").rglob("*.md")),
            *sorted((ROOT / ".agy").glob("*.md")),
            ROOT / ".github" / "PULL_REQUEST_TEMPLATE.md",
            *sorted((ROOT / ".github" / "ISSUE_TEMPLATE").glob("*.y*ml")),
        )
    )
)


def read_within(root: Path, path: Path) -> str:
    try:
        root_resolved = root.resolve(strict=True)
        resolved = path.resolve(strict=True)
        resolved.relative_to(root_resolved)
    except (FileNotFoundError, ValueError) as error:
        raise AssertionError(f"contract path escapes candidate root or is missing: {path}") from error
    return resolved.read_text(encoding="utf-8")


def read(path: Path) -> str:
    return read_within(ROOT, path)


def regular_path_findings(root: Path, relative: str, *, directory: bool = False) -> list[str]:
    """Reject a missing, symlinked, or wrong-kind path and every symlinked ancestor."""
    findings: list[str] = []
    current = root
    parts = Path(relative).parts
    for index, part in enumerate(parts):
        current = current / part
        is_leaf = index == len(parts) - 1
        try:
            current.lstat()
        except FileNotFoundError:
            return [f"protected path is missing: {relative}"]
        if current.is_symlink():
            findings.append(f"protected path or ancestor is a symlink: {current.relative_to(root)}")
            return findings
        if not is_leaf and not current.is_dir():
            findings.append(f"protected path ancestor is not a directory: {current.relative_to(root)}")
            return findings
        if is_leaf:
            expected_kind = current.is_dir() if directory else current.is_file()
            if not expected_kind:
                kind = "directory" if directory else "file"
                findings.append(f"protected path is not a regular {kind}: {relative}")
    return findings


def inherited_identity_occurrences(root: Path) -> list[tuple[str, str]]:
    """Return every byte-level occurrence of identity values quarantined for issue #15."""
    tokens = (INHERITED_TEAM_ID.encode(), INHERITED_BUNDLE_ID.encode())
    excluded = {".git"}
    findings: list[tuple[str, str]] = []
    for path in root.rglob("*"):
        relative = path.relative_to(root)
        if any(part in excluded for part in relative.parts):
            continue
        relative_text = str(relative)
        if any(token in relative_text.encode() for token in tokens):
            findings.append((relative_text, "<path>"))
        if path.is_symlink():
            raw_lines = [os.readlink(path).encode()]
        elif path.is_file():
            raw_lines = path.read_bytes().splitlines()
        else:
            continue
        for raw_line in raw_lines:
            if any(token in raw_line for token in tokens):
                findings.append(
                    (
                        str(path.relative_to(root)),
                        raw_line.decode("utf-8", errors="replace").strip(),
                    )
                )
    return sorted(findings)


def unapproved_inherited_identity_occurrences(
    root: Path, allowed: list[tuple[str, str]]
) -> list[tuple[str, str]]:
    """Allow issue #15 removals, but reject additions and duplicate occurrences."""
    actual = Counter(inherited_identity_occurrences(root))
    return sorted((actual - Counter(allowed)).elements())


def inherited_runtime_identity_occurrences(root: Path) -> list[tuple[str, str]]:
    """Find deferred URL, owner-route, and extension identity covered by issue #15."""
    excluded = {".git"}
    findings: list[tuple[str, str]] = []
    for path in root.rglob("*"):
        relative = path.relative_to(root)
        if any(part in excluded for part in relative.parts):
            continue
        relative_bytes = str(relative).encode()
        for pattern in INHERITED_RUNTIME_IDENTITY_PATTERNS:
            findings.extend(
                (str(relative), "<path>") for _ in pattern.finditer(relative_bytes)
            )
        if path.is_symlink():
            raw_lines = [os.readlink(path).encode()]
        elif path.is_file():
            raw_lines = path.read_bytes().splitlines()
        else:
            continue
        for raw_line in raw_lines:
            for pattern in INHERITED_RUNTIME_IDENTITY_PATTERNS:
                findings.extend(
                    (
                        str(relative),
                        raw_line.decode("utf-8", errors="replace").strip(),
                    )
                    for _ in pattern.finditer(raw_line)
                )
    return sorted(findings)


def unapproved_runtime_identity_occurrences(
    root: Path, allowed: list[tuple[str, str]]
) -> list[tuple[str, str]]:
    actual = Counter(inherited_runtime_identity_occurrences(root))
    return sorted((actual - Counter(allowed)).elements())


def canonical_identity_migration_findings(
    root: Path, required_version: str | None = None
) -> list[str]:
    """Require the complete issue #15 replacement when the quarantine disappears."""
    expected_lines = {
        "Config/Shared.xcconfig": {
            "DEVELOPMENT_TEAM =": 1,
            "APP_IDENTIFIER_SUFFIX =": 1,
            "APP_BUNDLE_IDENTIFIER = no.gior.hermex$(APP_IDENTIFIER_SUFFIX)": 1,
            "APP_GROUP_IDENTIFIER = group.no.gior.hermex$(APP_IDENTIFIER_SUFFIX)": 1,
        },
        ".xcodebuildmcp/config.yaml": {'bundleId: "no.gior.hermex"': 1},
        "HermesMobile.xcodeproj/project.pbxproj": {
            'APP_URL_SCHEME_SUFFIX = "";': 2,
            'HERMES_URL_SCHEME = "hermex$(APP_URL_SCHEME_SUFFIX)";': 2,
            'PRODUCT_BUNDLE_IDENTIFIER = "$(APP_BUNDLE_IDENTIFIER)";': 2,
            'PRODUCT_BUNDLE_IDENTIFIER = "$(APP_BUNDLE_IDENTIFIER).tests";': 2,
            'PRODUCT_BUNDLE_IDENTIFIER = "$(APP_BUNDLE_IDENTIFIER).share";': 2,
            'PRODUCT_BUNDLE_IDENTIFIER = "$(APP_BUNDLE_IDENTIFIER).liveactivity";': 2,
        },
        "HermesMobile/Resources/HermesMobile.entitlements": {
            "<string>$(APP_GROUP_IDENTIFIER)</string>": 1,
        },
        "HermesShareExtension/Resources/HermesShareExtension.entitlements": {
            "<string>$(APP_GROUP_IDENTIFIER)</string>": 1,
        },
        "HermesMobile/Auth/KeychainStore.swift": {'?? "no.gior.hermex"': 1},
        "HermesMobile/Features/Share/SharedDraftStore.swift": {
            '?? "group.no.gior.hermex"': 1,
            '?? "hermex"': 1,
        },
        "HermesMobile/LiveActivities/HermesDeepLink.swift": {'?? "hermex"': 1},
        "HermesMobileTests/TranscriptLinkPreviewTests.swift": {
            'in: "Open file:///tmp/report.txt, ssh://server.test, and hermex://session/1."': 1,
        },
    }
    findings: list[str] = []
    for relative, required in expected_lines.items():
        path = root / relative
        try:
            lines = [line.strip() for line in read_within(root, path).splitlines()]
        except AssertionError:
            findings.append(f"missing canonical identity file: {relative}")
            continue
        for line, count in required.items():
            actual = sum(candidate_line == line for candidate_line in lines)
            if actual != count:
                findings.append(f"{relative}: expected {count} occurrence(s) of {line!r}, found {actual}")

    identity_assignment = re.compile(
        r"^\s*(?:APP_IDENTIFIER_SUFFIX|APP_BUNDLE_IDENTIFIER|APP_GROUP_IDENTIFIER|"
        r"APP_URL_SCHEME_SUFFIX|HERMES_URL_SCHEME|PRODUCT_BUNDLE_IDENTIFIER)\s*="
    )
    allowed_assignments = Counter(
        {
            ("Config/Shared.xcconfig", "APP_IDENTIFIER_SUFFIX ="): 1,
            (
                "Config/Shared.xcconfig",
                "APP_BUNDLE_IDENTIFIER = no.gior.hermex$(APP_IDENTIFIER_SUFFIX)",
            ): 1,
            (
                "Config/Shared.xcconfig",
                "APP_GROUP_IDENTIFIER = group.no.gior.hermex$(APP_IDENTIFIER_SUFFIX)",
            ): 1,
            ("HermesMobile.xcodeproj/project.pbxproj", 'APP_URL_SCHEME_SUFFIX = "";'): 2,
            (
                "HermesMobile.xcodeproj/project.pbxproj",
                'HERMES_URL_SCHEME = "hermex$(APP_URL_SCHEME_SUFFIX)";',
            ): 2,
            (
                "HermesMobile.xcodeproj/project.pbxproj",
                'PRODUCT_BUNDLE_IDENTIFIER = "$(APP_BUNDLE_IDENTIFIER)";',
            ): 2,
            (
                "HermesMobile.xcodeproj/project.pbxproj",
                'PRODUCT_BUNDLE_IDENTIFIER = "$(APP_BUNDLE_IDENTIFIER).tests";',
            ): 2,
            (
                "HermesMobile.xcodeproj/project.pbxproj",
                'PRODUCT_BUNDLE_IDENTIFIER = "$(APP_BUNDLE_IDENTIFIER).share";',
            ): 2,
            (
                "HermesMobile.xcodeproj/project.pbxproj",
                'PRODUCT_BUNDLE_IDENTIFIER = "$(APP_BUNDLE_IDENTIFIER).liveactivity";',
            ): 2,
        }
    )
    actual_assignments: Counter[tuple[str, str]] = Counter()
    assignment_paths = sorted(root.rglob("*.xcconfig"))
    project_path = root / "HermesMobile.xcodeproj/project.pbxproj"
    if project_path.exists():
        assignment_paths.append(project_path)
    for assignment_path in assignment_paths:
        relative = str(assignment_path.relative_to(root))
        for line in read_within(root, assignment_path).splitlines():
            stripped = line.strip()
            if identity_assignment.match(stripped):
                actual_assignments[(relative, stripped)] += 1
    for key in ("APP_IDENTIFIER_SUFFIX", "APP_URL_SCHEME_SUFFIX"):
        invalid = [
            f"{relative}: {line}"
            for (relative, line), count in actual_assignments.items()
            if line.startswith(f"{key} =")
            and (relative, line) not in allowed_assignments
            for _ in range(count)
        ]
        if invalid:
            findings.append(f"{key} must be empty in every tracked build configuration: {invalid}")
    unexpected_assignments = actual_assignments - allowed_assignments
    missing_assignments = allowed_assignments - actual_assignments
    if unexpected_assignments or missing_assignments:
        findings.append(
            "effective identity assignment inventory must resolve exactly to "
            "no.gior.hermex, .tests, .share, .liveactivity, group.no.gior.hermex, and hermex"
        )

    project_path = root / "HermesMobile.xcodeproj/project.pbxproj"
    if project_path.exists() and project_path.is_file() and not project_path.is_symlink():
        marketing_lines = [
            line.strip()
            for line in read_within(root, project_path).splitlines()
            if "MARKETING_VERSION" in line
        ]
        version_pattern = re.compile(
            r"MARKETING_VERSION = (0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*);"
        )
        parsed_versions = [
            match.group(0).removeprefix("MARKETING_VERSION = ").removesuffix(";")
            for line in marketing_lines
            if (match := version_pattern.fullmatch(line)) is not None
        ]
        if not marketing_lines or len(parsed_versions) != len(marketing_lines):
            findings.append("HermesMobile.xcodeproj/project.pbxproj: invalid MARKETING_VERSION assignment")
        elif len(set(parsed_versions)) != 1:
            findings.append("HermesMobile.xcodeproj/project.pbxproj: target versions diverge")
        elif required_version is not None and (
            parsed_versions[0] != required_version or len(parsed_versions) != 8
        ):
            findings.append(
                "HermesMobile.xcodeproj/project.pbxproj: "
                f"identity epoch requires eight {required_version} target versions"
            )

    for relative in ("Config/Shared.xcconfig", "HermesMobile.xcodeproj/project.pbxproj"):
        path = root / relative
        if path.exists() and re.search(
            r"(?m)^\s*DEVELOPMENT_TEAM\s*=\s*[A-Z0-9]{10}\s*;?\s*$",
            read_within(root, path),
        ):
            findings.append(f"{relative}: Apple Team identity remains")
    return findings


def identity_migration_findings(
    root: Path,
    expected_identity: list[tuple[str, str]],
    expected_runtime: list[tuple[str, str]],
    required_version: str | None = None,
) -> list[str]:
    """Permit only the untouched quarantine or the complete canonical migration."""
    actual_identity = Counter(inherited_identity_occurrences(root))
    actual_runtime = Counter(inherited_runtime_identity_occurrences(root))
    if actual_identity == Counter(expected_identity) and actual_runtime == Counter(expected_runtime):
        return []
    if actual_identity or actual_runtime:
        return ["issue #15 identity migration is partial; preserve the quarantine or remove it atomically"]
    return canonical_identity_migration_findings(root, required_version)


def webui_fork_routing_findings(root: Path) -> list[str]:
    """Advance fork guidance only after issue #45 records a valid tested commit."""
    fork_url = "https://github.com/ebreen/hermes-webui"
    guidance_paths = (
        "CONTRACT_TESTS.md",
        "DEVELOPMENT.md",
        "PROJECT_SPEC.md",
        "README.md",
        "docs/improvements-contract.md",
    )
    findings: list[str] = []
    guidance: dict[str, str] = {}
    for relative in guidance_paths:
        try:
            guidance[relative] = read_within(root, root / relative)
        except AssertionError:
            findings.append(f"missing canonical WebUI guidance: {relative}")

    pin_path = root / "WEBUI_FORK_TESTED_SHA"
    if pin_path.is_symlink() or (pin_path.exists() and not pin_path.is_file()):
        findings.append("WEBUI_FORK_TESTED_SHA must be a regular non-symlink file")
        return findings
    pin = read_within(root, pin_path).strip() if pin_path.exists() else ""
    if pin and re.fullmatch(r"[0-9a-f]{40}", pin) is None:
        findings.append("WEBUI_FORK_TESTED_SHA is not a full lowercase commit SHA")
    if pin:
        for relative, text in guidance.items():
            if fork_url not in text:
                findings.append(f"{relative} omits the pinned live WebUI fork")
    else:
        for relative, text in guidance.items():
            if fork_url in text:
                findings.append(f"{relative} represents the unpinned WebUI fork as live")
    return findings


def app_config_route_findings(root: Path) -> list[str]:
    """Require exact runtime declarations and reject predecessor-owned production routes."""
    relative = "HermesMobile/Config/AppConfig.swift"
    path = root / relative
    if path_findings := regular_path_findings(root, relative):
        return path_findings
    text = read_within(root, path)
    expected = {
        "privacyPolicyURL": "https://github.com/ebreen/hermex/blob/master/PRIVACY.md",
        "supportURL": "https://github.com/ebreen/hermex/issues",
    }
    findings: list[str] = []
    for property_name, expected_url in expected.items():
        matches = re.findall(
            rf'(?m)^\s*static let {property_name} = URL\(staticString: "([^"]+)"\)\s*$',
            text,
        )
        if matches != [expected_url]:
            findings.append(
                f"{relative}: {property_name} must declare exactly {expected_url}"
            )

    prohibited_routes = (
        "https://github.com/uzairansaruzi/hermex",
        INHERITED_OWNER_DOMAIN,
    )
    mobile_root = root / "HermesMobile"
    for swift_path in sorted(mobile_root.rglob("*.swift")):
        swift_text = read_within(root, swift_path)
        for route in prohibited_routes:
            if route in swift_text:
                findings.append(
                    f"{swift_path.relative_to(root)} routes production UI to predecessor owner: {route}"
                )
    return findings


def normalize_prose(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def executable_workflow_sha256(workflow: str) -> str:
    """Hash exact workflow bytes; comments inside block scalars can alter shell execution."""
    return hashlib.sha256(workflow.encode("utf-8")).hexdigest()


def active_workflow_texts(root: Path) -> dict[str, str]:
    workflow_dir = root / ".github" / "workflows"
    for directory in (root / ".github", workflow_dir):
        if directory.is_symlink() or not directory.is_dir():
            raise AssertionError(
                f"protected workflow directory must be a regular non-symlink directory: "
                f"{directory.relative_to(root)}"
            )
    paths = sorted((*workflow_dir.rglob("*.yml"), *workflow_dir.rglob("*.yaml")))
    workflows: dict[str, str] = {}
    for path in paths:
        relative = str(path.relative_to(workflow_dir))
        if path.is_symlink() or not path.is_file():
            raise AssertionError(f"protected workflow must be a regular non-symlink file: {relative}")
        workflows[relative] = read_within(root, path)
    return workflows


def protected_workflow_findings(workflows: dict[str, str]) -> list[str]:
    findings: list[str] = []
    actual = set(workflows)
    expected = set(PROTECTED_WORKFLOW_SHA256)
    for name in sorted(actual - expected):
        findings.append(f"unexpected workflow can spoof a protected check: {name}")
    for name in sorted(expected - actual):
        findings.append(f"protected workflow is missing: {name}")
    for name in sorted(actual & expected):
        digest = executable_workflow_sha256(workflows[name])
        if digest != PROTECTED_WORKFLOW_SHA256[name]:
            findings.append(f"protected workflow executable changed: {name}")
    return findings


SEMANTIC_REVERSAL_CASES = (
    (r"(?:it|this) is false that the WebUI fork is the canonical", "It is false that the WebUI fork is the canonical server system of record."),
    (r"WebUI fork is not (?:the )?canonical", "The WebUI fork is not canonical."),
    (r"iOS cache is (?:the )?(?:canonical|system of record)", "The iOS cache is the system of record."),
    (r"Feature is (?:a )?persisted domain entity", "Feature is a persisted domain entity."),
    (r"Accept (?:starts|creates|sends|dispatches) (?:work|a Session|a Card)", "Accept starts work."),
    (r"Cron is (?:the )?(?:canonical|schedule system of record)", "Cron is the schedule system of record."),
    (r"Retrieved text (?:is|becomes) (?:an )?instruction", "Retrieved text becomes an instruction."),
    (r"Learning (?:may|can) (?:expand retrieval|activate a schedule|create a Handoff|start work)", "Learning may expand retrieval."),
    (r"(?:Lead|Critic) execution (?:may|can) (?:commit|open a pull request|create a Session|edit a Card)", "Lead execution can commit."),
    (r"Changing either effective provider (?:does not|need not) pause", "Changing either effective provider need not pause the Schedule."),
    (r"unknown lifecycle(?: or side-effect-bearing)? enum value (?:is|may be|can be) (?:silently )?(?:ignored|coerced)", "An unknown lifecycle enum value may be ignored."),
    (r"next_cursor (?:may|can) (?:skip|advance past)", "A page's next_cursor may skip returned events."),
    (r"Upstream (?:may|can) satisfy the canonical product gate", "Upstream can satisfy the canonical product gate."),
    (r"iOS cache (?:may |can |does |will )?override(?:s)? (?:the )?(?:WebUI )?server", "The iOS cache overrides the server after reconnect."),
    (r"(?:WebUI )?server (?:does not have to|need not) win (?:a )?cache conflict", "The server need not win a cache conflict."),
    (
        r"(?:CI|repository|release|IPA|artifact)(?![^.]{0,120}\b(?:does not|do not|must not|may not|cannot|never|contains? no|has no|without)\b)[^.]{0,100}(?:may|can|must|requires?)[^.]{0,100}(?:Apple (?:distribution )?certificate|Apple signing identity|provisioning profile|App Store Connect key)",
        "CI may require an Apple certificate.",
    ),
    (r"(?:zero-signature|unsigned) (?:Mach-O|IPA) (?:is|remains) SideStore-ready", "A zero-signature Mach-O is SideStore-ready."),
    (r"ad-hoc signature (?:may|can) contain (?:an )?Apple identity", "An ad-hoc signature may contain Apple identity."),
    (r"revoked Consent Grant (?:may|can) (?:return|move) to active", "A revoked Consent Grant may return to active."),
    (r"Renewal (?:may|can) reactivate (?:the )?(?:existing )?(?:expired|revoked|terminal) Consent Grant", "Renewal may reactivate the existing expired Consent Grant."),
    (r"expired Consent Grant (?:may|can) authorize (?:the )?(?:rest|remainder) of an in-flight Cycle", "An expired Consent Grant may authorize the rest of an in-flight Cycle."),
    (r"Duplicate owned Cron jobs (?:may|can) be repaired before the Schedule is (?:marked )?degraded", "Duplicate owned Cron jobs may be repaired before the Schedule is degraded."),
    (r"(?:first|last|arbitrary) Cron job returned wins", "For duplicate owned Cron jobs, the first Cron job returned wins."),
    (r"Profile disappears after Card creation[^.]{0,120}(?:delete|recreate|replace) (?:the )?Card", "If the Profile disappears after Card creation, delete the Card and recreate it."),
    (r"deferred Proposal (?:may|can) remain deferred after `?review_after`?", "A deferred Proposal may remain deferred after `review_after`."),
    (r"Handoff (?:row|unique constraint)[^.]{0,120}deduplicate(?:s)? /api/session/new", "The Handoff row and later target ID deduplicate /api/session/new."),
    (r"(?:timeout|connection loss) proves Session creation did not happen", "A timeout proves Session creation did not happen."),
    (r"Request execution is exactly once without destination idempotency", "Request execution is exactly once without destination idempotency."),
    (r"outcome-uncertain (?:Session )?creation (?:may|can) retry automatically", "An outcome-uncertain Session creation may retry automatically."),
    (r"(?:Create & Start|idempotent saga)[^.]{0,160}starts? (?:it |work )?exactly once", "Create & Start uses an idempotent saga that starts it exactly once."),
    (r"final authority (?:belongs to|is) (?:the )?(?:iOS|native) projection", "Final authority belongs to the iOS projection."),

    (r"Cron (?:owns|is) (?:the )?authoritative (?:schedule|scheduling state)", "Cron owns the authoritative schedule."),
    (
        r"learning (?:may|can|does|will) (?:raise|increase|promote)[^.]{0,80}(?:above|over|past) (?:the )?(?:risk )?threshold",
        "Learning may raise candidates above the risk threshold.",
    ),
    (
        r"Accept (?:automatically )?(?:(?:launches|starts|creates)[^.]{0,80}(?:worker run|execution)|executes[^.]{0,80})",
        "Accept launches a worker run.",
    ),
    (
        r"archived Subject[^.]{0,100}(?:may|can|does|will) consume[^.]{0,80}defer_elapsed",
        "An archived Subject may consume defer_elapsed before restoration.",
    ),
    (
        r"Save to Triage[^.]{0,180}Create (?:&|and) Start[^.]{0,120}(?:may|can|is allowed to) create (?:a )?(?:new|second) Card",
        "Save to Triage followed by Create and Start may create a second Card.",
    ),
    (r"authorization and overlap checks may occur after Cron dispatch", "Authorization and overlap checks may occur after Cron dispatch."),
    (r"losing fire may retrieve or submit", "A losing fire may retrieve or submit provider data before recording skipped_overlap."),
    (
        r"timed[- ]out in[- ]flight provider call permits automatic takeover",
        "A timed-out in-flight provider call permits automatic takeover after its deadline.",
    ),
    (r"one provider/model authorization may cover both Lead and Critic", "One provider/model authorization may cover both Lead and Critic even when their providers differ."),
    (r"Run Now may execute without (?:a )?(?:Consent )?Grant", "Run Now may execute without a Consent Grant while recurrence is paused."),
    (r"Improvements routes may use (?:a )?cross-origin service", "Improvements routes may use a cross-origin service."),
    (r"third-party (?:database|analytics service) may receive Improvements data", "A third-party analytics service may receive Improvements data."),
    (r"existing triage Card may start without (?:a )?(?:version|CAS|compare-and-set)", "An existing triage Card may start without a version check."),
    (r"Handoff audit may omit (?:the )?start-operation", "Handoff audit may omit the start-operation payload hash."),
    (r"probabilistic similarity alone may reject", "Probabilistic similarity alone may reject a Proposal."),
    (r"related-Proposal corpus may omit (?:rejected|dismissed|archived|implemented)", "The related-Proposal corpus may omit rejected Proposals."),
    (r"multi-Handoff Delivery State (?:is|may be) implementation-defined", "Multi-Handoff Delivery State is implementation-defined."),
    (r"retention for (?:cancelled|unknown|succeeded) Cycles (?:is|may be) implementation-defined", "Retention for unknown Cycles is implementation-defined."),
    (r"Grant confirmation evidence may be deleted before Subject purge", "Grant confirmation evidence may be deleted before Subject purge."),
    (
        r"Context Source revoked after admission may remain usable",
        "A Context Source revoked after admission may remain usable for the current Cycle.",
    ),
    (
        r"queued Cycle may transition to `?policy_denied`?",
        "A queued Cycle may transition to policy_denied when admission fails.",
    ),
    (
        r"Proposal review (?:may|can) transition to `?(?:archived|abandoned|implemented)`?",
        "Proposal review may transition to archived after delivery.",
    ),
    (
        r"compacted Proposal may receive an unread Update without (?:a )?(?:complete body|reviewable successor)",
        "A compacted Proposal may receive an unread Update without a complete body.",
    ),
)

SEMANTIC_REVERSALS = tuple(pattern for pattern, _ in SEMANTIC_REVERSAL_CASES)


def semantic_reversal_findings(text: str) -> list[str]:
    normalized = normalize_prose(text)
    return [pattern for pattern in SEMANTIC_REVERSALS if re.search(pattern, normalized, re.I)]


PROHIBITED_GUIDANCE = (
    r"you are NOT modifying the upstream",
    r"Hermex (?:is|contains) (?:an? )?(?:iOS|mobile) client only",
    r"revisit forking later",
    r"ground truth for exact JSON shapes",
    r"TestFlight first",
    r"(?:PRODUCT_BUNDLE_IDENTIFIER|bundle (?:identifier|ID)|app ID)[^.\n]{0,80}(?:com|org|net)\.[a-z0-9-]+(?:\.[a-z0-9-]+){1,}",
    r"(?:Apple (?:Team|team)|Team ID|DEVELOPMENT_TEAM)[^.\n]{0,80}\b(?=[A-Z0-9]{0,9}\d)[A-Z0-9]{10}\b",
    r"hermes-mobile-ios",
    r"apps\.apple\.com/app/hermex",
    r"hermexapp\.com",
    r"buymeacoffee\.com/callmeuzi",
    r"contains only the iOS client",
    r"do not modify the upstream `?hermes-webui",
    r"Improvements (?:may|can|does|will) (?:write|edit|mutate) (?:native )?Memory",
    r"/api/memory/write",
    r"if a request conflicts with it,\s*stop and ask",
    r"stop and ask before (?:implementing|changing) (?:the )?product",
    r"ask before touching",
    r"ask the (?:human|owner) (?:before|for) (?:every|all) (?:ordinary|reversible)",
    r"This is a single-context repo",
    r"no required `?CONTEXT\.md`?",
    r"If these files do not exist, proceed silently",
    r"`?CONTEXT\.md`? (?:is|remains) optional",
    r"`?PROJECT_SPEC\.md`? (?:is|remains) (?:canonical|co-equal)",
)


def normalized_prose_with_line_map(text: str) -> tuple[str, list[int]]:
    """Normalize whitespace while retaining a source line for every output character."""
    parts: list[str] = []
    source_lines: list[int] = []
    source_cursor = 0
    line_number = 1
    for token in re.finditer(r"\S+", text):
        line_number += text.count("\n", source_cursor, token.start())
        if parts:
            parts.append(" ")
            source_lines.append(line_number)
        value = token.group(0)
        parts.append(value)
        source_lines.extend([line_number] * len(value))
        source_cursor = token.end()
    return "".join(parts), source_lines


def match_is_explicitly_negated(text: str, start: int) -> bool:
    """Return true only when a nearby negator directly governs the matched proposition."""
    prefix = text[:start]
    clause = re.split(r"[.!?;:,]", prefix)[-1]
    negators = list(
        re.finditer(
            r"\b(?:never|do not|does not|must not|cannot|can't|is forbidden to|are forbidden to)\b",
            clause,
            flags=re.IGNORECASE,
        )
    )
    if not negators:
        return False
    between = clause[negators[-1].end() :]
    if re.search(
        r"\b(?:and|although|because|but|except|however|or|since|so|that|then|unless|while|yet)\b",
        between,
        flags=re.IGNORECASE,
    ):
        return False
    return len(re.findall(r"\b[\w'-]+\b", between)) <= 5


def superseded_guidance_findings(text: str) -> list[tuple[int, str, str]]:
    normalized, source_lines = normalized_prose_with_line_map(text)
    findings: list[tuple[int, str, str]] = []
    for pattern in PROHIBITED_GUIDANCE:
        for match in re.finditer(pattern, normalized, flags=re.IGNORECASE):
            if match_is_explicitly_negated(normalized, match.start()):
                continue
            line_number = source_lines[match.start()] if source_lines else 1
            findings.append((line_number, pattern, match.group(0)))
    return findings


def fork_routing_findings(path: Path, text: str) -> list[tuple[int, str]]:
    """Reject predecessor-repository routing outside narrow sync/provenance references."""
    relative = path.relative_to(ROOT)
    normalized_document = normalize_prose(text)
    findings: list[tuple[int, str]] = []
    for line_number, line in enumerate(text.splitlines(), 1):
        if UPSTREAM_APP_REPOSITORY not in line:
            continue
        normalized_line = normalize_prose(line)
        allowed = False
        if relative == Path("docs/agents/issue-tracker.md"):
            allowed = normalized_line == (
                "- Upstream remote: `https://github.com/uzairansaruzi/hermex.git` "
                "(read-only compatibility/sync input)"
            )
        elif relative == Path("README.md"):
            allowed = normalized_line == (
                "Hermex is an independent fork built on the upstream "
                "[hermes-webui](https://github.com/nesquena/hermes-webui) project and is not "
                "affiliated with its maintainers. The native app derives from "
                "[uzairansaruzi/hermex](https://github.com/uzairansaruzi/hermex); that repository "
                "remains a read-only compatibility input. Apple and SideStore are not affiliated "
                "with this project."
            )
        elif relative == Path("PROJECT_SPEC.md"):
            allowed = normalized_line == (
                "- Keep the app's read-only upstream remote at "
                "https://github.com/uzairansaruzi/hermex. Inspect app-upstream and inherited "
                "server drift weekly and before starting a large slice."
            )
            issue_match = re.fullmatch(
                r"- \[[^\]]+\]\(https://github\.com/uzairansaruzi/hermex/issues/(\d+)\)",
                normalized_line,
            )
            if issue_match and issue_match.group(1) in HISTORICAL_UPSTREAM_ISSUES:
                allowed = (
                    "inherited historical rationale and evidence from the predecessor repository"
                    in normalized_document
                    and "they are not current fork authority" in normalized_document
                )
        if not allowed:
            findings.append((line_number, normalized_line))
    return findings


def active_workflow_job(workflow: str, name: str) -> str:
    """Return one job after removing full-line comments that cannot affect Actions."""
    active = "\n".join(
        line for line in workflow.splitlines() if not line.lstrip().startswith("#")
    ) + "\n"
    match = re.search(
        rf"(?ms)^  {re.escape(name)}:\n.*?(?=^  [A-Za-z0-9_-]+:\n|\Z)",
        active,
    )
    if match is None:
        raise AssertionError(f"workflow is missing active job: {name}")
    return match.group(0)


def workflow_job_shape_findings(
    job: str,
    *,
    allowed_root_keys: set[str],
    job_name: str,
    expected_active_steps: int,
) -> list[str]:
    """Reject root-level execution overrides and additional active steps."""
    findings: list[str] = []
    root_keys = [
        line[4:].split(":", 1)[0].strip().strip("'\"")
        for line in job.splitlines()
        if line.startswith("    ")
        and not line.startswith("     ")
        and not line[4:].lstrip().startswith("#")
        and ":" in line[4:]
    ]
    unexpected = sorted(set(root_keys) - allowed_root_keys)
    if unexpected:
        findings.append(f"{job_name} job has unsupported root keys: {unexpected}")
    duplicates = sorted(key for key in set(root_keys) if root_keys.count(key) > 1)
    if duplicates:
        findings.append(f"{job_name} job has duplicate root keys: {duplicates}")
    if len(re.findall(r"^      -\s+\S", job, re.M)) != expected_active_steps:
        findings.append(
            f"{job_name} job must contain exactly {expected_active_steps} active steps"
        )
    return findings


def workflow_step_shape_findings(
    step: str, *, expected_keys: list[str], step_name: str
) -> list[str]:
    """Reject duplicate, reordered, or additional keys in one active step."""
    keys: list[str] = []
    for line in step.splitlines():
        if line.startswith("      - "):
            candidate = line[8:]
        elif line.startswith("        ") and not line.startswith("         "):
            candidate = line[8:]
        else:
            continue
        if candidate.lstrip().startswith("#") or ":" not in candidate:
            continue
        keys.append(candidate.split(":", 1)[0].strip().strip("'\""))
    if keys != expected_keys:
        return [
            f"{step_name} step keys must be exactly {expected_keys}, found {keys}"
        ]
    return []


def contract_job_bypass_findings(job: str) -> list[str]:
    """Return conditions that can let the contract job or validator step skip."""
    findings = workflow_job_shape_findings(
        job,
        allowed_root_keys={"name", "runs-on", "timeout-minutes", "env", "outputs", "steps"},
        job_name="contract",
        expected_active_steps=2,
    )
    before_steps = job.split("    steps:\n", 1)[0]
    for key in ("if", "continue-on-error", "strategy", "defaults"):
        if re.search(rf"(?m)^    {re.escape(key)}:", before_steps):
            findings.append(f"contract job contains forbidden job key `{key}`")

    expected_output = "    outputs:\n      validated: ${{ steps.validate.outputs.validated }}\n"
    if expected_output not in before_steps:
        findings.append("contract job does not expose the validator execution proof")

    checkout_matches = re.findall(
        r"(?ms)^      - name: Check out\n.*?(?=^      - |\Z)",
        job,
    )
    expected_checkout = "      - name: Check out\n        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n"
    if (
        len(checkout_matches) != 1
        or checkout_matches[0].rstrip("\n") != expected_checkout.rstrip("\n")
    ):
        findings.append("checkout step is not the exact fixed action block")

    matches = list(
        re.finditer(
            r"(?ms)^      - name: Validate canonical contract\n.*?(?=^      - name:|\Z)",
            job,
        )
    )
    if len(matches) != 1:
        findings.append("contract job must have exactly one named validator step")
        return findings

    validator_step = matches[0].group(0)
    findings.extend(
        workflow_step_shape_findings(
            validator_step,
            expected_keys=["name", "id", "run"],
            step_name="validator",
        )
    )
    for key in ("if", "continue-on-error", "env", "shell", "working-directory"):
        if re.search(rf"(?m)^        {re.escape(key)}:", validator_step):
            findings.append(f"validator step contains forbidden key `{key}`")

    expected_step = (
        "      - name: Validate canonical contract\n"
        "        id: validate\n"
        "        run: |\n"
        "          set -euo pipefail\n"
        "          expected_count=25\n"
        "          log_file=$(mktemp)\n"
        "          trap 'rm -f \"${log_file}\"' EXIT\n"
        "          python3 -m unittest tests/test_fork_contract.py -v 2>&1 | tee \"${log_file}\"\n"
        "          actual_count=$(\n"
        "            python3 - \"${log_file}\" <<'PY'\n"
        "          import re\n"
        "          import sys\n"
        "\n"
        "          text = open(sys.argv[1], encoding=\"utf-8\").read()\n"
        '          counts = re.findall(r"(?m)^Ran (\\d+) tests in ", text)\n'
        "          if len(counts) != 1:\n"
        '              raise SystemExit(f"expected one unittest count, found {counts}")\n'
        "          print(counts[0])\n"
        "          PY\n"
        "          )\n"
        '          if [[ "${actual_count}" != "${expected_count}" ]]; then\n'
        '            echo "Contract test manifest mismatch: expected ${expected_count}, found ${actual_count}." >&2\n'
        "            exit 1\n"
        "          fi\n"
        "          printf 'validated=true\\n' >> \"$GITHUB_OUTPUT\"\n"
    )
    if expected_step not in validator_step:
        findings.append("validator step is not the exact fail-closed command block")
    expected_job = (
        "  contract:\n"
        "    name: Improvements contract\n"
        "    runs-on: ubuntu-latest\n"
        "    timeout-minutes: 5\n"
        "    env:\n"
        "      PYTHONDONTWRITEBYTECODE: '1'\n"
        "    outputs:\n"
        "      validated: ${{ steps.validate.outputs.validated }}\n"
        "    steps:\n"
        "      - name: Check out\n"
        "        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n"
        "\n"
        + expected_step
    )
    if job.rstrip("\n") != expected_job.rstrip("\n"):
        findings.append("contract job is not the exact fail-closed job block")
    if "|| true" in validator_step or re.search(r"(?m)^\s*exit 0\s*$", validator_step):
        findings.append("validator step contains an explicit success bypass")
    return findings


def required_workflow_gate_findings(workflow: str) -> list[str]:
    """Return ways the required contract or path-correlated build gate can become inert."""
    findings: list[str] = []
    actual_digest = executable_workflow_sha256(workflow)
    if actual_digest != PR_CI_EXECUTABLE_SHA256:
        findings.append(
            "PR CI executable workflow differs from the reviewed canonical digest: "
            f"{actual_digest}"
        )
    active = "\n".join(
        line for line in workflow.splitlines() if not line.lstrip().startswith("#")
    ) + "\n"

    for job_name in ("contract", "gate"):
        count = len(re.findall(rf"(?m)^  {job_name}:\s*$", active))
        if count != 1:
            findings.append(f"workflow must contain exactly one active `{job_name}` job")
    if findings:
        return findings

    contract_job = active_workflow_job(active, "contract")
    findings.extend(contract_job_bypass_findings(contract_job))

    gate_job = active_workflow_job(active, "gate")
    findings.extend(
        workflow_job_shape_findings(
            gate_job,
            allowed_root_keys={"name", "needs", "if", "runs-on", "timeout-minutes", "steps"},
            job_name="gate",
            expected_active_steps=1,
        )
    )
    before_steps = gate_job.split("    steps:\n", 1)[0]
    if len(re.findall(r"(?m)^    if: always\(\)\s*$", before_steps)) != 1:
        findings.append("gate job must run exactly once with `if: always()`")
    for key in ("continue-on-error", "strategy", "defaults"):
        if re.search(rf"(?m)^    {re.escape(key)}:", before_steps):
            findings.append(f"gate job contains forbidden job key `{key}`")

    matches = list(
        re.finditer(r"(?ms)^      - name: Check results\n.*?(?=^      - name:|\Z)", gate_job)
    )
    if len(matches) != 1:
        findings.append("gate job must have exactly one result-check step")
        return findings

    gate_step = matches[0].group(0)
    findings.extend(
        workflow_step_shape_findings(
            gate_step,
            expected_keys=["name", "run"],
            step_name="gate result",
        )
    )
    for key in ("if", "continue-on-error", "env", "shell", "working-directory"):
        if re.search(rf"(?m)^        {re.escape(key)}:", gate_step):
            findings.append(f"gate result step contains forbidden key `{key}`")
    expected_gate_step = (
        "      - name: Check results\n"
        "        run: |\n"
        "          set -euo pipefail\n"
        '          echo "changes: ${{ needs.changes.result }}"\n'
        '          echo "contract: ${{ needs.contract.result }}"\n'
        '          echo "contract validated: ${{ needs.contract.outputs.validated }}"\n'
        '          echo "run_ios: ${{ needs.changes.outputs.run_ios }}"\n'
        '          echo "test: ${{ needs.test.result }}"\n'
        '          if [[ "${{ needs.changes.result }}" != "success" ]]; then\n'
        '            echo "Path detection failed — failing the gate." >&2\n'
        "            exit 1\n"
        "          fi\n"
        '          if [[ "${{ needs.contract.result }}" != "success" ]]; then\n'
        '            echo "Improvements contract validation failed — failing the gate." >&2\n'
        "            exit 1\n"
        "          fi\n"
        '          if [[ "${{ needs.contract.outputs.validated }}" != "true" ]]; then\n'
        '            echo "Improvements contract validator did not prove execution — failing the gate." >&2\n'
        "            exit 1\n"
        "          fi\n"
        '          if [[ "${{ needs.changes.outputs.run_ios }}" == "true" ]]; then\n'
        '            if [[ "${{ needs.test.result }}" != "success" ]]; then\n'
        '              echo "Build and Test was required but did not pass — failing the gate." >&2\n'
        "              exit 1\n"
        "            fi\n"
        '          elif [[ "${{ needs.changes.outputs.run_ios }}" == "false" ]]; then\n'
        '            if [[ "${{ needs.test.result }}" != "skipped" ]]; then\n'
        '              echo "Build and Test ran unexpectedly for a docs-only change — failing the gate." >&2\n'
        "              exit 1\n"
        "            fi\n"
        "          else\n"
        '            echo "Path detection returned an invalid run_ios value — failing the gate." >&2\n'
        "            exit 1\n"
        "          fi\n"
        '          echo "Gate passed."\n'
    )
    if gate_step.rstrip("\n") != expected_gate_step.rstrip("\n"):
        findings.append("gate result step is not the exact fail-closed command block")
    expected_gate_job = (
        "  gate:\n"
        "    name: CI Gate\n"
        "    needs: [changes, contract, test]\n"
        "    if: always()\n"
        "    runs-on: ubuntu-latest\n"
        "    timeout-minutes: 5\n"
        "    steps:\n"
        + expected_gate_step
    )
    if gate_job.rstrip("\n") != expected_gate_job.rstrip("\n"):
        findings.append("gate job is not the exact fail-closed job block")
    if "|| true" in gate_step or re.search(r"(?m)^\s*exit 0\s*$", gate_step):
        findings.append("gate result step contains an explicit success bypass")

    required = (
        "    needs: [changes, contract, test]",
        'echo "contract validated: ${{ needs.contract.outputs.validated }}"',
        'if [[ "${{ needs.contract.outputs.validated }}" != "true" ]]; then',
        'if [[ "${{ needs.changes.outputs.run_ios }}" == "true" ]]; then',
        'if [[ "${{ needs.test.result }}" != "success" ]]; then',
        'elif [[ "${{ needs.changes.outputs.run_ios }}" == "false" ]]; then',
        'if [[ "${{ needs.test.result }}" != "skipped" ]]; then',
    )
    for snippet in required:
        if snippet not in gate_job:
            findings.append(f"gate is missing required check: {snippet}")
    return findings


class ForkContractTests(unittest.TestCase):
    maxDiff = None

    def assert_contains_all(self, text: str, snippets: tuple[str, ...], label: str) -> None:
        missing = [snippet for snippet in snippets if snippet not in text]
        self.assertFalse(missing, f"{label} is missing required contract text: {missing}")

    def test_improvements_contract_locks_every_approved_decision(self) -> None:
        self.assertTrue(
            CONTRACT.is_file(),
            "missing canonical contract: docs/improvements-contract.md",
        )
        contract = read(CONTRACT)
        self.assert_contains_all(
            normalize_prose(contract),
            (
                "# Improvements Contract",
                "Improvements is the bounded-context name.",
                "`Feature` is not a persisted domain entity.",
                "Improvement Subject",
                "UI label is **Subject**",
                "Dream Cycle is an immutable attempt",
                "Proposal Update",
                "Proposal Decision",
                "Outcome",
                "Dream Perspective",
                "Subject Guidance",
                "Learning Hypothesis",
                "ordered audit and sync events",
                "WebUI fork is the canonical server system of record.",
                "iOS cache is a replaceable projection",
                "read-only while offline",
                "server version wins",
                "explicit conflict",
                "Cron, Sessions, Profiles, Projects, and Kanban remain native referenced systems",
                "stable opaque IDs",
                "idempotency key",
                "additive minor versions",
                "explicitly incompatible major version",
                "ordered cursor sync",
                "`previous_cursor`",
                "`high_water_cursor`",
                "`snapshot_cursor`",
                "`reset_required`",
                "strictly after that snapshot cursor",
                "dedicated SQLite database under `HERMES_WEBUI_STATE_DIR`",
                "global to one WebUI deployment",
                "not scoped to the currently active Hermes Profile",
                "stdlib `sqlite3`",
                "WAL mode",
                "foreign keys",
                "explicit schema migrations",
                "backup before every migration",
                "must not copy whole Sessions",
                "must not temporarily switch process-global `HERMES_HOME`",
                "Subject-linked and consented Profiles and Context Sources",
                "broad cross-Profile Session and Memory retrieval",
                "all current Hermes Profiles",
                "provider and model",
                "source classes",
                "item, token, and excerpt caps",
                "redaction",
                "audit",
                "renewed when the scope or provider changes",
                "current Consent Grant",
                "the server checks the current Consent Grant immediately before every retrieval",
                "immediately before every retrieval and every provider submission",
                "If consent expires during a Cycle, or is revoked",
                "Retrieved text is untrusted data",
                "`paused`, `enabled`, `degraded`, or `archived`",
                "`queued`, `running`, `succeeded`, `no_proposal`, `invalid_output`, `failed`, `cancelled`, `unknown`, `skipped_overlap`, or `skipped_policy`",
                "Cron job ID is an adapter reference",
                "one deployment scheduling timezone: `Europe/Oslo`",
                "next three wall-clock runs and UTC offsets",
                "Only one Dream Cycle may run for a Subject",
                "never queues a backlog",
                "duplicate **Run Now** opens the active Cycle",
                "`catch_up`",
                "**Stop after current Cycle**",
                "does not offer a hard-cancel",
                "`cancellation_requested`",
                '"schemaVersion": 1',
                "local-delivery only",
                "within 90 seconds",
                "managed Dream jobs",
                "does not depend on APNs",
                "Seeded and newly created Dream Schedules start Paused",
                "one-shot Cron job",
                "explicit IANA timezone",
                "Cron is an idempotent execution projection",
                "one bounded retry",
                "exactly one Lead Profile and one Lead Dream Perspective",
                "optional Critic",
                "up to five Proposals",
                "Reject a candidate before scoring",
                "`verified`, `strong_inference`, `assumption`, or `speculation`",
                "no concrete problem/opportunity, impact, or acceptance evidence",
                "exact duplicate",
                "out-of-scope autonomy",
                "required Critic fails, no Proposal enters the inbox",
                "`single_pass`",
                "hard-gate failure regardless of numeric score",
                "Evidence 25",
                "Impact 20",
                "Novelty 15",
                "Specificity and testability 15",
                "Feasibility and scope 15",
                "Strategic fit 10",
                "quality threshold is 70",
                "zero Proposals is valid",
                "ranking-only and reversible",
                "use them immediately as soft retrieval/ranking influences",
                "must not affect the publication threshold",
                "weak provisional influence",
                "Repeated independent support raises confidence",
                "Contradicting outcomes lower it",
                "decay after 90 days without support",
                "history, pin, correct, disable, and reset controls",
                "Accept starts nothing",
                "create-only is the quiet default",
                "Open Draft Session",
                "Save to Triage",
                "`triage`",
                "Create & Start Work",
                "`todo`",
                "valid assignee",
                "blocked by dependencies",
                "existing gateway dispatcher",
                "must not start a second persistent dispatcher",
                "Create & Start",
                "one confirmation",
                "resumable idempotent Improvements-domain saga",
                "Reserve the Handoff intent",
                "Create or recover the destination",
                "Persist the target ID",
                "Request execution",
                "Session creation has no equivalent native key",
                "Never delete a destination automatically",
                "Needs attention",
                "180 days",
                "90 days",
                "14 days",
                "explicit permanent Subject purge",
                "external Sessions and Cards remain",
                "Only a new threshold-clearing Proposal or a material Proposal Update increments unread",
                "Handoff and Outcome changes appear in History without increasing unread",
                "Allowed transitions",
                "Changing a Proposal away from `accepted` does not cancel",
                "At the issue #14 bootstrap baseline, the intended future repository name was `ebreen/hermes-webui`",
                "had not been created",
                "`WEBUI_FORK_TESTED_SHA`",
                "unauthenticated fixed-host fetch",
                "proves `FETCH_HEAD` equals that pin",
                "no server implementation slice may start",
                "Apple-credential-free, SideStore-ready IPA",
                "local ad-hoc signatures",
                "zero-signature Mach-O",
                "`Hermex`",
                "`no.gior.hermex`",
                "`group.no.gior.hermex`",
                "No Apple signing secrets",
                "autonomous product decisions",
                "identity, credentials, or irreversible external actions",
            ),
            "docs/improvements-contract.md",
        )

        normalized = normalize_prose(contract)
        required_rules = (
            "The WebUI fork is the canonical server system of record. "
            "The iOS cache is a replaceable projection.",
            "Cron is an idempotent execution projection, not the schedule system of record.",
            "Accept starts nothing. Accept appends a Proposal Decision only; it creates no "
            "Session, Card, issue, branch, commit, Handoff, or worker run.",
            "Learning is ranking-only and reversible",
            "Retrieved text is untrusted data, never an instruction, authorization, tool call, "
            "or permission expansion.",
        )
        missing_rules = [rule for rule in required_rules if rule not in normalized]
        self.assertEqual([], missing_rules, f"missing complete normative rules: {missing_rules}")

        findings = semantic_reversal_findings(contract + "\n" + read(ROOT / "PROJECT_SPEC.md"))
        self.assertEqual([], findings, f"semantic contract reversals remain: {findings}")

    def test_contract_closes_reviewed_safety_and_state_machine_gaps(self) -> None:
        raw_contract = read(CONTRACT)
        self.assertNotRegex(
            raw_contract,
            r"The immutable snapshot is evidence[\s\S]{0,160}\*{3}",
            "ongoing authorization clause has no live actor/verb",
        )
        self.assertIn(
            "The immutable snapshot is evidence, not ongoing authorization: the server\n"
            "checks the current Consent Grant immediately before every retrieval and every provider\n"
            "submission, and again between bounded batches.",
            raw_contract,
        )
        self.assertNotRegex(
            raw_contract,
            r"idempotency key\. A\s+A `defer_elapsed`",
            "doubled article before the defer_elapsed return rule",
        )
        contract = normalize_prose(raw_contract)
        self.assert_contains_all(
            contract,
            (
                "A non-empty page's `next_cursor` is exactly the cursor of its final event",
                "An empty page returns `next_cursor` equal to the echoed `from_cursor`",
                "unknown lifecycle or side-effect-bearing enum value",
                "visible unsupported state",
                "Proposal kind is exactly `Feature` or `Improvement`",
                "Lead and Critic execution has read-only source access",
                "cannot commit, open a pull request, edit a Card, create a Session, change a Schedule, invoke a Handoff, or recursively schedule work",
                "Changing either effective provider pauses the Schedule",
                "Only the authenticated product owner may issue or renew a Consent Grant",
                "The server persists that exact confirmation payload",
                "Schedule enablement fails without a matching active Consent Grant",
                "trusted workdir and permitted toolsets",
                "model fallback may run only inside the already approved provider trust boundary",
                "must inspect it before making a current factual claim",
                "recreates a missing projection",
                "next reconciliation invokes the operation automatically",
                "Repair from Schedule",
                "Adopt changes",
                "orphaned owned job is paused and reported",
                "scheduler heartbeat is unhealthy",
                "restores only to `paused`",
                "A failed Handoff may resume",
                "Abandon handoff projects it to `cancelled`",
                "Defer records a required `review_after` timestamp",
                "exactly one idempotent `defer_elapsed` Review Return event",
                "returns the Proposal from `deferred` to `reviewing`",
                "first transaction commits the Schedule as `degraded`",
                "does not repair the projection",
                "stored `cron_projection_id`",
                "lexicographically smallest valid managed job ID is the deterministic winner",
                "If an assignee Profile disappears after Card creation, the Card remains",
                "`reassignment_required`",
                "requests reassignment",
                "terminal and cannot be reactivated",
                "Renewal creates a new Consent Grant with a new stable ID",
                "`renewed_from_grant_id`",
                "consent expires during a Cycle",
                "policy-blocked terminal result is never automatically retried",
                "Exactly-once creation is claimed only when the destination enforces the Handoff idempotency key",
                "single-worker lease and fencing token",
                "durable invocation marker",
                "lease expiry after a native attempt",
                "outcome-uncertain",
                "must not automatically retry",
                "must not call `/api/session/new` again",
                "Link existing Session",
                "Create another despite possible duplicate",
                "new linked Handoff",
                "destination-creation key is independent of create or start intent",
                "separate start-operation key",
                "changed start payload",
                "script-only admission adapter",
                "before any native agent invocation, retrieval, or provider submission",
                "durable per-Subject lease",
                "monotonically increasing fencing token",
                "zero retrieval or provider egress",
                "stale fencing token",
                "current authorization epoch of every named Context Source",
                "`source_suspended` or `source_revoked`",
                "A result already in flight is retained only as a policy-stop audit digest",
                "automatic takeover remains blocked even after the deadline",
                "Lead and Critic role independently",
                "`manual_once`",
                "does not enable recurrence",
                "same authenticated WebUI origin",
                "No third-party database or analytics service receives Improvements data",
                "native target version",
                "`stale_preview`",
                "idempotent `prepare_target` step",
                "creation-key hash and start-operation-key hash",
                "creation-payload hash and start-payload hash",
                "across every non-purged Proposal",
                "including all six declared review states",
                "never treated as Proposal review states",
                "Proposal has no `archived`, `abandoned`, or `implemented` review state",
                "tracked `APP_IDENTIFIER_SUFFIX` and `APP_URL_SCHEME_SUFFIX` assignments remain empty",
                "resolved build settings for every target and configuration",
                "Both app-group entitlement consumers use that same canonical variable",
                "Probabilistic similarity is retrieval only",
                "must not reject a candidate by itself",
                "records `skipped_policy` and exactly one closed reason code",
                "No other admission-failure state or reason is valid",
                "`uncertain_invocation_blocked`",
                "`queued` may become `running`, `cancelled`, `skipped_overlap`, `skipped_policy`, or `failed`",
                "Goal mode, retry limits",
                "`evidence_reopened` Review Return event",
                "resets its 180-day compaction clock",
                "`reopens_compacted` edge",
                "never appends an unread Update to a hollow compacted Proposal",
                "deterministic fold across all Handoffs",
                "`Verified` > `Implemented` > `In Progress` > `Planned` > `Discussing`",
                "ever entered `accepted` or `deferred`",
                "`succeeded`, `no_proposal`, `invalid_output`, `failed`, `cancelled`, `unknown`, `skipped_overlap`, and `skipped_policy`",
                "Grant confirmation evidence",
                "provider-submission provenance",
                "strongest positive",
                "no preference signal",
            ),
            "reviewed safety/state contract",
        )

    def test_contract_closes_transferable_exact_review_findings(self) -> None:
        contract = normalize_prose(read(CONTRACT))
        self.assert_contains_all(
            contract,
            (
                "Every Consent Grant renewal creates a new Grant ID, even when scope and provider are unchanged",
                "Archived Subjects do not consume `defer_elapsed`",
                "restoration reconciliation atomically appends the deterministic `defer_elapsed` event",
                "A paused Schedule with an active Cron projection",
                "`hermex-fork`",
                "`hermes-agent-deployment`",
                "Each receives one suggested daily Schedule template",
                "Both templates start paused, permit **Run Now**, and suggest staggered overnight times",
                "explicit confirmation of timezone, Profile, source policy, consent, and provider/model behavior",
                "Additional Subjects remain user-addable",
                "same target Card from `triage` to `todo`",
                "must never create a second Card",
                "confirmed preview snapshot",
                "Handoff idempotency-key hash",
                "each saga step and error category",
                "Preservation overrides compaction",
                "Delivery State other than `Unsent`",
                "regardless of its current review state",
                "Semantic Versioning controls `CFBundleShortVersionString`",
                "Development versions use `0.y.z`",
                "After the identity epoch, later SemVer changes do not require a trusted-validator modification",
                "Every target advances together",
                "first acceptance-complete physical-iPhone release is `1.0.0`",
                "monotonic protected release-workflow run number",
                "immutable GitHub run ID and exact source commit",
                "`Hermex-<version>-<build>-<short-source>.ipa`",
                "PR artifacts expire after 14 days",
                "Merged-`master` diagnostic artifacts expire after 30 days",
                "retained with its GitHub Release",
                "latest known-good release",
                "new, higher `CFBundleVersion`",
                "Issue #15 is the explicit migration blocker",
                "preserve the exact issue #14 identity quarantine or complete the canonical issue #15 migration",
                "Partial identity migration fails",
                "must not produce or publish a release artifact",
                "does not authorize a signing or upload path",
            ),
            "transferable exact-review findings",
        )
        self.assertNotIn("A disabled Schedule with an active projection", contract)
        self.assertNotIn("Eir" + "ik", contract)

        readme = normalize_prose(read(ROOT / "README.md"))
        self.assertIn("docs/improvements-contract.md", readme)
        self.assertIn(
            "canonical and normative for the Improvements bounded context",
            readme,
        )
        self.assertNotIn(
            "`PROJECT_SPEC.md`: source of truth for product scope, API behavior, dependencies, and architecture decisions",
            readme,
        )

    def test_contract_defines_the_dream_result_wire_enum(self) -> None:
        contract = normalize_prose(read(CONTRACT))
        self.assertNotIn('"result": "proposals-or-no-proposal"', contract)
        self.assert_contains_all(
            contract,
            (
                "The `result` enum is exactly `proposals` or `no_proposal`",
                "`proposals` requires from one through five validated Proposal objects",
                "`no_proposal` requires an empty `proposals` array",
                "Cycle failure states are never valid Dreamer envelope `result` values",
            ),
            "Dream result wire contract",
        )

    def test_fork_release_validation_is_canonical_and_upstream_is_compatibility_only(self) -> None:
        spec = normalize_prose(read(ROOT / "PROJECT_SPEC.md"))
        self.assertIn(
            "Contract tests must pass against the canonical fork commit pinned in `WEBUI_FORK_TESTED_SHA`",
            spec,
        )
        self.assertIn("Upstream is a separate inherited-compatibility comparison", spec)
        self.assertIn("Upstream counts and activity are volatile", spec)
        for stale_stat in ("5,200+ stars", "660+ forks", "67+ open issues"):
            self.assertNotIn(stale_stat, spec)
        self.assertNotIn(
            "Contract tests pass against the upstream tag pinned in `UPSTREAM_TESTED_SHA`",
            spec,
        )

    def test_context_preserves_kanban_and_defines_improvements_language(self) -> None:
        context = read(ROOT / "CONTEXT.md")
        self.assert_contains_all(
            context,
            (
                "## Kanban",
                "**Board**:",
                "**Card**:",
                "**Status**:",
                "**Dispatcher**:",
                "**Run Dispatcher**:",
                "**Archive Board**:",
                "## Improvements",
                "**Improvement Subject** (UI: **Subject**):",
                "**Context Source**:",
                "**Dream Schedule**:",
                "**Dream Cycle**:",
                "**Proposal**:",
                "**Proposal Update**:",
                "**Proposal Decision**:",
                "**Handoff**:",
                "**Outcome**:",
                "**Dream Perspective**:",
                "**Subject Guidance**:",
                "**Learning Hypothesis**:",
                "**Audit Event**:",
                "**Sync Event**:",
                "`Feature` is not a persisted domain entity",
                "Unsent, Discussing, Planned, In Progress, Implemented, Verified, or Abandoned",
            ),
            "CONTEXT.md",
        )
        self.assertNotIn("## Features & Improvements", context)

    def test_canonical_docs_reject_superseded_contracts(self) -> None:
        findings: list[str] = []
        scanned = 0
        for path in MAINTAINED_GUIDANCE:
            scanned += 1
            for line_number, pattern, line in superseded_guidance_findings(read(path)):
                findings.append(f"{path.name}:{line_number}: /{pattern}/ -> {line}")
        self.assertEqual(
            len(MAINTAINED_GUIDANCE),
            scanned,
            "superseded-guidance scan did not visit the maintained inventory",
        )
        self.assertEqual([], findings, "superseded canonical statements remain:\n" + "\n".join(findings))

    def test_all_maintained_guidance_rejects_semantic_reversals(self) -> None:
        findings: list[str] = []
        scanned = 0
        for path in MAINTAINED_GUIDANCE:
            scanned += 1
            for pattern in semantic_reversal_findings(read(path)):
                findings.append(f"{path.relative_to(ROOT)}: /{pattern}/")
        self.assertEqual(
            len(MAINTAINED_GUIDANCE),
            scanned,
            "semantic-reversal scan did not visit the maintained inventory",
        )
        self.assertEqual([], findings, "semantic reversals remain:\n" + "\n".join(findings))

    def test_maintained_guidance_inventory_and_enforcement_contact_are_fork_owned(self) -> None:
        maintained = set(MAINTAINED_GUIDANCE)
        root_guidance = set(ROOT.glob("*.md"))
        issue_guidance = set((ROOT / ".github" / "ISSUE_TEMPLATE").glob("*.y*ml"))
        self.assertFalse(root_guidance - maintained)
        self.assertFalse(issue_guidance - maintained)

        code_of_conduct = read(ROOT / "CODE_OF_CONDUCT.md")
        self.assertNotIn("@uzairansaruzi", code_of_conduct)
        self.assertIn("ebreen@proton.me", code_of_conduct)

    def test_unrelated_negation_does_not_hide_superseded_guidance(self) -> None:
        for poison in (
            "Do not ignore this, Hermex is an iOS client only.",
            "Do not be confused because Hermex is an iOS client only.",
        ):
            findings = superseded_guidance_findings(poison)
            self.assertIn(
                r"Hermex (?:is|contains) (?:an? )?(?:iOS|mobile) client only",
                {pattern for _, pattern, _ in findings},
            )

    def test_superseded_guidance_scan_allows_valid_safety_wording(self) -> None:
        valid = (
            "The iOS client only submits mutations while online; offline state is read-only.",
            "Native Memory writes are forbidden for Improvements.",
            "Never call `/api/memory/write`; Improvements cannot mutate native Memory.",
            "Do not stop and ask before changing an ordinary reversible product detail.",
            "This is not a single-context repo.",
            "`CONTEXT.md` is not optional.",
            "`PROJECT_SPEC.md` is not canonical.",
        )
        for sentence in valid:
            self.assertEqual([], superseded_guidance_findings(sentence), sentence)

    def test_superseded_guidance_detector_rejects_multiline_positive_mutations(self) -> None:
        poisoned = """If a request conflicts with it,
stop and ask before implementing the product.
Improvements may
write native Memory.
This is a single-context repo.
There is no required `CONTEXT.md`.
If these files do not exist, proceed silently.
`CONTEXT.md` is optional.
`PROJECT_SPEC.md` is canonical.
"""
        findings = superseded_guidance_findings(poisoned)
        matched_patterns = {pattern for _, pattern, _ in findings}
        self.assertIn(r"if a request conflicts with it,\s*stop and ask", matched_patterns)
        self.assertIn(
            r"Improvements (?:may|can|does|will) (?:write|edit|mutate) (?:native )?Memory",
            matched_patterns,
        )
        for pattern in (
            r"This is a single-context repo",
            r"no required `?CONTEXT\.md`?",
            r"If these files do not exist, proceed silently",
            r"`?CONTEXT\.md`? (?:is|remains) optional",
            r"`?PROJECT_SPEC\.md`? (?:is|remains) (?:canonical|co-equal)",
        ):
            self.assertIn(pattern, matched_patterns)

    def test_each_prohibited_guidance_rule_is_live_in_isolation(self) -> None:
        poisons = (
            "You are NOT modifying the upstream.",
            "Hermex is an iOS client only.",
            "We can revisit forking later.",
            "Upstream is the ground truth for exact JSON shapes.",
            "Ship TestFlight first.",
            "Use bundle identifier com.predecessor.mobileapp.",
            "Use Apple Team " + "ABCDE" + "12345.",
            "Clone hermes-mobile-ios.",
            "Download from apps.apple.com/app/hermex.",
            "Use hermexapp.com.",
            "Donate at buymeacoffee.com/callmeuzi.",
            "This repository contains only the iOS client.",
            "Do not modify the upstream hermes-webui.",
            "Improvements may write native Memory.",
            "Call /api/memory/write.",
            "If a request conflicts with it, stop and ask.",
            "Stop and ask before implementing the product.",
            "Ask before touching ordinary product details.",
            "Ask the human before every ordinary decision.",
            "This is a single-context repo.",
            "There is no required CONTEXT.md.",
            "If these files do not exist, proceed silently.",
            "CONTEXT.md is optional.",
            "PROJECT_SPEC.md is canonical.",
        )
        self.assertEqual(len(PROHIBITED_GUIDANCE), len(poisons))
        for pattern, poison in zip(PROHIBITED_GUIDANCE, poisons, strict=True):
            with self.subTest(pattern=pattern):
                matched = {item_pattern for _, item_pattern, _ in superseded_guidance_findings(poison)}
                self.assertIn(pattern, matched)

    def test_domain_agent_guidance_recognizes_the_canonical_bounded_context(self) -> None:
        domain = normalize_prose(read(ROOT / "docs" / "agents" / "domain.md"))
        self.assertIn("multiple bounded contexts", domain)
        self.assertIn("`docs/improvements-contract.md` is canonical and normative", domain)
        self.assertIn("`PROJECT_SPEC.md` is subordinate", domain)
        self.assertIn("`CONTEXT.md` is required", domain)
        self.assertIn("Do not proceed silently", domain)
        self.assertNotIn("single-context repo", domain)
        self.assertNotIn("no required `CONTEXT.md`", domain)

    def test_fork_owned_guidance_routes_to_the_fork(self) -> None:
        guidance = (
            ROOT / "README.md",
            ROOT / "SECURITY.md",
            ROOT / "CONTRIBUTING.md",
            ROOT / "DEVELOPMENT.md",
            ROOT / "TESTFLIGHT.md",
        )
        stale = [
            path.name
            for path in guidance
            if "github.com/uzairansaruzi/hermex" in read(path) and path.name != "README.md"
        ]
        self.assertEqual([], stale, f"fork guidance still routes to upstream owner: {stale}")
        routing_findings: list[tuple[str, int, str]] = []
        scanned = 0
        for path in MAINTAINED_GUIDANCE:
            scanned += 1
            for line_number, line in fork_routing_findings(path, read(path)):
                routing_findings.append((str(path.relative_to(ROOT)), line_number, line))
        self.assertEqual(
            len(MAINTAINED_GUIDANCE),
            scanned,
            "fork-routing scan did not visit the maintained inventory",
        )
        self.assertEqual([], routing_findings, f"maintained guidance routes to predecessor: {routing_findings}")
        poisoned_path = ROOT / ".github" / "ISSUE_TEMPLATE" / "upstream-help.yml"
        poisoned = "Open https://github.com/uzairansaruzi/hermex/issues for support."
        self.assertEqual(
            [(1, poisoned)],
            fork_routing_findings(poisoned_path, poisoned),
        )
        readme = read(ROOT / "README.md")
        self.assertNotIn(
            "upstream contract-test readiness",
            readme,
            "README still describes CONTRACT_TESTS.md as upstream readiness",
        )
        self.assertIn(
            "fork-owned contract-test readiness",
            readme,
            "README does not describe CONTRACT_TESTS.md as fork-owned",
        )
        triage_labels = read(ROOT / "docs" / "agents" / "triage-labels.md")
        self.assertIn(
            "fork-owned server behavior",
            triage_labels,
            "triage labels do not route fork-owned server defects to the fork",
        )
        self.assertNotIn(
            "As a client repo, a chunk of incoming bugs are really server bugs",
            triage_labels,
            "triage labels still treat this repo as an upstream-only client",
        )

    def test_readme_privacy_claim_matches_link_preview_networking(self) -> None:
        readme = read(ROOT / "README.md")
        self.assertNotIn("the app talks only to your server", readme)
        self.assertIn("Link previews", readme)
        self.assertIn("can contact third-party sites", readme)
        self.assertIn("Rendering a transcript can automatically fetch", readme)
        self.assertIn("link-preview metadata and remote media", readme)
        self.assertIn("expose the device IP address", readme)

    def test_distribution_and_ci_guidance_matches_active_side_store_path(self) -> None:
        active_guidance = "\n".join(
            read(path)
            for path in (
                ROOT / "README.md",
                ROOT / "CHANGELOG.md",
                ROOT / "CONTRIBUTING.md",
                ROOT / "PROJECT_SPEC.md",
                ROOT / "docs" / "agents" / "feature-gap-index.md",
            )
        )
        for stale_claim in (
            "For App Store submission",
            'App Store review for "remote shell" apps',
            "Version headings correspond to App Store releases",
            "`master` remains release-ready",
            "The same suite runs in CI on every pull",
        ):
            self.assertNotIn(stale_claim, active_guidance)
        self.assertIn("Apple-credential-free SideStore", active_guidance)
        self.assertIn("docs-only pull requests run only", active_guidance)
        self.assertIn("no installable release artifact", active_guidance)
        self.assertNotIn("`master` is the protected", active_guidance)
        self.assertIn("query GitHub before relying on branch protection", active_guidance)

        project_intent = read(ROOT / "PROJECT_INTENT.md")
        self.assertNotIn("Hermex is distributed", project_intent)
        self.assertIn("Hermex targets distribution", project_intent)

        changelog = read(ROOT / "CHANGELOG.md")
        self.assertIn("inherited predecessor planning history", changelog.lower())
        self.assertIn("not a hermex fork release", changelog.lower())
        contract = normalize_prose(read(CONTRACT))
        self.assert_contains_all(
            contract,
            (
                "issue #14 baseline `MARKETING_VERSION = 1.5` values",
                "Any local or upstream `v1.4.0` and `v1.5.0` tag refs",
                "Their absence from the fork remote does not authorize reusing those names",
                "inherited predecessor provenance",
                "fork identity epoch",
                "does not descend from that epoch",
                "atomically sets every target to `0.1.0`",
                "unauthenticated GET",
                "No archive, package, upload, or release may proceed",
            ),
            "fork version provenance",
        )

        workflow = read(ROOT / ".github" / "workflows" / "pr-ci.yml")
        self.assertNotIn("runs per TESTFLIGHT.md", workflow)
        self.assertIn("runs per DEVELOPMENT.md", workflow)

        onboarding = read(ROOT / "HermesMobile" / "Features" / "Onboarding" / "OnboardingFlowPolicy.swift")
        development = read(ROOT / "DEVELOPMENT.md")
        for guidance in (onboarding, development):
            self.assertIn("inherited", guidance)
            self.assertIn("compatibility", guidance)
            self.assertIn("Python", guidance)
        self.assertNotIn("Node.js web app", onboarding)
        self.assertNotIn("The password", onboarding)
        self.assertNotIn("Verify it works: curl http://$(tailscale ip -4)", onboarding)
        self.assertIn(
            "When using the bind-all fallback instead, curl http://$(tailscale ip -4):8787/health",
            onboarding,
        )
        self.assertIn("outside the agent transcript", onboarding)
        self.assertIn("tailscale serve", onboarding)
        self.assert_contains_all(
            normalize_prose(development),
            (
                "At the issue #14 bootstrap baseline, `ebreen/hermes-webui` had not been created",
                "Current server testing validates inherited compatibility",
                "After issue #45 creates the public fork",
                "that exact fork commit becomes the canonical primary target",
            ),
            "development fork transition",
        )
        self.assertNotIn(
            "This app is developed against the self-hosted canonical `ebreen/hermes-webui` fork",
            development,
        )
        project_spec = read(ROOT / "PROJECT_SPEC.md")
        self.assertNotIn(
            "generic Cron mutation,",
            project_spec,
            "PROJECT_SPEC still claims generic Cron mutation is omitted",
        )
        self.assertNotIn(
            "Do not expose create/edit/run/pause/resume",
            project_spec,
            "PROJECT_SPEC still declares Tasks read-only",
        )
        self.assertIn(
            "Dream projections are server-owned",
            project_spec,
            "PROJECT_SPEC does not separate Dream projections from generic Cron",
        )
        with tempfile.TemporaryDirectory(prefix="hermex-webui-guidance-poison-") as temp:
            poisoned_root = Path(temp)
            for relative in (
                "CONTRACT_TESTS.md",
                "DEVELOPMENT.md",
                "PROJECT_SPEC.md",
                "README.md",
                "docs/improvements-contract.md",
            ):
                target = poisoned_root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(read(ROOT / relative))
            poisoned_development = poisoned_root / "DEVELOPMENT.md"
            poisoned_development.write_text(
                poisoned_development.read_text()
                + "\nCurrent server: https://github.com/ebreen/hermes-webui\n"
            )
            findings = webui_fork_routing_findings(poisoned_root)
            self.assertTrue(
                any("DEVELOPMENT.md represents the unpinned WebUI fork as live" in item for item in findings)
            )

    def test_fork_owned_repository_metadata(self) -> None:
        self.assertEqual([], webui_fork_routing_findings(ROOT))
        with tempfile.TemporaryDirectory(prefix="hermex-webui-pin-") as temp:
            pin_root = Path(temp)
            guidance_paths = (
                "CONTRACT_TESTS.md",
                "DEVELOPMENT.md",
                "PROJECT_SPEC.md",
                "README.md",
                "docs/improvements-contract.md",
            )
            for relative in guidance_paths:
                path = pin_root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("unpinned fork guidance\n")
            self.assertEqual([], webui_fork_routing_findings(pin_root))

            fork_url = "https://github.com/ebreen/hermes-webui"
            (pin_root / "README.md").write_text(f"premature {fork_url}\n")
            self.assertEqual(
                ["README.md represents the unpinned WebUI fork as live"],
                webui_fork_routing_findings(pin_root),
            )

            for relative in guidance_paths:
                (pin_root / relative).write_text(f"live fork: {fork_url}\n")
            (pin_root / "WEBUI_FORK_TESTED_SHA").write_text("a" * 40 + "\n")
            self.assertEqual([], webui_fork_routing_findings(pin_root))

            (pin_root / "PROJECT_SPEC.md").write_text("missing live fork route\n")
            self.assertEqual(
                ["PROJECT_SPEC.md omits the pinned live WebUI fork"],
                webui_fork_routing_findings(pin_root),
            )
            (pin_root / "PROJECT_SPEC.md").write_text(f"live fork: {fork_url}\n")
            (pin_root / "WEBUI_FORK_TESTED_SHA").write_text("not-a-commit\n")
            self.assertEqual(
                ["WEBUI_FORK_TESTED_SHA is not a full lowercase commit SHA"],
                webui_fork_routing_findings(pin_root),
            )
        self.assertEqual("* @ebreen", read(ROOT / ".github" / "CODEOWNERS").strip())
        self.assertFalse(
            (ROOT / ".github" / "FUNDING.yml").exists(),
            "fork must not publish inherited upstream funding metadata",
        )
        contacts = read(ROOT / ".github" / "ISSUE_TEMPLATE" / "config.yml")
        self.assertIn("github.com/ebreen/hermex/blob/master/SECURITY.md", contacts)
        self.assertIn("github.com/ebreen/hermex/issues/45", contacts)
        self.assertNotIn("uzairansaruzi/hermex", contacts)
        self.assertNotIn("ebreen/hermex/discussions", contacts)

        bug_form = read(ROOT / ".github" / "ISSUE_TEMPLATE" / "bug_report.yml")
        self.assertIn("SideStore artifact", bug_form)
        self.assertIn("WEBUI_FORK_TESTED_SHA", bug_form)
        self.assertNotIn("TestFlight build", bug_form)
        feature_form = read(ROOT / ".github" / "ISSUE_TEMPLATE" / "feature_request.yml")
        for form in (bug_form, feature_form):
            self.assert_contains_all(
                normalize_prose(form),
                (
                    "GitHub issues and attachments are public",
                    "I removed credentials, authorization headers, private server URLs, prompts, transcripts, Memory excerpts",
                    "Security vulnerabilities must use the private process in SECURITY.md",
                    "required: true",
                ),
                "public issue privacy acknowledgment",
            )
        production_testflight = [
            str(path.relative_to(ROOT))
            for path in (ROOT / "HermesMobile").rglob("*.swift")
            if "TestFlight" in read(path)
        ]
        self.assertEqual(
            [],
            production_testflight,
            f"production UI still names the retired TestFlight path: {production_testflight}",
        )
        self.assertEqual([], app_config_route_findings(ROOT))
        with tempfile.TemporaryDirectory(prefix="hermex-route-decoy-") as temp:
            route_root = Path(temp)
            route_path = route_root / "HermesMobile" / "Config" / "AppConfig.swift"
            route_path.parent.mkdir(parents=True)
            route_path.write_text(
                "import Foundation\n"
                "enum AppConfig {\n"
                '    static let privacyPolicyURL = URL(staticString: "https://github.com/ebreen/hermex/blob/master/PRIVACY.md")\n'
                '    static let supportURL = URL(staticString: "https://github.com/uzairansaruzi/hermex/issues")\n'
                '    static let decoy = "https://github.com/ebreen/hermex/issues"\n'
                "}\n"
            )
            route_findings = app_config_route_findings(route_root)
            self.assertTrue(any("supportURL must declare exactly" in item for item in route_findings))
            self.assertTrue(any("routes production UI to predecessor owner" in item for item in route_findings))
        privacy = read(ROOT / "PRIVACY.md")
        self.assert_contains_all(
            normalize_prose(privacy),
            (
                "user-configured Hermes server",
                "automatic link-preview metadata requests",
                "remote media requests",
                "IP address and request metadata",
                "does not include a third-party analytics SDK",
                "GitHub Issues are public",
                "Do not include credentials, authorization headers, private server URLs, prompts, transcripts, or Memory excerpts",
            ),
            "fork privacy notice",
        )
        expected_inherited_identity = sorted(
            [
                ("Config/Shared.xcconfig", f"DEVELOPMENT_TEAM = {INHERITED_TEAM_ID}"),
                (".xcodebuildmcp/config.yaml", f'bundleId: "{INHERITED_BUNDLE_ID}"'),
                (
                    "Config/Shared.xcconfig",
                    f"APP_BUNDLE_IDENTIFIER = {INHERITED_BUNDLE_ID}$(APP_IDENTIFIER_SUFFIX)",
                ),
                (
                    "Config/Shared.xcconfig",
                    f"APP_GROUP_IDENTIFIER = group.{INHERITED_BUNDLE_ID}$(APP_IDENTIFIER_SUFFIX)",
                ),
                (
                    "HermesMobile/HermesMobileApp.swift",
                    f"// `xcrun simctl launch <udid> {INHERITED_BUNDLE_ID} --streaming-lab`",
                ),
                (
                    "HermesMobile/Auth/KeychainStore.swift",
                    f'?? "{INHERITED_BUNDLE_ID}"',
                ),
                (
                    "HermesMobile/Features/Share/SharedDraftStore.swift",
                    f'?? "group.{INHERITED_BUNDLE_ID}"',
                ),
            ]
        )
        self.assertEqual(
            [],
            unapproved_inherited_identity_occurrences(ROOT, expected_inherited_identity),
        )
        trusted_base_value = os.environ.get("HERMEX_CONTRACT_BASE_ROOT")
        trusted_base: Path | None = None
        if trusted_base_value:
            trusted_base = Path(trusted_base_value).resolve(strict=True)
            self.assertEqual(
                [],
                unapproved_inherited_identity_occurrences(
                    ROOT, inherited_identity_occurrences(trusted_base)
                ),
                "candidate reintroduces an inherited identity occurrence removed from the base",
            )
        expected_runtime_identity = sorted(
            [
                (
                    "HermesMobile.xcodeproj/project.pbxproj",
                    f'HERMES_URL_SCHEME = "{INHERITED_URL_SCHEME}$(APP_URL_SCHEME_SUFFIX)";',
                ),
                (
                    "HermesMobile.xcodeproj/project.pbxproj",
                    f'HERMES_URL_SCHEME = "{INHERITED_URL_SCHEME}$(APP_URL_SCHEME_SUFFIX)";',
                ),
                (
                    "HermesMobile.xcodeproj/project.pbxproj",
                    f'PRODUCT_BUNDLE_IDENTIFIER = "$(APP_BUNDLE_IDENTIFIER).{INHERITED_SHARE_SUFFIX}";',
                ),
                (
                    "HermesMobile.xcodeproj/project.pbxproj",
                    f'PRODUCT_BUNDLE_IDENTIFIER = "$(APP_BUNDLE_IDENTIFIER).{INHERITED_SHARE_SUFFIX}";',
                ),
                (
                    "HermesMobile.xcodeproj/project.pbxproj",
                    f'PRODUCT_BUNDLE_IDENTIFIER = "$(APP_BUNDLE_IDENTIFIER).{INHERITED_WIDGET_SUFFIX}";',
                ),
                (
                    "HermesMobile.xcodeproj/project.pbxproj",
                    f'PRODUCT_BUNDLE_IDENTIFIER = "$(APP_BUNDLE_IDENTIFIER).{INHERITED_WIDGET_SUFFIX}";',
                ),
                (
                    "HermesMobile/AppIntents/HermexAppIntents.swift",
                    f"/// deep-link router. An intent writes a `{INHERITED_URL_SCHEME}://…` URL here; `ContentView` observes",
                ),
                (
                    "HermesMobile/Features/Share/SharedDraftStore.swift",
                    f'?? "{INHERITED_URL_SCHEME}"',
                ),
                (
                    "HermesMobile/LiveActivities/HermesDeepLink.swift",
                    f'?? "{INHERITED_URL_SCHEME}"',
                ),
                (
                    "HermesMobile/LiveActivities/HermesDeepLink.swift",
                    f"/// `{INHERITED_URL_SCHEME}://new-chat` (scheme follows the active build, e.g. `-branch`).",
                ),
                (
                    "HermesMobile/LiveActivities/HermesDeepLink.swift",
                    f"/// `{INHERITED_URL_SCHEME}://new-chat-voice` (scheme follows the active build, e.g. `-branch`).",
                ),
                (
                    "HermesMobile/LiveActivities/HermesDeepLink.swift",
                    f"/// `{INHERITED_URL_SCHEME}://new-chat-profile?profile=<name>` (scheme follows the active build).",
                ),
                (
                    "HermesMobileTests/TranscriptLinkPreviewTests.swift",
                    f'in: "Open file:///tmp/report.txt, ssh://server.test, and {INHERITED_URL_SCHEME}://session/1."',
                ),
            ]
        )
        self.assertEqual(
            [],
            unapproved_runtime_identity_occurrences(ROOT, expected_runtime_identity),
        )
        if trusted_base is not None:
            self.assertEqual(
                [],
                unapproved_runtime_identity_occurrences(
                    ROOT, inherited_runtime_identity_occurrences(trusted_base)
                ),
                "candidate reintroduces deferred runtime identity removed from the base",
            )
        identity_epoch_version = None
        if trusted_base is not None and (
            inherited_identity_occurrences(trusted_base)
            or inherited_runtime_identity_occurrences(trusted_base)
        ):
            identity_epoch_version = "0.1.0"
        self.assertEqual(
            [],
            identity_migration_findings(
                ROOT,
                expected_inherited_identity,
                expected_runtime_identity,
                identity_epoch_version,
            ),
            "issue #15 must preserve the exact quarantine or complete the canonical migration",
        )
        with tempfile.TemporaryDirectory(prefix="hermex-legacy-identity-") as temp:
            poisoned_root = Path(temp)
            (poisoned_root / "copied-identity.bin").write_bytes(
                b"prefix\x00" + INHERITED_TEAM_ID.encode() + b"\n"
            )
            tracked_cache = poisoned_root / "payload" / "__pycache__" / "copied.bin"
            tracked_cache.parent.mkdir(parents=True)
            tracked_cache.write_bytes(INHERITED_BUNDLE_ID.encode() + b"\n")
            (poisoned_root / "copied-identity-link").symlink_to(INHERITED_BUNDLE_ID)
            (poisoned_root / f"{INHERITED_BUNDLE_ID}.txt").write_text("safe payload")
            self.assertEqual(
                sorted(
                    [
                        ("copied-identity.bin", f"prefix\x00{INHERITED_TEAM_ID}"),
                        ("copied-identity-link", INHERITED_BUNDLE_ID),
                        (f"{INHERITED_BUNDLE_ID}.txt", "<path>"),
                        ("payload/__pycache__/copied.bin", INHERITED_BUNDLE_ID),
                    ]
                ),
                inherited_identity_occurrences(poisoned_root),
            )
            (poisoned_root / "copied-scheme.bin").write_bytes(
                b"prefix\x00" + INHERITED_URL_SCHEME.encode() + b"://session/2"
            )
            tracked_runtime_cache = (
                poisoned_root / "runtime" / "__pycache__" / "scheme.bin"
            )
            tracked_runtime_cache.parent.mkdir(parents=True)
            tracked_runtime_cache.write_bytes(
                INHERITED_URL_SCHEME.encode() + b"://cached"
            )
            (poisoned_root / "copied-owner-route").symlink_to(
                f"https://www.{INHERITED_OWNER_DOMAIN}/hermes-mobile"
            )
            self.assertEqual(
                sorted(
                    [
                        (
                            "copied-owner-route",
                            f"https://www.{INHERITED_OWNER_DOMAIN}/hermes-mobile",
                        ),
                        (
                            "copied-scheme.bin",
                            f"prefix\x00{INHERITED_URL_SCHEME}://session/2",
                        ),
                        (
                            "runtime/__pycache__/scheme.bin",
                            f"{INHERITED_URL_SCHEME}://cached",
                        ),
                    ]
                ),
                inherited_runtime_identity_occurrences(poisoned_root),
            )
        with tempfile.TemporaryDirectory(prefix="hermex-duplicate-identity-") as temp:
            duplicate_root = Path(temp)
            duplicate_config = duplicate_root / "Config" / "Shared.xcconfig"
            duplicate_config.parent.mkdir(parents=True)
            duplicate_line = f"DEVELOPMENT_TEAM = {INHERITED_TEAM_ID}"
            duplicate_config.write_text(f"{duplicate_line}\n{duplicate_line}\n")
            self.assertEqual(
                [("Config/Shared.xcconfig", duplicate_line)],
                unapproved_inherited_identity_occurrences(
                    duplicate_root, expected_inherited_identity
                ),
            )

        with tempfile.TemporaryDirectory(prefix="hermex-partial-identity-") as temp:
            partial_root = Path(temp)
            partial_config = partial_root / "Config" / "Shared.xcconfig"
            partial_config.parent.mkdir(parents=True)
            partial_config.write_text(f"DEVELOPMENT_TEAM = {INHERITED_TEAM_ID}\n")
            self.assertEqual(
                ["issue #15 identity migration is partial; preserve the quarantine or remove it atomically"],
                identity_migration_findings(
                    partial_root,
                    expected_inherited_identity,
                    expected_runtime_identity,
                ),
            )

        with tempfile.TemporaryDirectory(prefix="hermex-complete-identity-") as temp:
            complete_root = Path(temp)
            canonical_files = {
                "Config/Shared.xcconfig": "\n".join(
                    (
                        "DEVELOPMENT_TEAM =",
                        "APP_IDENTIFIER_SUFFIX =",
                        "APP_BUNDLE_IDENTIFIER = no.gior.hermex$(APP_IDENTIFIER_SUFFIX)",
                        "APP_GROUP_IDENTIFIER = group.no.gior.hermex$(APP_IDENTIFIER_SUFFIX)",
                    )
                ),
                ".xcodebuildmcp/config.yaml": 'bundleId: "no.gior.hermex"',
                "HermesMobile.xcodeproj/project.pbxproj": "\n".join(
                    (
                        *('APP_URL_SCHEME_SUFFIX = "";',) * 2,
                        *('HERMES_URL_SCHEME = "hermex$(APP_URL_SCHEME_SUFFIX)";',) * 2,
                        *('PRODUCT_BUNDLE_IDENTIFIER = "$(APP_BUNDLE_IDENTIFIER)";',) * 2,
                        *('PRODUCT_BUNDLE_IDENTIFIER = "$(APP_BUNDLE_IDENTIFIER).tests";',) * 2,
                        *('PRODUCT_BUNDLE_IDENTIFIER = "$(APP_BUNDLE_IDENTIFIER).share";',) * 2,
                        *('PRODUCT_BUNDLE_IDENTIFIER = "$(APP_BUNDLE_IDENTIFIER).liveactivity";',) * 2,
                        *("MARKETING_VERSION = 0.1.0;",) * 8,
                    )
                ),
                "HermesMobile/Resources/HermesMobile.entitlements": (
                    "<string>$(APP_GROUP_IDENTIFIER)</string>"
                ),
                "HermesShareExtension/Resources/HermesShareExtension.entitlements": (
                    "<string>$(APP_GROUP_IDENTIFIER)</string>"
                ),
                "HermesMobile/Auth/KeychainStore.swift": '?? "no.gior.hermex"',
                "HermesMobile/Features/Share/SharedDraftStore.swift": "\n".join(
                    ('?? "group.no.gior.hermex"', '?? "hermex"')
                ),
                "HermesMobile/LiveActivities/HermesDeepLink.swift": '?? "hermex"',
                "HermesMobileTests/TranscriptLinkPreviewTests.swift": (
                    'in: "Open file:///tmp/report.txt, ssh://server.test, and hermex://session/1."'
                ),
            }
            for relative, content in canonical_files.items():
                path = complete_root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content + "\n")
            self.assertEqual(
                [],
                identity_migration_findings(
                    complete_root,
                    expected_inherited_identity,
                    expected_runtime_identity,
                ),
            )
            self.assertEqual(
                [],
                identity_migration_findings(
                    complete_root,
                    expected_inherited_identity,
                    expected_runtime_identity,
                    "0.1.0",
                ),
            )
            shared_path = complete_root / "Config/Shared.xcconfig"
            shared_path.write_text(
                shared_path.read_text().replace(
                    "APP_IDENTIFIER_SUFFIX =\n",
                    "APP_IDENTIFIER_SUFFIX = .preview\n",
                )
            )
            suffix_findings = identity_migration_findings(
                complete_root,
                expected_inherited_identity,
                expected_runtime_identity,
            )
            self.assertTrue(any("APP_IDENTIFIER_SUFFIX must be empty" in item for item in suffix_findings))
            shared_path.write_text(
                shared_path.read_text().replace(
                    "APP_IDENTIFIER_SUFFIX = .preview\n",
                    "APP_IDENTIFIER_SUFFIX =\n",
                )
            )
            project_path = complete_root / "HermesMobile.xcodeproj/project.pbxproj"
            project_path.write_text(
                project_path.read_text().replace(
                    'PRODUCT_BUNDLE_IDENTIFIER = "$(APP_BUNDLE_IDENTIFIER).tests";\n',
                    "",
                    1,
                )
            )
            tests_identity_findings = identity_migration_findings(
                complete_root,
                expected_inherited_identity,
                expected_runtime_identity,
            )
            self.assertTrue(any(".tests" in item for item in tests_identity_findings))
            project_path.write_text(
                'PRODUCT_BUNDLE_IDENTIFIER = "$(APP_BUNDLE_IDENTIFIER).tests";\n'
                + project_path.read_text()
            )
            project_path.write_text(
                project_path.read_text().replace(
                    "MARKETING_VERSION = 0.1.0;",
                    "MARKETING_VERSION = 0.2.0;",
                )
            )
            self.assertEqual(
                [],
                identity_migration_findings(
                    complete_root,
                    expected_inherited_identity,
                    expected_runtime_identity,
                ),
            )
            epoch_findings = identity_migration_findings(
                complete_root,
                expected_inherited_identity,
                expected_runtime_identity,
                "0.1.0",
            )
            self.assertTrue(
                any(
                    "identity epoch requires eight 0.1.0 target versions" in finding
                    for finding in epoch_findings
                )
            )

        tracker = read(ROOT / "docs" / "agents" / "issue-tracker.md")
        self.assertIn("GitHub repo: `ebreen/hermex`", tracker)
        self.assertIn("Remote: `https://github.com/ebreen/hermex.git`", tracker)
        project_spec = normalize_prose(read(ROOT / "PROJECT_SPEC.md"))
        for guidance in (tracker, project_spec):
            self.assertIn("https://github.com/uzairansaruzi/hermex", guidance)
            self.assertIn("weekly and before starting a large slice", guidance)
        self.assertIn("inherited historical rationale and evidence", project_spec.lower())
        self.assertIn("not current fork authority", project_spec.lower())

    def test_active_workflows_have_no_apple_credentialed_distribution_path(self) -> None:
        workflow_dir = ROOT / ".github" / "workflows"
        self.assertFalse((workflow_dir / "internal-testflight.yml").exists())
        self.assertFalse((workflow_dir / "external-testflight.yml").exists())
        prohibited = (
            r"secrets\.APP_STORE_CONNECT",
            r"APP_STORE_CONNECT_PRIVATE_KEY",
            r"-allowProvisioningUpdates",
            r"xcodebuild\s+-exportArchive",
            r"testFlightInternalTestingOnly",
            r"DEVELOPMENT_TEAM\s*[:=]\s*['\"]?[A-Z0-9]{10}\b",
            r"PROVISIONING_PROFILE_SPECIFIER",
            r"CODE_SIGN_IDENTITY[^\n]*(?:Apple Distribution|iPhone Distribution)",
        )
        findings: list[str] = []
        for path in sorted(workflow_dir.glob("*.y*ml")):
            text = read(path)
            for pattern in prohibited:
                if re.search(pattern, text, flags=re.IGNORECASE):
                    findings.append(f"{path.name}: /{pattern}/")
        self.assertEqual([], findings, "active signed distribution workflow remains: " + str(findings))
        upstream_watch = read(workflow_dir / "upstream-watch.yml")
        self.assertIn("          retention-days: 30", upstream_watch)

        retired_findings: list[str] = []
        retired_name = re.compile(r"testflight|app[-_ ]?store[-_ ]?connect", re.IGNORECASE)
        retired_content = re.compile(
            r"app-store-connect|Spaceship::ConnectAPI|APP_STORE_CONNECT_(?:KEY|ISSUER|PRIVATE)|TestFlight",
            re.IGNORECASE,
        )
        for root in (ROOT / "Config", ROOT / "ci"):
            for path in sorted(candidate for candidate in root.rglob("*") if candidate.is_file()):
                relative = path.relative_to(ROOT)
                if retired_name.search(path.name):
                    retired_findings.append(f"retired path: {relative}")
                    continue
                try:
                    text = read(path)
                except UnicodeDecodeError:
                    continue
                if retired_content.search(text):
                    retired_findings.append(f"retired capability: {relative}")
        self.assertEqual(
            [],
            retired_findings,
            "retired credentialed distribution machinery remains: " + str(retired_findings),
        )

    def test_every_canonical_root_doc_points_to_the_contract(self) -> None:
        missing_links = [path.name for path in CANONICAL_DOCS if "docs/improvements-contract.md" not in read(path)]
        self.assertEqual([], missing_links, f"canonical docs missing Improvements contract link: {missing_links}")

    def test_trusted_contract_workflow_executes_only_the_base_validator(self) -> None:
        for relative, directory in (
            ("tests/test_fork_contract.py", False),
            (".github/CODEOWNERS", False),
            (".github/workflows", True),
            (".github/workflows/contract-ci.yml", False),
            (".github/workflows/pr-ci.yml", False),
            (".github/workflows/upstream-watch.yml", False),
        ):
            self.assertEqual(
                [],
                regular_path_findings(ROOT, relative, directory=directory),
            )
        with tempfile.TemporaryDirectory(prefix="hermex-protected-parent-symlink-") as temp:
            poison_root = Path(temp)
            trusted_tests = poison_root / "trusted-tests"
            trusted_tests.mkdir()
            (trusted_tests / "test_fork_contract.py").write_text("trusted\n")
            (poison_root / "tests").symlink_to("trusted-tests", target_is_directory=True)
            self.assertEqual(
                ["protected path or ancestor is a symlink: tests"],
                regular_path_findings(poison_root, "tests/test_fork_contract.py"),
            )
            github = poison_root / ".github"
            github.mkdir()
            (poison_root / "owner").write_text("* @ebreen\n")
            (github / "CODEOWNERS").symlink_to("../owner")
            self.assertEqual(
                ["protected path or ancestor is a symlink: .github/CODEOWNERS"],
                regular_path_findings(poison_root, ".github/CODEOWNERS"),
            )
        path = ROOT / ".github" / "workflows" / "contract-ci.yml"
        self.assertTrue(path.is_file(), "trusted contract workflow is missing")
        workflow = read(path)
        active_workflows = active_workflow_texts(ROOT)
        self.assertEqual([], protected_workflow_findings(active_workflows))
        mutable_actions = [
            f"{name}: {reference}"
            for name, text in active_workflows.items()
            for reference in re.findall(r"(?m)^\s*uses:\s*([^\s#]+)", text)
            if not re.fullmatch(r"[^@\s]+@[0-9a-f]{40}", reference)
        ]
        self.assertEqual([], mutable_actions, f"protected workflows use mutable actions: {mutable_actions}")
        spoofed_workflows = dict(active_workflows)
        spoofed_workflows["spoof.yml"] = (
            "name: Spoof\non:\n  pull_request:\njobs:\n  spoof:\n"
            "    name: Trusted Contract Gate\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n"
        )
        self.assertIn(
            "unexpected workflow can spoof a protected check: spoof.yml",
            protected_workflow_findings(spoofed_workflows),
        )
        with tempfile.TemporaryDirectory(prefix="hermex-workflow-symlink-") as temp:
            temp_root = Path(temp)
            workflow_dir = temp_root / ".github" / "workflows"
            workflow_dir.mkdir(parents=True)
            payload = temp_root / ".github" / "reviewed-pr-ci.yml"
            payload.write_text(active_workflows["pr-ci.yml"], encoding="utf-8")
            (workflow_dir / "pr-ci.yml").symlink_to("../reviewed-pr-ci.yml")
            with self.assertRaisesRegex(
                AssertionError,
                "protected workflow must be a regular non-symlink file: pr-ci.yml",
            ):
                active_workflow_texts(temp_root)
            reviewed_workflows = temp_root / ".github" / "reviewed-workflows"
            workflow_dir.rename(reviewed_workflows)
            workflow_dir.symlink_to("reviewed-workflows", target_is_directory=True)
            with self.assertRaisesRegex(
                AssertionError,
                "protected workflow directory must be a regular non-symlink directory: .github/workflows",
            ):
                active_workflow_texts(temp_root)
        self.assert_contains_all(
            workflow,
            (
                "pull_request_target:",
                "contents: read",
                "pull-requests: read",
                "ref: ${{ github.event.pull_request.base.sha }}",
                "ref: refs/pull/${{ github.event.pull_request.number }}/merge",
                "persist-credentials: false",
                "allow-unsafe-pr-checkout: true",
                "path: validator",
                "path: candidate",
                'HERMEX_CONTRACT_ROOT="${GITHUB_WORKSPACE}/candidate"',
                "PYTHONDONTWRITEBYTECODE=1",
                'python3 "${GITHUB_WORKSPACE}/validator/tests/test_fork_contract.py" -v',
                'cmp -s "${GITHUB_WORKSPACE}/validator/tests/test_fork_contract.py"',
                'ls-tree -d HEAD -- tests',
                'ls-tree HEAD -- tests/test_fork_contract.py',
                '[[ "${validator_mode}" == "100644" ]]',
                'cat-file blob "${validator_oid}"',
                "expected_count=25",
                'pin_file="${GITHUB_WORKSPACE}/candidate/WEBUI_FORK_TESTED_SHA"',
                "https://github.com/ebreen/hermes-webui.git",
                'git -C "${verify_dir}" fetch --quiet --depth=1 --no-tags',
                "WEBUI_FORK_TESTED_SHA does not resolve to a public fork commit",
                '[[ "$(git -C "${verify_dir}" rev-parse FETCH_HEAD)" == "${webui_pin}" ]]',
                '[[ "$(git -C "${verify_dir}" cat-file -t FETCH_HEAD)" == "commit" ]]',
            ),
            "trusted contract workflow",
        )
        self.assertEqual(1, workflow.count("allow-unsafe-pr-checkout: true"))
        self.assertNotIn('python3 "${GITHUB_WORKSPACE}/candidate', workflow)
        self.assertNotIn("cd candidate", workflow)
        self.assertNotIn("github.event.pull_request.head.repo", workflow)
        self.assertNotIn("GH_TOKEN", workflow)
        self.assertEqual(CONTRACT_CI_EXECUTABLE_SHA256, executable_workflow_sha256(workflow))

        credentialed_candidate_checkout = workflow.replace(
            "          persist-credentials: false\n",
            "          persist-credentials: true\n",
            1,
        )
        self.assertNotEqual(workflow, credentialed_candidate_checkout)
        self.assertNotEqual(
            CONTRACT_CI_EXECUTABLE_SHA256,
            executable_workflow_sha256(credentialed_candidate_checkout),
        )
        continuation_breaker = workflow.replace(
            '            HERMEX_CONTRACT_ROOT="${GITHUB_WORKSPACE}/candidate" \\\n',
            '            HERMEX_CONTRACT_ROOT="${GITHUB_WORKSPACE}/candidate" \\\n'
            "            # breaks the shell continuation\n",
            1,
        )
        self.assertNotEqual(workflow, continuation_breaker)
        self.assertNotEqual(
            CONTRACT_CI_EXECUTABLE_SHA256,
            executable_workflow_sha256(continuation_breaker),
        )

        procedure = normalize_prose(read(ROOT / "CONTRACT_TESTS.md"))
        self.assert_contains_all(
            procedure,
            (
                "Trusted Improvements Validator",
                "Issue #14 is the one-time bootstrap",
                "dedicated trust-root pull request",
                "independent exact-SHA review",
                "explicit administrator bypass",
                "canary pull request",
                "Trusted Contract Gate",
                "unauthenticated fixed-host fetch",
                "passes no token",
                "executes no fork script",
            ),
            "trust-root update procedure",
        )

    def test_pr_ci_runs_the_contract_suite_on_cheap_ubuntu(self) -> None:
        workflow = read(ROOT / ".github" / "workflows" / "pr-ci.yml")
        changes_job = active_workflow_job(workflow, "changes")
        contract_job = active_workflow_job(workflow, "contract")
        gate_job = active_workflow_job(workflow, "gate")
        self.assertNotIn("--jq '.[].filename'", changes_job)
        self.assert_contains_all(
            changes_job,
            (
                "--paginate --slurp",
                'metadata.get("changed_files")',
                'record.get("status")',
                'record.get("previous_filename")',
                'if status in ("renamed", "copied"):',
                'f"{status} record {index} has no valid previous_filename"',
                "if len(records) != expected:",
                "docs_only.fullmatch(path)",
            ),
            "changed-file classifier",
        )

        self.assertRegex(contract_job, r"(?m)^    name: Improvements contract$")
        self.assertRegex(contract_job, r"(?m)^    runs-on: ubuntu-latest$")
        self.assertIn("    outputs:\n      validated: ${{ steps.validate.outputs.validated }}", contract_job)
        self.assertIn("    env:\n      PYTHONDONTWRITEBYTECODE: '1'", contract_job)
        self.assertIn("        id: validate", contract_job)
        self.assertIn("          expected_count=25", contract_job)
        self.assertIn("Contract test manifest mismatch", contract_job)
        self.assertIn(
            'python3 -m unittest tests/test_fork_contract.py -v 2>&1 | tee "${log_file}"',
            contract_job,
        )
        self.assertIn("printf 'validated=true\\n' >> \"$GITHUB_OUTPUT\"", contract_job)
        self.assertNotIn("continue-on-error: true", contract_job)
        self.assertEqual([], contract_job_bypass_findings(contract_job))

        self.assertRegex(gate_job, r"(?m)^    needs: \[changes, contract, test\]$")
        self.assertRegex(gate_job, r"(?m)^    if: always\(\)$")
        self.assertIn('echo "contract: ${{ needs.contract.result }}"', gate_job)
        self.assertIn('echo "contract validated: ${{ needs.contract.outputs.validated }}"', gate_job)
        self.assertIn('if [[ "${{ needs.contract.result }}" != "success" ]]', gate_job)
        self.assertIn('if [[ "${{ needs.contract.outputs.validated }}" != "true" ]]', gate_job)
        self.assertIn(
            'if [[ "${{ needs.changes.outputs.run_ios }}" == "true" ]]; then',
            gate_job,
        )
        self.assertIn('if [[ "${{ needs.test.result }}" != "success" ]]; then', gate_job)
        self.assertIn(
            'elif [[ "${{ needs.changes.outputs.run_ios }}" == "false" ]]; then',
            gate_job,
        )
        self.assertIn('if [[ "${{ needs.test.result }}" != "skipped" ]]; then', gate_job)
        self.assertNotIn("continue-on-error: true", gate_job)
        self.assertIn("          retention-days: 14", workflow)
        self.assertEqual(PR_CI_EXECUTABLE_SHA256, executable_workflow_sha256(workflow))
        self.assertEqual([], required_workflow_gate_findings(workflow))

    def test_each_semantic_reversal_rule_is_live_in_isolation(self) -> None:
        for pattern, poison in SEMANTIC_REVERSAL_CASES:
            with self.subTest(pattern=pattern):
                self.assertEqual([pattern], semantic_reversal_findings(poison))

        canonical_corpus = "\n".join(read(path) for path in MAINTAINED_GUIDANCE)
        self.assertEqual([], semantic_reversal_findings(canonical_corpus))

    def test_workflow_guard_rejects_comment_only_changes(self) -> None:
        decoy = """jobs:
  contract:
    # name: Improvements contract
    # runs-on: ubuntu-latest
    # run: python3 -m unittest tests/test_fork_contract.py -v
  gate:
    # needs: [changes, contract, test]
"""
        contract_job = active_workflow_job(decoy, "contract")
        gate_job = active_workflow_job(decoy, "gate")
        self.assertNotIn("runs-on: ubuntu-latest", contract_job)
        self.assertNotIn("python3 -m unittest", contract_job)
        self.assertNotIn("needs: [changes, contract, test]", gate_job)

        workflow = read(ROOT / ".github" / "workflows" / "pr-ci.yml")
        commented_decoys = workflow + """
#  contract:
#    name: Improvements contract
#  gate:
#    name: CI Gate
"""
        self.assertTrue(required_workflow_gate_findings(commented_decoys))

    def test_workflow_guard_rejects_inert_required_paths(self) -> None:
        workflow = read(ROOT / ".github" / "workflows" / "pr-ci.yml")
        contract_job = active_workflow_job(workflow, "contract")
        poisoned_jobs = (
            contract_job.replace(
                "    runs-on: ubuntu-latest\n",
                "    if: ${{ false }}\n    runs-on: ubuntu-latest\n",
                1,
            ),
            contract_job.replace(
                "      - name: Validate canonical contract\n",
                "      - name: Validate canonical contract\n        if: ${{ false }}\n",
                1,
            ),
            contract_job.replace(
                "      - name: Validate canonical contract\n",
                "      - name: Validate canonical contract\n        continue-on-error: ${{ true }}\n",
                1,
            ),
            contract_job.replace(
                "    timeout-minutes: 5\n",
                "    strategy:\n      matrix:\n        include: []\n    timeout-minutes: 5\n",
                1,
            ),
            contract_job.replace(
                "      - name: Validate canonical contract\n",
                "      - name: Validate canonical contract\n        shell: \"true {0}\"\n",
                1,
            ),
            contract_job.replace(
                "python3 -m unittest tests/test_fork_contract.py -v",
                "python3 -m unittest tests/test_fork_contract.py -v || true",
                1,
            ),
            contract_job.replace(
                "          printf 'validated=true\\n' >> \"$GITHUB_OUTPUT\"\n",
                "          printf 'validated=true\\n' >> \"$GITHUB_OUTPUT\"\n"
                "        env:\n          PATH: .github/fake-bin:$PATH\n",
                1,
            ),
            contract_job.replace(
                "          printf 'validated=true\\n' >> \"$GITHUB_OUTPUT\"\n",
                "          printf 'validated=true\\n' >> \"$GITHUB_OUTPUT\"\n"
                "        run: |\n"
                "          printf 'validated=true\\n' >> \"$GITHUB_OUTPUT\"\n",
                1,
            ),
            contract_job.replace(
                "    runs-on: ubuntu-latest\n",
                "    runs-on: ubuntu-latest\n    \"env\" :\n      PATH: .github/fake-bin:$PATH\n",
                1,
            ),
            contract_job.replace(
                "    runs-on: ubuntu-latest\n",
                "    runs-on: ubuntu-latest\n    container: attacker/image:latest\n",
                1,
            ),
            contract_job.replace(
                "        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n\n"
                "      - name: Validate canonical contract\n",
                "        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n\n"
                "      - name: Spoof runtime\n        run: echo fake >> \"$GITHUB_PATH\"\n"
                "      - name: Validate canonical contract\n",
                1,
            ),
            contract_job.replace(
                "    steps:\n",
                "    outputs:\n      spoof: true\n    steps:\n",
                1,
            ),
        )
        for poisoned in poisoned_jobs:
            with self.subTest(job=poisoned):
                self.assertTrue(contract_job_bypass_findings(poisoned))

        duplicated = workflow.replace("\n  test:\n", f"\n{contract_job}\n  test:\n", 1)
        gate_if_false = workflow.replace(
            "      - name: Check results\n",
            "      - name: Check results\n        if: ${{ false }}\n",
            1,
        )
        gate_early_exit = workflow.replace(
            "      - name: Check results\n        run: |\n          set -euo pipefail\n",
            "      - name: Check results\n        run: |\n          set -euo pipefail\n          exit 0\n",
            1,
        )
        gate_extra_step = workflow.replace(
            "    steps:\n      - name: Check results\n",
            "    steps:\n      - name: Spoof result\n        run: true\n      - name: Check results\n",
            1,
        )
        gate_env_override = workflow.replace(
            "  gate:\n    name: CI Gate\n",
            "  gate:\n    name: CI Gate\n    env:\n      BASH_ENV: .github/fake-bash-env\n",
            1,
        )
        gate_step_env_override = workflow.replace(
            "          echo \"Gate passed.\"\n",
            "          echo \"Gate passed.\"\n"
            "        env:\n          BASH_ENV: .github/fake-bash-env\n",
            1,
        )
        gate_duplicate_run = workflow.replace(
            "          echo \"Gate passed.\"\n",
            "          echo \"Gate passed.\"\n"
            "        run: echo \"Gate bypassed\"\n",
            1,
        )
        gate_unreachable_checks = workflow.replace(
            "          set -euo pipefail\n          echo \"changes:",
            "          set -euo pipefail\n"
            "          if false; then\n"
            "          echo \"changes:",
            1,
        ).replace(
            "          echo \"Gate passed.\"\n",
            "          echo \"Gate passed.\"\n          fi\n",
            1,
        )
        manual_only_trigger = workflow.replace(
            "  pull_request:\n",
            "  workflow_dispatch:\n",
            1,
        )
        incomplete_response_is_accepted = workflow.replace(
            "          if len(records) != expected:\n"
            "              fail(f\"expected {expected} file records, received {len(records)}\")\n",
            "",
            1,
        )
        self.assertNotEqual(workflow, manual_only_trigger)
        self.assertNotEqual(workflow, incomplete_response_is_accepted)
        for poisoned in (
            duplicated,
            gate_if_false,
            gate_early_exit,
            gate_extra_step,
            gate_env_override,
            gate_step_env_override,
            gate_duplicate_run,
            gate_unreachable_checks,
            manual_only_trigger,
            incomplete_response_is_accepted,
        ):
            with self.subTest(workflow=poisoned):
                self.assertTrue(required_workflow_gate_findings(poisoned))


if __name__ == "__main__":
    unittest.main()
