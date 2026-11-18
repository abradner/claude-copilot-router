"""Unit tests for lib/settings_merge.py: the router must never clobber a user's settings."""
import json
import os
import shutil
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
        self.addCleanup(shutil.rmtree, self.d)
        self.dest = os.path.join(self.d, "settings.json")
        self.state = os.path.join(self.d, ".ccr-kit-prev.json")

    def write(self, path, data):
        with open(path, "w") as f:
            json.dump(data, f)

    def read(self, path=None):
        with open(path or self.dest) as f:
            return json.load(f)

    def test_kit_keeps_user_keys_and_sets_router_keys(self):
        self.write(self.dest, {"theme": "dark", "env": {"MY_VAR": "1"}, "hooks": {"Stop": []}})
        sm.kit(self.dest, self.state, "/k/master-key", "http://127.0.0.1:4141", *MODELS, "opus")
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

    def test_kit_is_idempotent(self):
        sm.kit(self.dest, self.state, "/k", "http://127.0.0.1:4141", *MODELS, "sonnet")
        first = self.read()
        sm.kit(self.dest, self.state, "/k", "http://127.0.0.1:4141", *MODELS, "sonnet")
        self.assertEqual(first, self.read())

    def test_kit_on_missing_file(self):
        sm.kit(self.dest, self.state, "/k", "http://127.0.0.1:5000", *MODELS, "haiku")
        self.assertEqual(self.read()["env"]["ANTHROPIC_MODEL"], "claude-haiku-5-5")
        self.assertEqual(os.stat(self.dest).st_mode & 0o777, 0o600, "new files are private")

    def test_invalid_json_is_left_untouched(self):
        with open(self.dest, "w") as f:
            f.write("{not json")
        with self.assertRaises(SystemExit):
            sm.kit(self.dest, self.state, "/k", "http://127.0.0.1:4141", *MODELS, "sonnet")
        self.assertEqual(open(self.dest).read(), "{not json")
        self.assertEqual(sorted(os.listdir(self.d)), ["settings.json"])

    def test_unkit_restores_what_kit_replaced(self):
        mine = {"model": "opus", "apiKeyHelper": "/usr/local/bin/my-helper",
                "env": {"ANTHROPIC_MODEL": "x", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
                        "ANTHROPIC_CUSTOM_HEADERS": "h: v", "FOO": "bar"}}
        self.write(self.dest, mine)
        sm.kit(self.dest, self.state, "/k", "http://127.0.0.1:4141", *MODELS, "sonnet")
        sm.kit(self.dest, self.state, "/k", "http://127.0.0.1:5151", *MODELS, "opus")  # rerun
        self.assertEqual(self.read()["apiKeyHelper"], "/bin/cat /k")
        sm.unkit(self.dest, self.state, "/k", "http://127.0.0.1:4141")
        self.assertEqual(self.read(), mine)
        sm.unkit(self.dest, self.state, "/k", "http://127.0.0.1:4141")  # rerun after an interrupt
        self.assertEqual(self.read(), mine)
        self.assertTrue(os.path.exists(self.state), "the caller removes STATE last")

    def test_prekitted_profile_values_are_not_saved_as_users(self):
        sm.kit(self.dest, self.state, "/k", "http://127.0.0.1:4141", *MODELS, "sonnet")
        os.remove(self.state)  # as left by a build without the state file
        sm.kit(self.dest, self.state, "/k", "http://127.0.0.1:4141", *MODELS, "sonnet")
        sm.unkit(self.dest, self.state, "/k", "http://127.0.0.1:4141")
        self.assertEqual(self.read(), {})

    def test_symlinked_settings_are_refused_and_target_untouched(self):
        main = os.path.join(self.d, "main-settings.json")
        self.write(main, {"theme": "dark"})
        os.symlink(main, self.dest)
        for call in (lambda: sm.check(self.dest),
                     lambda: sm.kit(self.dest, self.state, "/k", "http://127.0.0.1:4141", *MODELS, "sonnet"),
                     lambda: sm.unkit(self.dest, self.state, "/k", "http://127.0.0.1:4141"),
                     lambda: sm.share(main, self.dest, self.state)):
            with self.assertRaises(SystemExit):
                call()
        self.assertEqual(self.read(main), {"theme": "dark"})
        self.assertFalse(os.path.exists(self.state))

    def test_symlinked_state_is_refused(self):
        other = os.path.join(self.d, "victim.json")
        os.symlink(other, self.state)
        with self.assertRaises(SystemExit):
            sm.kit(self.dest, self.state, "/k", "http://127.0.0.1:4141", *MODELS, "sonnet")
        self.assertFalse(os.path.exists(other))

    def test_unkit_without_state_removes_only_the_routers_values(self):
        sm.kit(self.dest, self.state, "/k", "http://127.0.0.1:4141", *MODELS, "sonnet")
        s = self.read()
        s["env"]["ANTHROPIC_MODEL"] = "user-model"
        s["env"]["FOO"] = "1"
        self.write(self.dest, s)
        os.remove(self.state)
        sm.unkit(self.dest, self.state, "/k", "http://127.0.0.1:4141")
        env = self.read()["env"]
        self.assertNotIn("apiKeyHelper", self.read())
        self.assertNotIn("ANTHROPIC_BASE_URL", env)
        self.assertNotIn("ANTHROPIC_API_KEY", env)
        self.assertEqual(env["ANTHROPIC_MODEL"], "user-model")
        self.assertEqual(env["FOO"], "1")

    def test_unkit_without_state_keeps_a_users_own_helper(self):
        mine = {"apiKeyHelper": "/usr/local/bin/mine",
                "env": {"ANTHROPIC_BASE_URL": "https://gw.example", "ANTHROPIC_MODEL": "opus"}}
        self.write(self.dest, mine)
        sm.unkit(self.dest, self.state, "/k", "http://127.0.0.1:4141")
        self.assertEqual(self.read(), mine)

    def test_unkit_without_state_keeps_a_users_local_gateway(self):
        mine = {"apiKeyHelper": "/usr/local/bin/mine",
                "env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:8080", "ANTHROPIC_AUTH_TOKEN": ""}}
        self.write(self.dest, mine)
        sm.unkit(self.dest, self.state, "/k", "http://127.0.0.1:4141")
        self.assertEqual(self.read(), mine)

    def test_state_with_wrong_value_types_is_refused(self):
        self.write(self.dest, {"theme": "dark"})
        for bad in ({"prev": {"apiKeyHelper": ["x"]}}, {"prev": {"env": {"A": 1}}}, {"shared": [["x"]]}):
            self.write(self.state, bad)
            with self.assertRaises(SystemExit):
                sm.check(self.dest, self.state)
        self.assertEqual(self.read(), {"theme": "dark"})

    def test_unkit_removes_a_settings_file_it_created(self):
        sm.kit(self.dest, self.state, "/k", "http://127.0.0.1:4141", *MODELS, "sonnet")
        sm.unkit(self.dest, self.state, "/k", "http://127.0.0.1:4141")
        self.assertFalse(os.path.exists(self.dest))

    def test_malformed_state_is_refused_before_any_write(self):
        self.write(self.dest, {"apiKeyHelper": "/bin/cat /k"})
        self.write(self.state, {"prev": [1]})
        with self.assertRaises(SystemExit):
            sm.unkit(self.dest, self.state, "/k", "http://127.0.0.1:4141")
        self.assertEqual(self.read(), {"apiKeyHelper": "/bin/cat /k"})

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
        sm.kit(self.dest, self.state, "/k", "http://127.0.0.1:4141", *MODELS, "sonnet")
        sm.unkit(self.dest, self.state, "/k", "http://127.0.0.1:4141")
        self.assertEqual(self.read(), {"theme": "dark", "env": {"MY_VAR": "1"}})

    def test_apikeyhelper_quotes_path(self):
        sm.kit(self.dest, self.state, "/odd'dir/key", "http://127.0.0.1:4141", *MODELS, "sonnet")
        self.assertEqual(self.read()["apiKeyHelper"], "/bin/cat '/odd'\"'\"'dir/key'")

    def test_router_keys_survive_share(self):
        src = os.path.join(self.d, "src.json")
        self.write(src, {"hooks": {}, "env": {"ANTHROPIC_API_KEY": "leak"}})
        sm.kit(self.dest, self.state, "/k", "http://127.0.0.1:4141", *MODELS, "sonnet")
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
