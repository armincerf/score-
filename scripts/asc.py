#!/usr/bin/env python3
"""App Store Connect client for score's TestFlight pipeline (stdlib + `cryptography`).

    python3 scripts/asc.py status [--brief]      app record, latest builds, beta groups
    python3 scripts/asc.py ensure-testers        external group "Score testers" + its testers
    python3 scripts/asc.py testers               members of "Score testers" and their state
    python3 scripts/asc.py preflight             read-only: can `distribute` run? (before uploading)
    python3 scripts/asc.py wait-build BUILD [--timeout MINUTES]
    python3 scripts/asc.py distribute BUILD [--notes TEXT]

BUILD is the build number (CFBundleVersion), e.g. 20261011.120000.

Env (none of these is a secret except the .p8 file, which stays outside the repo):
    ASC_KEY_ID      (default 8QS8WXLS34)
    ASC_ISSUER_ID   (default 69a6de79-5ccb-47e3-e053-5b8c7c11a4d1)
    ASC_KEY_PATH    (default ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8)
    ASC_BUNDLE_ID   (default armincerf.score)
    ASC_REVIEW_FIRST_NAME, ASC_REVIEW_LAST_NAME, ASC_REVIEW_EMAIL, ASC_REVIEW_PHONE
                    beta review contact used by `distribute` (defaults Alex, Davis,
                    alexanderdavis95@gmail.com; the phone has no default)
    ASC_FEEDBACK_EMAIL  TestFlight feedback address (default: the review email)

Exit status: 0 ok, 1 error, 2 usage, 3 no App Store Connect app record for the bundle id.
The JWT is never printed.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, NoReturn

try:
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
except ImportError:  # pragma: no cover - environment check
    sys.exit(
        f"asc.py needs the 'cryptography' package, which {sys.executable} lacks.\n"
        "Run it with a python3 that has it (Homebrew's does), or: python3 -m pip install cryptography"
    )

BASE = "https://api.appstoreconnect.apple.com"
KEY_ID = os.environ.get("ASC_KEY_ID") or "8QS8WXLS34"
ISSUER_ID = os.environ.get("ASC_ISSUER_ID") or "69a6de79-5ccb-47e3-e053-5b8c7c11a4d1"
KEY_PATH = os.path.expanduser(
    os.environ.get("ASC_KEY_PATH") or f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8"
)
BUNDLE_ID = os.environ.get("ASC_BUNDLE_ID") or "armincerf.score"
LOCALE = "en-US"

GROUP_NAME = "Score testers"
# (email, first name, last name); names are optional for the API.
TESTERS = [
    ("alexanderdavis95@gmail.com", "Alex", "Davis"),
    ("lucio.dalessa@gmail.com", "Lucio", ""),
]

DEFAULT_REVIEW_FIRST_NAME = "Alex"
DEFAULT_REVIEW_LAST_NAME = "Davis"
DEFAULT_REVIEW_EMAIL = "alexanderdavis95@gmail.com"

BETA_DESCRIPTION = (
    "Score keeps table-tennis matches. The iPhone records the match on camera and calls the "
    "score; the paired Apple Watch is the remote for scoring points, marking highlights and "
    "ending games. After a match you get the full video, a highlight reel and an on-device "
    "match summary."
)
REVIEW_NOTES = (
    "No account or sign-in is needed. Start a match on the iPhone (it asks for camera and "
    "microphone access to record the match), then score points with the on-screen buttons or "
    "from the Apple Watch app. The watch app is optional."
)
DEFAULT_WHATS_NEW = (
    "Please record a match with the phone on a stand and score it from the watch (or the "
    "phone). Send feedback and screenshots from the TestFlight app."
)

EXIT_NO_APP = 3
NO_PHONE = (
    "beta review needs a contact phone number and App Store Connect has none: "
    "set ASC_REVIEW_PHONE (e.g. ASC_REVIEW_PHONE='+44 7700 900000') and re-run"
)
POLL_SECONDS = 30
FAILED_PROCESSING_STATES = {"FAILED", "INVALID"}
# External states in which the build needs no (new) beta review submission.
REVIEWED_EXTERNAL_STATES = {
    "BETA_APPROVED",
    "IN_BETA_TESTING",
    "READY_FOR_BETA_TESTING",
    "WAITING_FOR_BETA_REVIEW",
    "IN_BETA_REVIEW",
}


# ----------------------------------------------------------------------------- errors ---


class AscError(Exception):
    def __init__(self, method: str, path: str, status: int, detail: str) -> None:
        super().__init__(f"{method} {path} -> HTTP {status}: {detail}")
        self.status = status


def fail(message: str, code: int = 1) -> NoReturn:
    print(f"error: {message}", file=sys.stderr)
    sys.exit(code)


# -------------------------------------------------------------------------------- jwt ---


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


class Client:
    """Minimal JSON:API client. Signs an ES256 JWT with the .p8 and reuses it for 15 min."""

    def __init__(self) -> None:
        if not os.path.isfile(KEY_PATH):
            fail(f"no App Store Connect API key at {KEY_PATH} (set ASC_KEY_PATH)")
        with open(KEY_PATH, "rb") as fh:
            key = serialization.load_pem_private_key(fh.read(), password=None)
        if not isinstance(key, ec.EllipticCurvePrivateKey):
            fail(f"{KEY_PATH} is not an EC (ES256) private key")
        self._key = key
        self._token = ""
        self._token_born = 0.0

    def _jwt(self) -> str:
        now = time.time()
        if self._token and now - self._token_born < 15 * 60:
            return self._token
        header = {"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}
        payload = {
            "iss": ISSUER_ID,
            "iat": int(now),
            "exp": int(now) + 20 * 60,  # Apple's maximum lifetime
            "aud": "appstoreconnect-v1",
        }
        signing_input = ".".join(
            _b64url(json.dumps(part, separators=(",", ":")).encode()) for part in (header, payload)
        )
        der = self._key.sign(signing_input.encode("ascii"), ec.ECDSA(hashes.SHA256()))
        r, s = decode_dss_signature(der)  # JWS wants raw r||s, not DER
        self._token = f"{signing_input}.{_b64url(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"
        self._token_born = now
        return self._token

    def request(
        self,
        method: str,
        path: str,
        params: dict[str, Any] | None = None,
        body: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        url = path if path.startswith("http") else BASE + path
        if params:
            url += "?" + urllib.parse.urlencode(params, safe="[],")
        data = json.dumps(body).encode() if body is not None else None
        shown = urllib.parse.urlsplit(url).path
        for attempt in range(4):
            req = urllib.request.Request(url, data=data, method=method)
            req.add_header("Authorization", f"Bearer {self._jwt()}")
            req.add_header("Accept", "application/json")
            if data is not None:
                req.add_header("Content-Type", "application/json")
            try:
                with urllib.request.urlopen(req, timeout=60) as resp:
                    raw = resp.read()
                    return json.loads(raw) if raw else {}
            except urllib.error.HTTPError as err:
                raw = err.read()
                retryable = err.code == 429 or err.code >= 500
                if retryable and attempt < 3:
                    time.sleep(2 ** (attempt + 1))
                    continue
                raise AscError(method, shown, err.code, _error_detail(raw)) from None
            except (urllib.error.URLError, TimeoutError) as err:
                if attempt < 3:
                    time.sleep(2 ** (attempt + 1))
                    continue
                raise AscError(method, shown, 0, f"network error: {err}") from None
        raise AssertionError("unreachable")

    def get(self, path: str, **params: Any) -> dict[str, Any]:
        return self.request("GET", path, params=params)

    def get_all(self, path: str, **params: Any) -> list[dict[str, Any]]:
        """GET a collection, following `links.next`."""
        page = self.request("GET", path, params=params)
        items = list(page.get("data") or [])
        while page.get("links", {}).get("next"):
            page = self.request("GET", page["links"]["next"])
            items.extend(page.get("data") or [])
        return items

    def post(self, path: str, body: dict[str, Any]) -> dict[str, Any]:
        return self.request("POST", path, body=body)

    def patch(self, path: str, body: dict[str, Any]) -> dict[str, Any]:
        return self.request("PATCH", path, body=body)


def _error_detail(raw: bytes) -> str:
    try:
        errors = json.loads(raw).get("errors") or []
    except ValueError:
        return raw.decode(errors="replace")[:300]
    parts = []
    for e in errors:
        text = " ".join(x for x in (e.get("code"), e.get("title"), e.get("detail")) if x)
        pointer = (e.get("source") or {}).get("pointer")
        parts.append(f"{text} ({pointer})" if pointer else text)
    return "; ".join(parts) or raw.decode(errors="replace")[:300]


# ---------------------------------------------------------------------------- lookups ---


def find_app(api: Client) -> dict[str, Any] | None:
    apps = api.get("/v1/apps", **{"filter[bundleId]": BUNDLE_ID, "limit": 10}).get("data") or []
    return next((a for a in apps if a["attributes"].get("bundleId") == BUNDLE_ID), None)


def require_app(api: Client) -> dict[str, Any]:
    app = find_app(api)
    if app is None:
        print(_missing_app_message(api), file=sys.stderr)
        sys.exit(EXIT_NO_APP)
    return app


def _missing_app_message(api: Client) -> str:
    registered = bundle_id_registered(api)
    lines = [f"No App Store Connect app record for bundle id {BUNDLE_ID}."]
    if not registered:
        lines.append(
            f"The bundle id {BUNDLE_ID} is not registered yet either: run "
            "`scripts/testflight.sh --no-upload` once (cloud signing registers it), or add it at "
            "developer.apple.com > Identifiers."
        )
    lines.append(
        "Create the app: appstoreconnect.apple.com > Apps > + > New App > platform iOS, "
        f"bundle id {BUNDLE_ID}, any unique SKU (e.g. score), then re-run."
    )
    return "\n".join(lines)


def bundle_id_registered(api: Client) -> bool:
    found = api.get("/v1/bundleIds", **{"filter[identifier]": BUNDLE_ID, "limit": 50})
    return any(b["attributes"].get("identifier") == BUNDLE_ID for b in found.get("data") or [])


def find_group(api: Client, app_id: str) -> dict[str, Any] | None:
    groups = api.get_all("/v1/betaGroups", **{"filter[app]": app_id, "limit": 200})
    return next((g for g in groups if g["attributes"].get("name") == GROUP_NAME), None)


def find_build(api: Client, app_id: str, build_number: str) -> dict[str, Any] | None:
    found = api.get(
        "/v1/builds",
        **{
            "filter[app]": app_id,
            "filter[version]": build_number,
            "include": "preReleaseVersion",
            "limit": 10,
        },
    )
    builds = found.get("data") or []
    if not builds:
        return None
    build = builds[0]
    build["_marketing"] = _included_versions(found).get(_rel_id(build, "preReleaseVersion"), "?")
    return build


def _rel_id(resource: dict[str, Any], name: str) -> str | None:
    data = (resource.get("relationships", {}).get(name) or {}).get("data")
    return data.get("id") if isinstance(data, dict) else None


def _included_versions(doc: dict[str, Any]) -> dict[str, str]:
    return {
        inc["id"]: inc["attributes"].get("version", "?")
        for inc in doc.get("included") or []
        if inc.get("type") == "preReleaseVersions"
    }


def group_testers(api: Client, group_id: str) -> list[dict[str, Any]]:
    return api.get_all(f"/v1/betaGroups/{group_id}/betaTesters", limit=200)


def _tester_line(tester: dict[str, Any]) -> str:
    a = tester["attributes"]
    name = " ".join(x for x in (a.get("firstName"), a.get("lastName")) if x) or "-"
    return (
        f"  {a.get('email', '?'):<32} {name:<16} state={a.get('state') or '?'} "
        f"invite={a.get('inviteType') or '?'}"
    )


# ---------------------------------------------------------------------------- commands ---


def cmd_status(api: Client, args: argparse.Namespace) -> int:
    app = find_app(api)
    if app is None:
        print(_missing_app_message(api))
        return EXIT_NO_APP
    a = app["attributes"]
    print(f"App: {a.get('name')} ({BUNDLE_ID}) id={app['id']} sku={a.get('sku')}")
    if args.brief:
        return 0

    found = api.get(
        "/v1/builds",
        **{
            "filter[app]": app["id"],
            "sort": "-uploadedDate",
            "limit": 5,
            "include": "preReleaseVersion,buildBetaDetail",
        },
    )
    versions = _included_versions(found)
    details = {
        inc["id"]: inc["attributes"]
        for inc in found.get("included") or []
        if inc.get("type") == "buildBetaDetails"
    }
    builds = found.get("data") or []
    print(f"Latest builds ({len(builds)}):" if builds else "Builds: none uploaded yet")
    for b in builds:
        ba = b["attributes"]
        beta = details.get(_rel_id(b, "buildBetaDetail") or "", {})
        print(
            f"  {versions.get(_rel_id(b, 'preReleaseVersion') or '', '?')} "
            f"({ba.get('version')})  {ba.get('processingState')}"
            f"{'  EXPIRED' if ba.get('expired') else ''}"
            f"  internal={beta.get('internalBuildState', '?')}"
            f"  external={beta.get('externalBuildState', '?')}"
            f"  uploaded {(ba.get('uploadedDate') or '?')[:16].replace('T', ' ')}"
        )

    groups = api.get_all("/v1/betaGroups", **{"filter[app]": app["id"], "limit": 200})
    print(f"Beta groups ({len(groups)}):" if groups else "Beta groups: none")
    for g in groups:
        ga = g["attributes"]
        total = (
            api.get(f"/v1/betaGroups/{g['id']}/betaTesters", limit=1)
            .get("meta", {})
            .get("paging", {})
            .get("total", "?")
        )
        kind = "internal" if ga.get("isInternalGroup") else "external"
        print(f"  {ga.get('name')}  ({kind}, {total} testers)")
    return 0


def ensure_group(api: Client, app_id: str) -> dict[str, Any]:
    group = find_group(api, app_id)
    if group is None:
        group = api.post(
            "/v1/betaGroups",
            {
                "data": {
                    "type": "betaGroups",
                    "attributes": {"name": GROUP_NAME},
                    "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
                }
            },
        )["data"]
        print(f"Created external beta group {GROUP_NAME!r}")
    else:
        print(f"Beta group {GROUP_NAME!r} exists")
    if group["attributes"].get("isInternalGroup"):
        fail(f"{GROUP_NAME!r} is an internal group; external testers need an external group")
    return group


def ensure_testers(api: Client, app_id: str) -> dict[str, Any]:
    group = ensure_group(api, app_id)
    members = {
        (t["attributes"].get("email") or "").lower(): t for t in group_testers(api, group["id"])
    }
    for email, first, last in TESTERS:
        if email.lower() in members:
            print(f"  {email}: already in the group")
            continue
        # Tester records are per app: the same email has one record for each app it tests,
        # so look only at this app's; otherwise POST creates this app's record in the group.
        existing = api.get(
            "/v1/betaTesters", **{"filter[email]": email, "filter[apps]": app_id, "limit": 5}
        ).get("data")
        match = next(
            (
                t
                for t in existing or []
                if (t["attributes"].get("email") or "").lower() == email.lower()
            ),
            None,
        )
        if match is not None:
            api.post(
                f"/v1/betaGroups/{group['id']}/relationships/betaTesters",
                {"data": [{"type": "betaTesters", "id": match["id"]}]},
            )
            print(f"  {email}: added (existing tester)")
        else:
            attrs = {"email": email}
            if first:
                attrs["firstName"] = first
            if last:
                attrs["lastName"] = last
            api.post(
                "/v1/betaTesters",
                {
                    "data": {
                        "type": "betaTesters",
                        "attributes": attrs,
                        "relationships": {
                            "betaGroups": {"data": [{"type": "betaGroups", "id": group["id"]}]}
                        },
                    }
                },
            )
            print(f"  {email}: added (new tester)")
    return group


def cmd_ensure_testers(api: Client, args: argparse.Namespace) -> int:
    app = require_app(api)
    group = ensure_testers(api, app["id"])
    print(f"Members of {GROUP_NAME!r}:")
    for tester in group_testers(api, group["id"]):
        print(_tester_line(tester))
    print(
        "TestFlight emails the invite once a build in this group has passed beta review "
        "(`make testflight` adds every new build)."
    )
    return 0


def cmd_testers(api: Client, args: argparse.Namespace) -> int:
    app = require_app(api)
    group = find_group(api, app["id"])
    if group is None:
        print(f"No beta group {GROUP_NAME!r} yet (run `make testers`).")
        return 1
    testers = group_testers(api, group["id"])
    print(f"{GROUP_NAME} ({len(testers)} testers):")
    for tester in testers:
        print(_tester_line(tester))
    return 0


def cmd_preflight(api: Client, args: argparse.Namespace) -> int:
    """Read-only check that `distribute` will not stop on missing prerequisites."""
    app = require_app(api)
    detail = api.get(f"/v1/apps/{app['id']}/betaAppReviewDetail")["data"]["attributes"]
    if not (os.environ.get("ASC_REVIEW_PHONE") or detail.get("contactPhone")):
        fail(NO_PHONE)
    print(f"Preflight ok: app record for {BUNDLE_ID}, beta review contact phone available")
    return 0


def cmd_wait_build(api: Client, args: argparse.Namespace) -> int:
    app = require_app(api)
    deadline = time.monotonic() + args.timeout * 60
    started = time.monotonic()
    last_state = None
    last_heartbeat = started
    print(f"Waiting for build {args.build} to finish processing (up to {args.timeout} min)...")
    while True:
        build = find_build(api, app["id"], args.build)
        state = build["attributes"].get("processingState") if build else "NOT_VISIBLE_YET"
        elapsed = int(time.monotonic() - started)
        if state != last_state:
            print(f"  [{elapsed // 60:>2}m{elapsed % 60:02d}s] {state}", flush=True)
            last_state = state
            last_heartbeat = time.monotonic()
        elif time.monotonic() - last_heartbeat >= 300:
            print(f"  [{elapsed // 60:>2}m{elapsed % 60:02d}s] still {state}", flush=True)
            last_heartbeat = time.monotonic()
        if state == "VALID" and build is not None:
            print(f"Build {build['_marketing']} ({args.build}) is VALID.")
            return 0
        if state in FAILED_PROCESSING_STATES:
            fail(f"build {args.build} processing ended in {state}; see App Store Connect / email")
        if time.monotonic() >= deadline:
            fail(f"build {args.build} still {state} after {args.timeout} min; re-run wait-build")
        time.sleep(POLL_SECONDS)


def _ensure_whats_new(api: Client, build: dict[str, Any], notes: str | None) -> None:
    locs = api.get_all(f"/v1/builds/{build['id']}/betaBuildLocalizations", limit=50)
    loc = next((x for x in locs if x["attributes"].get("locale") == LOCALE), None)
    current = (loc or {}).get("attributes", {}).get("whatsNew") or ""
    wanted = notes if notes else (current or DEFAULT_WHATS_NEW)
    if loc is None:
        api.post(
            "/v1/betaBuildLocalizations",
            {
                "data": {
                    "type": "betaBuildLocalizations",
                    "attributes": {"locale": LOCALE, "whatsNew": wanted},
                    "relationships": {"build": {"data": {"type": "builds", "id": build["id"]}}},
                }
            },
        )
        print("  What to Test: set")
    elif current != wanted:
        api.patch(
            f"/v1/betaBuildLocalizations/{loc['id']}",
            {
                "data": {
                    "type": "betaBuildLocalizations",
                    "id": loc["id"],
                    "attributes": {"whatsNew": wanted},
                }
            },
        )
        print("  What to Test: updated")
    else:
        print("  What to Test: already set")


def _ensure_review_detail(api: Client, app_id: str) -> str:
    detail = api.get(f"/v1/apps/{app_id}/betaAppReviewDetail")["data"]
    have = detail["attributes"]

    def pick(env: str, key: str, default: str) -> str:
        return os.environ.get(env) or have.get(key) or default

    wanted = {
        "contactFirstName": pick(
            "ASC_REVIEW_FIRST_NAME", "contactFirstName", DEFAULT_REVIEW_FIRST_NAME
        ),
        "contactLastName": pick("ASC_REVIEW_LAST_NAME", "contactLastName", DEFAULT_REVIEW_LAST_NAME),
        "contactEmail": pick("ASC_REVIEW_EMAIL", "contactEmail", DEFAULT_REVIEW_EMAIL),
        "contactPhone": pick("ASC_REVIEW_PHONE", "contactPhone", ""),
        "demoAccountRequired": bool(have.get("demoAccountRequired")),
        "notes": have.get("notes") or REVIEW_NOTES,
    }
    if not wanted["contactPhone"]:
        fail(NO_PHONE)
    changed = {k: v for k, v in wanted.items() if have.get(k) != v}
    if changed:
        api.patch(
            f"/v1/betaAppReviewDetails/{detail['id']}",
            {"data": {"type": "betaAppReviewDetails", "id": detail["id"], "attributes": changed}},
        )
        print(f"  Beta review contact: updated ({', '.join(sorted(changed))})")
    else:
        print("  Beta review contact: already set")
    return wanted["contactEmail"]


def _ensure_beta_app_localization(api: Client, app_id: str, review_email: str) -> None:
    locs = api.get_all(f"/v1/apps/{app_id}/betaAppLocalizations", limit=50)
    loc = next((x for x in locs if x["attributes"].get("locale") == LOCALE), None)
    feedback = os.environ.get("ASC_FEEDBACK_EMAIL") or review_email
    if loc is None:
        api.post(
            "/v1/betaAppLocalizations",
            {
                "data": {
                    "type": "betaAppLocalizations",
                    "attributes": {
                        "locale": LOCALE,
                        "feedbackEmail": feedback,
                        "description": BETA_DESCRIPTION,
                    },
                    "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
                }
            },
        )
        print("  Test information (description, feedback email): set")
        return
    have = loc["attributes"]
    changed = {}
    if not have.get("feedbackEmail") or os.environ.get("ASC_FEEDBACK_EMAIL"):
        changed["feedbackEmail"] = feedback
    if not have.get("description"):
        changed["description"] = BETA_DESCRIPTION
    changed = {k: v for k, v in changed.items() if have.get(k) != v}
    if changed:
        api.patch(
            f"/v1/betaAppLocalizations/{loc['id']}",
            {"data": {"type": "betaAppLocalizations", "id": loc["id"], "attributes": changed}},
        )
        print(f"  Test information: updated ({', '.join(sorted(changed))})")
    else:
        print("  Test information: already set")


def _ensure_encryption(api: Client, build: dict[str, Any]) -> None:
    if build["attributes"].get("usesNonExemptEncryption") is None:
        api.patch(
            f"/v1/builds/{build['id']}",
            {
                "data": {
                    "type": "builds",
                    "id": build["id"],
                    "attributes": {"usesNonExemptEncryption": False},
                }
            },
        )
        print("  Export compliance: set usesNonExemptEncryption=false")
    else:
        print(
            "  Export compliance: usesNonExemptEncryption="
            f"{str(build['attributes']['usesNonExemptEncryption']).lower()}"
        )


def _ensure_in_group(api: Client, group: dict[str, Any], build: dict[str, Any]) -> None:
    builds = api.get_all(f"/v1/betaGroups/{group['id']}/builds", limit=200)
    if any(b["id"] == build["id"] for b in builds):
        print(f"  Group {GROUP_NAME!r}: build already added")
        return
    api.post(
        f"/v1/betaGroups/{group['id']}/relationships/builds",
        {"data": [{"type": "builds", "id": build["id"]}]},
    )
    print(f"  Group {GROUP_NAME!r}: build added")


def _ensure_beta_review(api: Client, build: dict[str, Any]) -> str:
    detail = api.get(f"/v1/builds/{build['id']}/buildBetaDetail")["data"]
    if detail["attributes"].get("autoNotifyEnabled") is False:
        api.patch(
            f"/v1/buildBetaDetails/{detail['id']}",
            {
                "data": {
                    "type": "buildBetaDetails",
                    "id": detail["id"],
                    "attributes": {"autoNotifyEnabled": True},
                }
            },
        )
        print("  Auto-notify testers: enabled")
    external = detail["attributes"].get("externalBuildState")
    subs = (
        api.get("/v1/betaAppReviewSubmissions", **{"filter[build]": build["id"], "limit": 5}).get(
            "data"
        )
        or []
    )
    if subs:
        state = subs[0]["attributes"].get("betaReviewState") or "?"
        print(f"  Beta review: submission exists, state={state} (external={external})")
        return state
    if external in REVIEWED_EXTERNAL_STATES:
        print(f"  Beta review: not needed (external={external})")
        return external or "?"
    created = api.post(
        "/v1/betaAppReviewSubmissions",
        {
            "data": {
                "type": "betaAppReviewSubmissions",
                "relationships": {"build": {"data": {"type": "builds", "id": build["id"]}}},
            }
        },
    )["data"]
    state = created["attributes"].get("betaReviewState") or "?"
    print(f"  Beta review: submitted, state={state}")
    return state


def cmd_distribute(api: Client, args: argparse.Namespace) -> int:
    app = require_app(api)
    build = find_build(api, app["id"], args.build)
    if build is None:
        fail(f"no build {args.build} on App Store Connect yet (upload it, then wait-build)")
    state = build["attributes"].get("processingState")
    if state != "VALID":
        fail(
            f"build {args.build} is {state}, not VALID; "
            f"run: python3 scripts/asc.py wait-build {args.build}"
        )
    print(f"Distributing {build['_marketing']} ({args.build}) to {GROUP_NAME!r}:")
    # App-level test information first: a missing review phone stops before anything is written.
    review_email = _ensure_review_detail(api, app["id"])
    _ensure_beta_app_localization(api, app["id"], review_email)
    group = ensure_testers(api, app["id"])
    _ensure_whats_new(api, build, args.notes)
    _ensure_encryption(api, build)
    _ensure_in_group(api, group, build)
    review = _ensure_beta_review(api, build)
    if review in ("APPROVED", "BETA_APPROVED", "IN_BETA_TESTING", "READY_FOR_BETA_TESTING"):
        print("Done: testers in the group can install this build from TestFlight.")
    else:
        print(
            "Done: the build reaches testers when Apple approves the beta review "
            "(the first build of a version can take a day; later builds are usually quicker)."
        )
    return 0


# -------------------------------------------------------------------------------- main ---


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="asc.py", description="App Store Connect / TestFlight helper for score."
    )
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("status", help="app record, latest builds, beta groups")
    p.add_argument("--brief", action="store_true", help="only check the app record")
    p.set_defaults(func=cmd_status)
    p = sub.add_parser("ensure-testers", help=f"create {GROUP_NAME!r} and add the testers")
    p.set_defaults(func=cmd_ensure_testers)
    p = sub.add_parser("testers", help=f"list {GROUP_NAME!r} members and their state")
    p.set_defaults(func=cmd_testers)
    p = sub.add_parser("preflight", help="read-only: can `distribute` run?")
    p.set_defaults(func=cmd_preflight)
    p = sub.add_parser("wait-build", help="poll until the build is VALID")
    p.add_argument("build", help="build number (CFBundleVersion)")
    p.add_argument("--timeout", type=int, default=30, help="minutes (default 30)")
    p.set_defaults(func=cmd_wait_build)
    p = sub.add_parser("distribute", help=f"send a VALID build to {GROUP_NAME!r}")
    p.add_argument("build", help="build number (CFBundleVersion)")
    p.add_argument("--notes", help="What to Test text for this build")
    p.set_defaults(func=cmd_distribute)
    args = parser.parse_args()

    api = Client()
    try:
        return int(args.func(api, args))
    except AscError as err:
        fail(str(err))
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
