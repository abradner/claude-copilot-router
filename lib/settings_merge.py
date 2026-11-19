"""Write the router's files without clobbering the user's. No secrets pass through argv:
the proxy key is referenced by path only (apiKeyHelper reads it at run time).

  kit     DEST STATE KEYPATH URL SONNET OPUS HAIKU MAIN
                                                    set the router-owned keys in the profile's
                                                    settings.json, keep everything else; the
                                                    first run saves what those keys held in STATE
  unkit   DEST STATE KEYPATH URL                    remove the router-owned keys, restoring
                                                    what STATE saved (without STATE, remove only
                                                    values that are recognisably the router's).
                                                    STATE is kept: the caller deletes it last
  check   DEST [STATE...]                           exit non-zero unless DEST (and STATE files)
                                                    can be read and written safely

Files the router writes are never symlinks: it refuses rather than write through a link, so a
profile's settings.json linked to ~/.claude/settings.json can never change the main profile.
  config  DEST SONNET OPUS HAIKU                    write the LiteLLM proxy config.yaml
  share   SRC DEST STATE                            copy hooks/statusLine/outputStyle from SRC
                                                    (SRC is only read, never modified)
  unshare DEST STATE                                undo `share`, restoring earlier values
"""
import json
import os
import shlex
import sys
import tempfile

SHARE_KEYS = ("hooks", "statusLine", "outputStyle")

# Exported credentials/provider switches are blanked so only the proxy key is used.
BLANKED = ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
           "ANTHROPIC_PROFILE", "ANTHROPIC_CUSTOM_HEADERS",
           "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY")
# The env keys a state file written before it recorded "keys" covered.
LEGACY_ENV = ("ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
              "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
              "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC") + BLANKED
# Auto mode's server-side checks run on Anthropic's servers, which Copilot is not: without this,
# Claude Code warns on every auto mode session and falls back to its own classifier requests
# anyway (they go through the proxy, so they use Copilot quota either way).
ROUTER_ENV = LEGACY_ENV + ("CLAUDE_CODE_AUTO_MODE_SERVER",)


def cc_name(copilot_id):
    """Claude Code expects Anthropic-style ids (dashes); Copilot ids may use dots."""
    return copilot_id.replace(".", "-")


def load(path):
    """A settings file is never moved or rewritten when it is not valid JSON: that would leave
    Claude Code running without the user's deny rules. Stop and let the user fix it."""
    if not os.path.exists(path):
        return {}
    try:
        with open(path) as f:
            data = json.load(f)
        if not isinstance(data, dict):
            raise ValueError("not a JSON object")
        return data
    except ValueError as e:
        sys.exit(f"error: {path} is not valid JSON ({e}); fix it first (left untouched)")


def no_link(*paths):
    for path in paths:
        if os.path.islink(path):
            sys.exit(f"error: {path} is a symlink; the router never writes through links. "
                     "Replace it with a copy of the file, then rerun.")


def write_atomic(path, text):
    """Replace path's contents atomically; an existing file keeps its mode, new files are 0600."""
    no_link(path)
    mode = os.stat(path).st_mode & 0o777 if os.path.exists(path) else 0o600
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".ccr.")
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def save(path, data):
    write_atomic(path, json.dumps(data, indent=2) + "\n")


def load_state(state):
    st = load(state)
    prev = st.get("prev", {})
    env = prev.get("env", {}) if isinstance(prev, dict) else None
    shared = st.get("shared", [])
    keys = st.get("keys", [])
    if not (isinstance(prev, dict) and isinstance(env, dict)
            and all(isinstance(v, str) for v in env.values())
            and isinstance(prev.get("apiKeyHelper", ""), (str, type(None)))
            and isinstance(shared, list) and all(isinstance(k, str) for k in shared)
            and isinstance(keys, list) and all(isinstance(k, str) for k in keys)):
        sys.exit(f"error: {state} is not in the expected shape; fix or delete it (left untouched)")
    return st


def check(dest, *states):
    no_link(dest, *states)
    load(dest)
    for state in states:
        load_state(state)


def kit(dest, state, keypath, url, sonnet, opus, haiku, main):
    models = {"sonnet": cc_name(sonnet), "opus": cc_name(opus), "haiku": cc_name(haiku)}
    no_link(dest, state)
    existed = os.path.exists(dest)
    s = load(dest)
    helper = f"/bin/cat {shlex.quote(keypath)}"
    ours = {
        "ANTHROPIC_BASE_URL": url,
        "ANTHROPIC_MODEL": models[main],
        "ANTHROPIC_DEFAULT_SONNET_MODEL": models["sonnet"],
        "ANTHROPIC_DEFAULT_OPUS_MODEL": models["opus"],
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": models["haiku"],
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        "CLAUDE_CODE_AUTO_MODE_SERVER": "0",
        **{k: "" for k in BLANKED},
    }
    env = s.get("env") if isinstance(s.get("env"), dict) else {}
    if not os.path.exists(state):
        # First run: remember what the router is about to replace, so unkit can put it back.
        # A profile that already carries this helper was kitted before STATE existed: there,
        # values equal to the router's own are the router's, not the user's.
        kitted = s.get("apiKeyHelper") == helper
        prev = {"env": {k: env[k] for k in ROUTER_ENV
                        if k in env and not (kitted and env[k] == ours[k])}}
        if "apiKeyHelper" in s and not kitted:
            prev["apiKeyHelper"] = s["apiKeyHelper"]
        save(state, {"prev": prev, "existed": existed, "keys": list(ROUTER_ENV)})
    else:
        # STATE from an older version did not cover keys the router has started setting since.
        # The router never wrote those, so any value they hold now is the user's: save it too.
        st = load_state(state)
        tracked = st.get("keys", LEGACY_ENV)
        new = [k for k in ROUTER_ENV if k not in tracked]
        if new:
            st.setdefault("prev", {}).setdefault("env", {}).update(
                {k: env[k] for k in new if k in env})
            st["keys"] = sorted(set(tracked) | set(ROUTER_ENV))
            save(state, st)
    s["apiKeyHelper"] = helper
    env.update(ours)
    s["env"] = env
    save(dest, s)


def unkit(dest, state, keypath, url):
    no_link(dest, state)
    if not os.path.exists(dest):
        return
    s = load(dest)
    env = s.get("env") if isinstance(s.get("env"), dict) else {}
    if os.path.exists(state):
        st = load_state(state)
        prev = st["prev"] if "prev" in st else {}
        s.pop("apiKeyHelper", None)
        if "apiKeyHelper" in prev:
            s["apiKeyHelper"] = prev["apiKeyHelper"]
        for k in ROUTER_ENV:
            env.pop(k, None)
        env.update(prev.get("env", {}))
        existed = st.get("existed", True)
    else:
        # No record of what was there before: take out only what is recognisably the router's,
        # and only when the router's own key helper shows it was kitted at all.
        if s.get("apiKeyHelper") == f"/bin/cat {shlex.quote(keypath)}":
            s.pop("apiKeyHelper")
            if env.get("ANTHROPIC_BASE_URL") == url:
                env.pop("ANTHROPIC_BASE_URL")
            for k in BLANKED:
                if env.get(k) == "":
                    env.pop(k)
        left = [k for k in ROUTER_ENV if k in env]
        if left:
            print(f"note: {dest}: no saved state, so these were kept; check them: {', '.join(left)}")
        existed = True
    if env:
        s["env"] = env
    else:
        s.pop("env", None)
    if not s and not existed:
        os.remove(dest)
    else:
        save(dest, s)


def config(dest, sonnet, opus, haiku):
    lines = ["# Written by claude-copilot-router install.sh; change models with install.sh flags.",
             "model_list:"]
    for cid in dict.fromkeys((sonnet, opus, haiku)):
        lines += [f"  - model_name: {cc_name(cid)}",
                  "    litellm_params:",
                  f"      model: github_copilot/{cid}"]
    lines += ["general_settings:",
              "  master_key: os.environ/LITELLM_MASTER_KEY",
              "litellm_settings:",
              "  drop_params: false", ""]
    write_atomic(dest, "\n".join(lines))


def share(src, dest, state):
    no_link(dest, state)
    sv = load(src)
    s = load(dest)
    st = load_state(state)
    prev = st.get("prev", {})          # values the profile had before the first share
    added = [k for k in SHARE_KEYS if k in sv]
    for k in added:
        if k not in prev:
            prev[k] = s.get(k)
            if k in s and s[k] != sv[k]:
                print(f"note: replacing the profile's own {k}; --unlink restores it")
        s[k] = sv[k]
    save(dest, s)
    save(state, {"shared": sorted(set(st.get("shared", [])) | set(added)), "prev": prev})
    for k in added:
        print(f"shared: {k}")
    hooks = sv.get("hooks")
    if isinstance(hooks, dict):
        for event, groups in hooks.items():
            for g in groups if isinstance(groups, list) else []:
                for h in (g.get("hooks", []) if isinstance(g, dict) else []):
                    if isinstance(h, dict):
                        print(f"  hook {event}: {h.get('command', h.get('type'))}")


def unshare(dest, state):
    no_link(dest, state)
    st = load_state(state)
    s = load(dest)
    prev = st.get("prev", {})
    for k in st.get("shared", []):
        if prev.get(k) is not None:
            s[k] = prev[k]
            print(f"restored: {k}")
        elif s.pop(k, None) is not None:
            print(f"removed: {k}")
    save(dest, s)
    if os.path.exists(state):
        os.remove(state)


COMMANDS = {"kit": kit, "unkit": unkit, "check": check, "config": config, "share": share, "unshare": unshare}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        sys.exit(__doc__)
    COMMANDS[sys.argv[1]](*sys.argv[2:])
