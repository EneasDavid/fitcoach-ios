#!/usr/bin/env python3
"""Static security checks mapped to the OWASP MASVS v2 controls (and the OWASP API Security Top 10 for the backend).

What this is: fast, repeatable checks over the source tree that fail the build on regressions — cleartext traffic, weak crypto, secrets in
the repo or in UserDefaults, permissive Firestore rules, Cloud Functions endpoints without authentication, a missing privacy manifest.
What this is not: a penetration test. MASTG-style dynamic testing (traffic interception, runtime hooking, reverse engineering of the
binary) and resilience controls (MASVS-RESILIENCE) are not covered; see docs/SECURITY_CI.md.

Usage: masvs_static_checks.py [--root DIR]      Exit code 1 when any check fails.
"""
import argparse
import pathlib
import re
import sys
from dataclasses import dataclass

SKIP_DIRS = {"node_modules", ".git", ".build", "build", "DerivedData", ".swiftpm", "xcuserdata"}
TEXT_SUFFIXES = {".swift", ".js", ".json", ".yml", ".yaml", ".plist", ".md", ".sh", ".xcprivacy", ".rules", ".entitlements", ".txt", ".py", ".xcstrings"}
CLEARTEXT_OK = ("localhost", "127.0.0.1", "10.0.2.2", "www.w3.org", "www.apple.com/DTDs")

SECRET_PATTERNS = {
    "Google API key": re.compile(r"AIza[0-9A-Za-z_\-]{35}"),
    "private key block": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    "AWS access key": re.compile(r"AKIA[0-9A-Z]{16}"),
    "GitHub token": re.compile(r"gh[pousr]_[A-Za-z0-9]{36,}"),
    "Slack token": re.compile(r"xox[baprs]-[0-9A-Za-z\-]{10,}"),
    "Stripe live key": re.compile(r"sk_live_[0-9A-Za-z]{16,}"),
    "hard-coded client secret": re.compile(r"""client_?secret["']?\s*[:=]\s*["'][^"'\s]{8,}["']""", re.IGNORECASE),
}
WEAK_CRYPTO = re.compile(r"Insecure\.(MD5|SHA1)|CC_MD5|CC_SHA1\b|kCCAlgorithm(DES|RC4|RC2)|kCCOptionECBMode")
SECRET_KEY_NAMES = re.compile(r"(token|password|passwd|secret|cpf|apikey)", re.IGNORECASE)
AUTH_MARKERS = ("requireUser", "appCheckOnly", "STRAVA_VERIFY_TOKEN", "stravaStates/")


@dataclass(frozen=True)
class Finding:
    check: str
    control: str
    where: str
    message: str


def files(root: pathlib.Path, suffixes=TEXT_SUFFIXES, under: tuple[str, ...] = ()):
    bases = [root / u for u in under] if under else [root]
    for base in bases:
        if not base.exists():
            continue
        for path in base.rglob("*"):
            if path.is_file() and path.suffix in suffixes and not (SKIP_DIRS & set(path.relative_to(root).parts)):
                if path.stat().st_size < 2_000_000:
                    yield path


def lines(path: pathlib.Path):
    try:
        yield from enumerate(path.read_text(encoding="utf-8", errors="ignore").splitlines(), start=1)
    except OSError:
        return


def rel(root, path): return str(path.relative_to(root))


def check_cleartext(root) -> list[Finding]:
    out = []
    for path in files(root, {".swift"}, ("Sources", "App")):
        for number, line in lines(path):
            if line.lstrip().startswith("//"):
                continue
            for match in re.finditer(r"http://[^\s\"')]+", line):
                if not any(ok in match.group(0) for ok in CLEARTEXT_OK):
                    out.append(Finding("cleartext-url", "MASVS-NETWORK-1", f"{rel(root, path)}:{number}", f"plain http URL {match.group(0)}"))
    return out


def check_ats(root) -> list[Finding]:
    out = []
    for name in ("App/Info.plist", "project.yml"):
        path = root / name
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        if re.search(r"NSAllowsArbitraryLoads(InWebContent|ForMedia)?</key>\s*<true/>", text) or re.search(r"NSAllowsArbitraryLoads\w*:\s*(true|YES)", text):
            out.append(Finding("ats-disabled", "MASVS-NETWORK-1", name, "App Transport Security is switched off"))
    return out


def check_crypto(root) -> list[Finding]:
    out = []
    for path in files(root, {".swift", ".js"}, ("Sources", "App", "functions")):
        for number, line in lines(path):
            if WEAK_CRYPTO.search(line) or re.search(r"createHash\(['\"](md5|sha1)['\"]\)", line):
                out.append(Finding("weak-crypto", "MASVS-CRYPTO-1", f"{rel(root, path)}:{number}", "weak hash/cipher"))
    return out


def check_storage(root) -> list[Finding]:
    out = []
    for path in files(root, {".swift"}, ("Sources", "App")):
        for number, line in lines(path):
            if "UserDefaults" in line and re.search(r"forKey:\s*\"[^\"]*\"", line):
                key = re.search(r"forKey:\s*\"([^\"]*)\"", line).group(1)
                if SECRET_KEY_NAMES.search(key):
                    out.append(Finding("secret-in-userdefaults", "MASVS-STORAGE-1", f"{rel(root, path)}:{number}", f"key `{key}` looks sensitive; use the Keychain"))
            if "kSecAttrAccessibleAlways" in line:
                out.append(Finding("keychain-always", "MASVS-STORAGE-1", f"{rel(root, path)}:{number}", "Keychain item readable while the device is locked"))
    return out


def check_secrets(root) -> list[Finding]:
    out = []
    for path in files(root):
        for number, line in lines(path):
            if "allowlist-secret" in line:
                continue
            for label, pattern in SECRET_PATTERNS.items():
                if pattern.search(line):
                    out.append(Finding("hard-coded-secret", "MASVS-STORAGE-2", f"{rel(root, path)}:{number}", label))
    return out


def check_privacy(root) -> list[Finding]:
    out = []
    manifest = root / "App" / "PrivacyInfo.xcprivacy"
    if not manifest.exists():
        return [Finding("privacy-manifest", "MASVS-PRIVACY-1", "App/PrivacyInfo.xcprivacy", "privacy manifest is missing")]
    if not re.search(r"NSPrivacyTracking</key>\s*<false/>", manifest.read_text(encoding="utf-8")):
        out.append(Finding("privacy-tracking", "MASVS-PRIVACY-1", "App/PrivacyInfo.xcprivacy", "NSPrivacyTracking must be declared (false)"))
    uses_location = any("CLLocationManager" in line for p in files(root, {".swift"}, ("App", "Sources")) for _, line in lines(p))
    declared = any("NSLocationWhenInUseUsageDescription" in p.read_text(encoding="utf-8", errors="ignore") for p in (root / "project.yml", root / "App" / "Info.plist") if p.exists())
    if uses_location and not declared:
        out.append(Finding("location-purpose", "MASVS-PRIVACY-3", "project.yml", "location is used but has no usage description"))
    for path in files(root, {".entitlements"}, ("App",)):
        if re.search(r"get-task-allow</key>\s*<true/>", path.read_text(encoding="utf-8", errors="ignore")):
            out.append(Finding("get-task-allow", "MASVS-RESILIENCE-4", rel(root, path), "debuggable entitlement in a committed file"))
    return out


WRITE_OPS = re.compile(r"\b(create|update|write|delete)\b")
OWNERSHIP = re.compile(r"isSelf|isLinkedTrainerOf|isLinkedStudentOf|isTrainerAccount|request\.auth\.uid|me\(\)|resource\.data")


def check_firestore_rules(root) -> list[Finding]:
    path = root / "firebase" / "firestore.rules"
    if not path.exists():
        return []
    text = re.sub(r"//[^\n]*", "", path.read_text(encoding="utf-8"))
    out = []
    for match in re.finditer(r"allow\s+([^:]+):\s*if\s+(.*?);", text, re.DOTALL):
        ops, condition = match.group(1), " ".join(match.group(2).split())
        if condition == "true":
            out.append(Finding("rules-open", "API1:2023 (BOLA)", "firebase/firestore.rules", f"`allow {ops.strip()}: if true`"))
        elif WRITE_OPS.search(ops) and condition != "false" and not OWNERSHIP.search(condition):
            out.append(Finding("rules-write-without-owner", "API1:2023 (BOLA)", "firebase/firestore.rules", f"`allow {ops.strip()}` does not tie the write to an owner: {condition[:80]}"))
    if not re.search(r"match\s+/\{document=\*\*\}\s*\{\s*allow\s+read,\s*write:\s*if\s+false", text):
        out.append(Finding("rules-default-deny", "API5:2023 (BFLA)", "firebase/firestore.rules", "no default-deny rule at the end"))
    return out


def check_function_auth(root) -> list[Finding]:
    path = root / "functions" / "index.js"
    if not path.exists():
        return []
    text = path.read_text(encoding="utf-8")
    parts = re.split(r"^(?=exports\.\w+\s*=)", text, flags=re.MULTILINE)
    out = []
    for part in parts:
        head = re.match(r"exports\.(\w+)\s*=\s*(\w+)", part)
        if head and head.group(2) == "onRequest" and not any(marker in part for marker in AUTH_MARKERS):
            out.append(Finding("endpoint-without-auth", "API2:2023 (Broken Authentication)", f"functions/index.js:{head.group(1)}",
                               "HTTP endpoint with no ID-token, App Check, verify-token or single-use-state check"))
    return out


CHECKS = [check_cleartext, check_ats, check_crypto, check_storage, check_secrets, check_privacy, check_firestore_rules, check_function_auth]


def run(root: pathlib.Path) -> list[Finding]:
    return [finding for check in CHECKS for finding in check(root)]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=str(pathlib.Path(__file__).resolve().parents[2]))
    root = pathlib.Path(parser.parse_args().root).resolve()
    findings = run(root)
    for f in findings:
        print(f"✗ [{f.control}] {f.check}: {f.where} — {f.message}")
    print(f"{len(CHECKS)} check group(s), {len(findings)} finding(s).")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
