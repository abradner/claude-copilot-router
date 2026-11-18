"""Unit tests for lib/settings_merge.py: the router must never clobber a user's settings."""
import json
import os
import subprocess
import sys
import tempfile
import unittest

LIB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib")
sys.path.insert(0, LIB)
import settings_merge as sm  # noqa: E402

MODELS = ("claude-sonnet-5.5", "claude-opus-5.5", "claude-haiku-5.5")


class MergeTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="ccr-test.")
        self.dest = os.path.join(self.d, "settings.json")

    def write(self, path, data):
        with open(path, "w") as f:
            json.dump(data, f)

    def read(self, path=None):
        with open(path or self.dest) as f:
            return json.load(f)

    def test_kit_keeps_user_keys_and_sets_router_keys(self):
        self.write(self.dest, {"theme": "dark", "env": {"MY_VAR": "1"}, "hooks": {"Stop": []}})
        sm.kit(self.dest, "/k/master-key", "http://127.0.0.1:4141", *MODELS, "opus")
        s = self.read()
        self.assertEqual(s["theme"], "dark")
        self.assertEqual(s["hooks"], {"Stop": []})
        self.assertEqual(s["env"]["MY_VAR"], "1")
        self.assertEqual(s["apiKeyHelper"], "/bin/cat /k/master-key")
        self.assertEqual(s["env"]["ANTHROPIC_BASE_URL"], "http://127.0.0.1:4141")
        self.assertEqual(s["env"]["ANTHROPIC_MODEL"], "claude-opus-5-5")
        self.assertEqual(s["env"]["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "claude-haiku-5-5")
        for k in sm.BLANKED:
            self.assertEqual(s["env"][k], "")
        self.assertEqual(os.stat(self.dest).st_mode & 0o777, 0o600)

    def test_kit_is_idempotent(self):
        sm.kit(self.dest, "/k", "http://127.0.0.1:4141", *MODELS, "sonnet")
        first = self.read()
        sm.kit(self.dest, "/k", "http://127.0.0.1:4141", *MODELS, "sonnet")
        self.assertEqual(first, self.read())

    def test_kit_on_missing_file(self):
        sm.kit(self.dest, "/k", "http://127.0.0.1:5000", *MODELS, "haiku")
        self.assertEqual(self.read()["env"]["ANTHROPIC_MODEL"], "claude-haiku-5-5")

    def test_invalid_json_is_moved_aside_not_lost(self):
        with open(self.dest, "w") as f:
            f.write("{not json")
        sm.kit(self.dest, "/k", "http://127.0.0.1:4141", *MODELS, "sonnet")
        backups = [n for n in os.listdir(self.d) if n.startswith("settings.json.bad-")]
        self.assertEqual(len(backups), 1)
        with open(os.path.join(self.d, backups[0])) as f:
            self.assertEqual(f.read(), "{not json")

    def test_share_and_unshare_round_trip(self):
        src = os.path.join(self.d, "src.json")
        state = os.path.join(self.d, "state.json")
        self.write(src, {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "x"}]}]},
                         "statusLine": {"type": "command", "command": "y"},
                         "permissions": {"allow": ["Bash(rm:*)"]}})
        self.write(self.dest, {"theme": "dark"})
        sm.share(src, self.dest, state)
        s = self.read()
        self.assertIn("hooks", s)
        self.assertIn("statusLine", s)
        self.assertNotIn("permissions", s, "permissions must never be copied")
        sm.unshare(self.dest, state)
        self.assertEqual(self.read(), {"theme": "dark"})
        self.assertFalse(os.path.exists(state))

    def test_share_restores_profiles_own_values(self):
        src = os.path.join(self.d, "src.json")
        state = os.path.join(self.d, "state.json")
        self.write(src, {"hooks": {"Stop": ["shared"]}})
        self.write(self.dest, {"hooks": {"Stop": ["mine"]}, "theme": "dark"})
        sm.share(src, self.dest, state)
        sm.share(src, self.dest, state)  # re-share must not lose the original
        self.assertEqual(self.read()["hooks"], {"Stop": ["shared"]})
        sm.unshare(self.dest, state)
        self.assertEqual(self.read(), {"hooks": {"Stop": ["mine"]}, "theme": "dark"})

    def test_share_never_touches_invalid_source(self):
        src = os.path.join(self.d, "src.json")
        with open(src, "w") as f:
            f.write("{broken")
        with self.assertRaises(SystemExit):
            sm.share(src, self.dest, os.path.join(self.d, "st.json"))
        self.assertEqual(open(src).read(), "{broken")
        self.assertFalse(any(n.startswith("src.json.bad-") for n in os.listdir(self.d)))

    def test_unkit_removes_only_router_keys(self):
        self.write(self.dest, {"theme": "dark", "env": {"MY_VAR": "1"}})
        sm.kit(self.dest, "/k", "http://127.0.0.1:4141", *MODELS, "sonnet")
        sm.unkit(self.dest)
        self.assertEqual(self.read(), {"theme": "dark", "env": {"MY_VAR": "1"}})

    def test_apikeyhelper_quotes_path(self):
        sm.kit(self.dest, "/odd'dir/key", "http://127.0.0.1:4141", *MODELS, "sonnet")
        self.assertEqual(self.read()["apiKeyHelper"], "/bin/cat '/odd'\"'\"'dir/key'")

    def test_router_keys_survive_share(self):
        src = os.path.join(self.d, "src.json")
        self.write(src, {"hooks": {}, "env": {"ANTHROPIC_API_KEY": "leak"}})
        sm.kit(self.dest, "/k", "http://127.0.0.1:4141", *MODELS, "sonnet")
        sm.share(src, self.dest, os.path.join(self.d, "st.json"))
        self.assertEqual(self.read()["env"]["ANTHROPIC_API_KEY"], "", "env must never be copied")

    def test_config_yaml(self):
        out = os.path.join(self.d, "config.yaml")
        sm.config(out, "claude-sonnet-5.5", "claude-opus-5.5", "claude-sonnet-5.5")
        text = open(out).read()
        self.assertEqual(text.count("model_name: claude-sonnet-5-5"), 1, "duplicate ids collapse")
        self.assertIn("model: github_copilot/claude-opus-5.5", text)
        self.assertIn("master_key: os.environ/LITELLM_MASTER_KEY", text)

    def test_cli_usage_error(self):
        r = subprocess.run([sys.executable, "-I", os.path.join(LIB, "settings_merge.py"), "nope"],
                           capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main()
