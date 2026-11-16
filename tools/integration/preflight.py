"""Read-only I1 checks for a Windows developer shell."""

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from urllib.parse import urljoin

from common import (
    Auth, Blocked, CheckError, FIXTURE_USERS, LOOPBACK, ROOT, Report, STAGING_API, STAGING_AUTH,
    STAGING_KEY, api_base, base_url, expect, parser, process_health, publishable_key,
    request, require, setting,
)


def run_local(command, *, env=None):
    try:
        return subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True,
                              errors="replace", timeout=12, check=True).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        raise Blocked("Local command failed or timed out.") from None


def checkout():
    commit = run_local(["git", "rev-parse", "--short=12", "HEAD"])
    require(re.fullmatch(r"[0-9a-f]{12,40}", commit), "Git did not return a revision.")
    dirty = bool(run_local(["git", "status", "--porcelain"]))
    return f"{commit} ({'local changes present' if dirty else 'clean'})"


def local_android_paths():
    properties = ROOT / "apps/mobile/android/local.properties"
    paths = {}
    if properties.is_file():
        for line in properties.read_text(encoding="utf-8", errors="replace").splitlines():
            name, _, value = line.partition("=")
            if name in ("flutter.sdk", "sdk.dir") and value:
                paths[name] = Path(value.replace(r"\:", ":").replace("\\\\", "\\"))
    return paths


def check_tools(report, database):
    paths = local_android_paths()
    flutter = paths.get("flutter.sdk")
    sdk = paths.get("sdk.dir")
    if sdk is None:
        configured = os.getenv("ANDROID_HOME") or os.getenv("ANDROID_SDK_ROOT")
        sdk = Path(configured) if configured else None
    bat, exe = (".bat", ".exe") if os.name == "nt" else ("", "")
    java_home = os.getenv("JAVA_HOME")
    java = (Path(java_home) / f"bin/java{exe}").is_file() if java_home else shutil.which("java")
    for tool, available in (
        ("Git", shutil.which("git")), ("uv", shutil.which("uv")),
        ("Python 3.12 or 3.13", (3, 12) <= sys.version_info[:2] <= (3, 13)),
        ("Node.js", shutil.which("node")), ("npm", shutil.which("npm")),
        ("Flutter", shutil.which("flutter") or (flutter and (flutter / f"bin/flutter{bat}").is_file())),
        ("Dart", shutil.which("dart") or (flutter and (flutter / f"bin/dart{bat}").is_file())),
        ("JDK", java),
        ("Android SDK", sdk and (sdk / "platforms").is_dir() and (sdk / "build-tools").is_dir()),
        ("adb", shutil.which("adb") or (sdk and (sdk / f"platform-tools/adb{exe}").is_file())),
    ):
        report.add("PASS" if available else "BLOCKED", f"Tool {tool}",
                   "Found" if available else "Install or configure in the developer shell.")
    if database:
        psql = shutil.which("psql")
        report.add("PASS" if psql else "BLOCKED", "Tool psql", "Required for the PostgreSQL probe.")
    for tool in ("docker", "supabase"):
        report.add("PASS" if shutil.which(tool) else "NOT TESTED", f"Tool {tool}",
                   "Used for the optional disposable Supabase CLI suite.")


def android_config(profile):
    require((ROOT / "apps/mobile/android/gradlew.bat").is_file(), "Android Gradle wrapper is missing.")
    mode = os.getenv("ITDA_UPLOAD_MODE", "disabled")
    staging = profile == "staging"
    expected_modes = ("staging",) if staging else ("disabled", "mock")
    if mode not in expected_modes:
        raise Blocked("Select staging for this profile." if staging else "Select disabled or mock for the fixture profile.")
    if mode == "disabled":
        return
    generic = ("ITDA_API_BASE_URL", "ITDA_SUPABASE_URL", "ITDA_SUPABASE_PUBLISHABLE_KEY")
    isolated = (STAGING_API, STAGING_AUTH, STAGING_KEY)
    selected, unused = (isolated, generic) if staging else (generic, isolated)
    require(not any(os.getenv(name) for name in unused), "Android endpoint variable sets must use separate shells.")
    for name in selected[:2]:
        base_url(setting(name), allow_local_http=not staging, local_only=not staging,
                 local_hosts={"localhost", "127.0.0.1", "10.0.2.2"})
    publishable_key(setting(selected[2]))


def database_connection(profile):
    host = setting("PGHOST")
    database = setting("PGDATABASE")
    setting("PGUSER")
    require(re.fullmatch(r"[A-Za-z0-9.:-]+", host) and re.fullmatch(r"[A-Za-z0-9_-]+", database),
            "Supply one PostgreSQL host and a database name in PGHOST and PGDATABASE.")
    require(profile != "fixture" or host in LOOPBACK, "The fixture profile allows only a loopback database.")
    psql = shutil.which("psql")
    if not psql:
        raise Blocked("Install psql or add it to PATH.")
    env = dict(os.environ)
    env.pop("PGSERVICE", None)
    env.pop("PGHOSTADDR", None)
    env.update(PGCONNECT_TIMEOUT="5", PGOPTIONS="-c default_transaction_read_only=on -c statement_timeout=5000")
    return run_local([psql, "-X", "-w", "-At", "-c", """
        select case when to_regclass('public.contents') is not null
                     and to_regclass('public.analysis_jobs') is not null
                     and to_regclass('public.sync_events') is not null
                    then 'schema-present' else 'connected' end
    """], env=env)


def check_web(profile, value):
    if profile == "staging" and not value:
        raise Blocked("Pass --web-url for the approved staging or local API-mode web server.")
    url = base_url(value or "http://127.0.0.1:3000", allow_local_http=True, local_only=profile == "fixture")
    reply = request(url, "/")
    if profile == "staging":
        if reply.status not in (302, 303, 307, 308):
            expect(reply, 307)
        try:
            destination = urljoin(url + "/", reply.headers.get("Location", ""))
        except ValueError:
            raise CheckError("Web returned an invalid redirect.") from None
        require(destination == url + "/login", "Expected an unauthenticated redirect to the same web server's /login.")
        reply = request(url, "/login")
    expect(reply, 200)
    require(reply.headers.get_content_type() == "text/html", "Expected a rendered web page.")
    heading = "잇다에 로그인" if profile == "staging" else "콘텐츠 보관함"
    require(heading.encode("utf-8") in reply.body, "Expected the ITDA sign-in or library page.")


def auth_health(auth):
    value = expect(request(auth.base, "/auth/v1/health", key=auth.key), 200).json()
    require(isinstance(value.get("version"), str) and value.get("name") in ("GoTrue", "Auth"),
            "Expected the Supabase Auth health response.")


def api_checks(report, args):
    base = report.attempt("API configuration", lambda: api_base(args.profile, args.api_url))
    if base is None:
        report.add("NOT TESTED", "API probes", "API base unavailable.")
        return
    persistence = report.attempt("GET /health", lambda: process_health(base, args.profile), "Process health")
    if persistence is None:
        report.add("NOT TESTED", "API bearer gate", "Resolve process health or profile first.")
        return
    path = "/v1/contents?limit=1"
    report.attempt("API bearer required", lambda: expect(request(base, path), 401, "unauthorized"))
    report.attempt("API rejects invalid bearer", lambda: expect(
        request(base, path, token="itda-i1-invalid-probe"), 401, "unauthorized"))
    if args.profile == "fixture":
        report.attempt("Fixture catalog read", lambda: require(isinstance(expect(
            request(base, path, token=FIXTURE_USERS["A"][1]), 200).json().get("items"), list),
            "Expected a catalog page."), "Synthetic bearer and volatile memory")
    elif persistence == "unconfigured":
        report.add("BLOCKED", "API persistence readiness", "API reports unconfigured persistence.")
    else:
        report.add("NOT TESTED", "API persistence readiness", "Run the two-account staging smoke.")


def main():
    command = parser(__doc__)
    command.add_argument("--web-url", help="Web startup URL (fixture default http://127.0.0.1:3000).")
    command.add_argument("--check-db", action="store_true", help="Probe explicitly configured PostgreSQL via psql.")
    args = command.parse_args()
    report = Report()
    try:
        report.add("PASS", "Repository revision", checkout())
    except CheckError as error:
        report.add(error.outcome, "Repository revision", str(error))
    check_tools(report, args.check_db)
    report.attempt("Android build configuration", lambda: android_config(args.profile), "Settings and wrapper")
    api_checks(report, args)
    if args.profile == "staging":
        auth = report.attempt("Supabase Auth configuration", Auth.from_environment)
        if auth:
            report.attempt("Supabase Auth availability", lambda: auth_health(auth), "GET /auth/v1/health")
        else:
            report.add("NOT TESTED", "Supabase Auth availability", "Configure the approved Auth project.")
    else:
        report.add("NOT TESTED", "Supabase Auth availability", "Fixture profile uses synthetic identities.")
    if args.check_db:
        result = report.attempt("PostgreSQL connectivity", lambda: database_connection(args.profile), "Read-only query")
        if result is not None:
            report.add("PASS" if result == "schema-present" else "BLOCKED", "PostgreSQL schema probe",
                       "Content, job, and sync tables checked.")
    else:
        report.add("NOT TESTED", "PostgreSQL connectivity", "Use --check-db with disposable database settings.")
    report.attempt("Web startup", lambda: check_web(args.profile, args.web_url), "Unauthenticated page")
    entry = ROOT / "services/backend/worker/__main__.py"
    if not entry.is_file() or "Worker scaffold only" in entry.read_text(encoding="utf-8"):
        report.add("BLOCKED" if args.profile == "staging" else "NOT TESTED", "Worker execution",
                   "This checkout has no runnable job consumer.")
    else:
        report.add("NOT TESTED", "Worker execution", "Verify a deterministic job reaches persisted results.")
    return report.exit_code()


if __name__ == "__main__":
    sys.exit(main())
