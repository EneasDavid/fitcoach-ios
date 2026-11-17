"""Tests for the CI checkers themselves: a security gate that never fails proves nothing, so each rule is shown to catch a planted violation
(and to leave clean input alone). Run: python3 -m unittest discover -s scripts/ci -p 'test_*.py'"""
import importlib.util
import pathlib
import tempfile
import textwrap
import unittest

HERE = pathlib.Path(__file__).resolve().parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, HERE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


workflows = load("check_workflows")
masvs = load("masvs_static_checks")


def parse(text):
    import yaml
    return yaml.safe_load(textwrap.dedent(text))


GOOD = """
name: ok
on: { pull_request: {} }
permissions: { contents: read }
jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@1111111111111111111111111111111111111111
        with: { persist-credentials: false }
      - run: echo "$TITLE"
        env: { TITLE: "${{ github.event.pull_request.title }}" }
"""


class WorkflowChecks(unittest.TestCase):
    def problems(self, text): return workflows.check_workflow("t.yml", parse(text))

    def test_a_clean_workflow_passes(self):
        self.assertEqual(self.problems(GOOD), [])

    def test_pull_request_target_is_refused(self):
        self.assertTrue(any("pull_request_target" in p for p in self.problems(GOOD.replace("pull_request: {}", "pull_request_target: {}"))))

    def test_missing_or_broad_permissions_are_refused(self):
        self.assertTrue(any("permissions" in p for p in self.problems(GOOD.replace("permissions: { contents: read }\n", ""))))
        self.assertTrue(any("write-all" in p for p in self.problems(GOOD.replace("{ contents: read }", "write-all"))))

    def test_a_job_without_timeout_is_refused(self):
        self.assertTrue(any("timeout" in p for p in self.problems(GOOD.replace("    timeout-minutes: 10\n", ""))))

    def test_every_action_needs_a_full_sha_even_the_official_ones(self):
        sha = "a" * 40
        for ref in ("someone/tool@v1", "actions/cache@v4", "actions/cache@main", "actions/cache"):
            bad = GOOD.replace("      - run: echo", f"      - uses: {ref}\n      - run: echo")
            self.assertTrue(any("pinned" in p or "no version" in p for p in self.problems(bad)), ref)
        self.assertEqual(self.problems(GOOD.replace("      - run: echo", f"      - uses: someone/tool@{sha}\n      - run: echo")), [])
        self.assertEqual(self.problems(GOOD.replace("      - run: echo", "      - uses: ./.github/actions/local\n      - run: echo")), [])

    def test_checkout_must_not_persist_the_token(self):
        self.assertTrue(any("persist-credentials" in p for p in self.problems(GOOD.replace("with: { persist-credentials: false }", "with: {}"))))

    def test_untrusted_expressions_in_run_are_refused_but_env_is_fine(self):
        bad = GOOD.replace('echo "$TITLE"', 'echo "${{ github.event.pull_request.title }}"')
        self.assertTrue(any("untrusted" in p for p in self.problems(bad)))
        self.assertTrue(any("untrusted" in p for p in self.problems(GOOD.replace('echo "$TITLE"', 'echo ${{ github.head_ref }}'))))
        self.assertTrue(any("untrusted" in p for p in self.problems(GOOD.replace('echo "$TITLE"', 'curl ${{ inputs.url }}'))))

    def test_echoing_a_secret_is_refused(self):
        self.assertTrue(any("secret" in p for p in self.problems(GOOD.replace('echo "$TITLE"', 'echo ${{ secrets.TOKEN }}'))))

    def test_docker_images_must_be_pinned_by_digest(self):
        self.assertTrue(any("digest" in p for p in self.problems(GOOD.replace("      - run: echo", "      - uses: docker://alpine:3\n      - run: echo"))))

    def test_every_workflow_in_the_repository_passes(self):
        self.assertEqual(workflows.main([]), 0)


def tree(files):
    root = pathlib.Path(tempfile.mkdtemp())
    for name, text in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(textwrap.dedent(text), encoding="utf-8")
    return root


PRIVACY = '<plist><dict><key>NSPrivacyTracking</key><false/></dict></plist>'


class MasvsChecks(unittest.TestCase):
    def found(self, files, check):
        return [f.check for f in check(tree({"App/PrivacyInfo.xcprivacy": PRIVACY, **files}))]

    def test_the_repository_is_clean(self):
        self.assertEqual(masvs.run(HERE.parents[1]), [])

    def test_cleartext_urls_are_caught_but_localhost_is_not(self):
        self.assertEqual(self.found({"Sources/A.swift": 'let u = URL(string: "http://example.com/x")'}, masvs.check_cleartext), ["cleartext-url"])
        self.assertEqual(self.found({"Sources/A.swift": 'let u = URL(string: "http://localhost:9099")'}, masvs.check_cleartext), [])
        self.assertEqual(self.found({"Sources/A.swift": '// see http://example.com\nlet a = 1'}, masvs.check_cleartext), [])

    def test_disabled_app_transport_security_is_caught(self):
        plist = "<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key>\n<true/></dict>"
        self.assertEqual(self.found({"App/Info.plist": plist}, masvs.check_ats), ["ats-disabled"])
        self.assertEqual(self.found({"project.yml": "NSAllowsArbitraryLoads: true"}, masvs.check_ats), ["ats-disabled"])
        self.assertEqual(self.found({"App/Info.plist": "<key>NSAllowsArbitraryLoads</key><false/>"}, masvs.check_ats), [])

    def test_weak_crypto_is_caught_but_sha256_is_not(self):
        self.assertEqual(self.found({"Sources/C.swift": "let h = Insecure.MD5.hash(data: d)"}, masvs.check_crypto), ["weak-crypto"])
        self.assertEqual(self.found({"functions/a.js": "crypto.createHash('sha1')"}, masvs.check_crypto), ["weak-crypto"])
        self.assertEqual(self.found({"Sources/C.swift": "let h = SHA256.hash(data: d)"}, masvs.check_crypto), [])

    def test_secrets_in_userdefaults_are_caught(self):
        self.assertEqual(self.found({"App/S.swift": 'UserDefaults.standard.set(t, forKey: "auth.token")'}, masvs.check_storage), ["secret-in-userdefaults"])
        self.assertEqual(self.found({"App/S.swift": 'UserDefaults.standard.set(on, forKey: "dataSaver.enabled")'}, masvs.check_storage), [])
        self.assertEqual(self.found({"App/S.swift": "kSecAttrAccessibleAlways"}, masvs.check_storage), ["keychain-always"])

    def test_hard_coded_secrets_are_caught_unless_allow_listed(self):
        google = "AIza" + "x" * 35                                   # built from parts so this file doesn't trip the scanner itself
        self.assertEqual(self.found({"App/K.swift": f'let k = "{google}"'}, masvs.check_secrets), ["hard-coded-secret"])
        self.assertEqual(self.found({"App/K.swift": f'let k = "{google}" // allowlist-secret'}, masvs.check_secrets), [])
        fake = '{"client_' + 'secret": "abcdefgh1234"}'                 # also built from parts
        self.assertEqual(self.found({"a.json": fake}, masvs.check_secrets), ["hard-coded-secret"])
        key = "-----BEGIN " + "RSA PRIVATE KEY-----"
        self.assertEqual(self.found({"k.txt": key}, masvs.check_secrets), ["hard-coded-secret"])

    def test_privacy_manifest_and_location_purpose(self):
        self.assertEqual([f.check for f in masvs.check_privacy(tree({}))], ["privacy-manifest"])
        self.assertEqual([f.check for f in masvs.check_privacy(tree({"App/PrivacyInfo.xcprivacy": "<plist/>"}))], ["privacy-tracking"])
        usage = {"App/PrivacyInfo.xcprivacy": PRIVACY, "App/L.swift": "let m = CLLocationManager()"}
        self.assertEqual([f.check for f in masvs.check_privacy(tree(usage))], ["location-purpose"])
        self.assertEqual([f.check for f in masvs.check_privacy(tree({**usage, "project.yml": "NSLocationWhenInUseUsageDescription: why"}))], [])

    def test_open_or_ownerless_firestore_rules_are_caught(self):
        deny = "match /{document=**} { allow read, write: if false; }"
        rules = lambda body: {"firebase/firestore.rules": f"service cloud.firestore {{ match /d/{{db}}/documents {{ {body} {deny} }} }}"}
        self.assertEqual(self.found(rules("match /a/{id} { allow read: if true; }"), masvs.check_firestore_rules), ["rules-open"])
        self.assertEqual(self.found(rules("match /a/{id} { allow write: if request.auth != null; }"), masvs.check_firestore_rules), ["rules-write-without-owner"])
        self.assertEqual(self.found(rules("match /a/{id} { allow create: if isSelf(id); }"), masvs.check_firestore_rules), [])
        self.assertEqual(self.found({"firebase/firestore.rules": "match /a/{id} { allow read: if isSelf(id); }"}, masvs.check_firestore_rules), ["rules-default-deny"])

    def test_http_endpoints_without_authentication_are_caught(self):
        js = "exports.open = onRequest({}, async (req, res) => { res.json({}); });\nexports.shut = onRequest({}, async (req, res) => { const uid = await requireUser(req, res); });\nexports.job = onDocumentCreated('x', async () => {});"
        self.assertEqual(self.found({"functions/index.js": js}, masvs.check_function_auth), ["endpoint-without-auth"])


if __name__ == "__main__":
    unittest.main()
