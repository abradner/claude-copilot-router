"""Write the router's files without clobbering the user's. No secrets pass through argv:
the proxy key is referenced by path only (apiKeyHelper reads it at run time).

  kit     DEST KEYPATH URL SONNET OPUS HAIKU MAIN   set the router-owned keys in the profile's
                                                    settings.json, keep everything else
  unkit   DEST                                      remove the router-owned keys again
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
import time

SHARE_KEYS = ("hooks", "statusLine", "outputStyle")

# Exported credentials/provider switches are blanked so only the proxy key is used.
BLANKED = ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
           "ANTHROPIC_PROFILE", "ANTHROPIC_CUSTOM_HEADERS",
           "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY")
ROUTER_ENV = ("ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
              "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
              "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC") + BLANKED


def cc_name(copilot_id):
    """Claude Code expects Anthropic-style ids (dashes); Copilot ids may use dots."""
    return copilot_id.replace(".", "-")


def load(path, move_bad=True):
    if not os.path.exists(path):
        return {}
    try:
        with open(path) as f:
            data = json.load(f)
        if not isinstance(data, dict):
            raise ValueError("not a JSON object")
        return data
    except ValueError as e:
        if not move_bad:
            sys.exit(f"error: {path} is not valid JSON ({e}); fix it first (left untouched)")
        bak = f"{path}.bad-{time.strftime('%Y%m%dT%H%M%S')}"
        os.replace(path, bak)
        print(f"warning: {path} was not valid JSON ({e}); moved to {bak}", file=sys.stderr)
        return {}


def write_atomic(path, text):
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".ccr.")
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def save(path, data):
    write_atomic(path, json.dumps(data, indent=2) + "\n")


def kit(dest, keypath, url, sonnet, opus, haiku, main):
    models = {"sonnet": cc_name(sonnet), "opus": cc_name(opus), "haiku": cc_name(haiku)}
    s = load(dest)
    s["apiKeyHelper"] = f"/bin/cat {shlex.quote(keypath)}"
    env = s.get("env") if isinstance(s.get("env"), dict) else {}
    env.update({
        "ANTHROPIC_BASE_URL": url,
        "ANTHROPIC_MODEL": models[main],
        "ANTHROPIC_DEFAULT_SONNET_MODEL": models["sonnet"],
        "ANTHROPIC_DEFAULT_OPUS_MODEL": models["opus"],
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": models["haiku"],
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    })
    env.update({k: "" for k in BLANKED})
    s["env"] = env
    save(dest, s)


def unkit(dest):
    s = load(dest)
    s.pop("apiKeyHelper", None)
    env = s.get("env") if isinstance(s.get("env"), dict) else {}
    for k in ROUTER_ENV:
        env.pop(k, None)
    if env:
        s["env"] = env
    else:
        s.pop("env", None)
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
    sv = load(src, move_bad=False)
    s = load(dest)
    st = load(state)
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
    st = load(state)
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


COMMANDS = {"kit": kit, "unkit": unkit, "config": config, "share": share, "unshare": unshare}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        sys.exit(__doc__)
    COMMANDS[sys.argv[1]](*sys.argv[2:])
