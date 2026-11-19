#!/bin/zsh -f
# Install or upgrade claude-copilot-router. Idempotent: re-run with new flags to change settings.
#
#   ./install.sh [--port N] [--profile DIR] [--alias NAME]
#                [--sonnet ID] [--opus ID] [--haiku ID] [--main sonnet|opus|haiku]
#                [--link-from DIR [--no-hooks]] [--unlink] [--adopt]
#
# Model ids are Copilot ids (see ./models.sh), e.g. claude-sonnet-5.5.
# --link-from ~/.claude shares an existing Claude Code setup: links skills/ and CLAUDE.md,
# copies hooks, statusLine and outputStyle. --unlink undoes exactly that.
# --adopt uses an existing Claude Code config dir (with .claude.json) as --profile; uninstall then removes only
# the router's keys, links and marker from it and leaves the directory.
# No GitHub sign-in happens here: run ./login.sh next.
set -eu
here="${0:A:h}"; source "$here/lib/common.sh"
ccr_load_conf
old_profile="$CCR_PROFILE"

link_from="" no_hooks="" unlink="" adopt=""
while (( $# )); do
  case $1 in
    --port) CCR_PORT="${2:?}"; shift ;;
    --profile) CCR_PROFILE="${2:?}"; shift ;;
    --alias) CCR_ALIAS="${2:?}"; shift ;;
    --sonnet) CCR_SONNET="${2:?}"; shift ;;
    --opus) CCR_OPUS="${2:?}"; shift ;;
    --haiku) CCR_HAIKU="${2:?}"; shift ;;
    --main) CCR_MAIN="${2:?}"; shift ;;
    --link-from) link_from="${2:?}"; shift ;;
    --no-hooks) no_hooks=--no-hooks ;;
    --unlink) unlink=1 ;;
    --adopt) adopt=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done
CCR_PROFILE="${CCR_PROFILE:A}"   # relative paths resolve against the current directory
ccr_validate
old_profile="${old_profile:A}"
if [ "$old_profile" != "$CCR_PROFILE" ] && { [ -e "$old_profile/$CCR_MARK" ] || [ -L "$old_profile/$CCR_MARK" ]; }; then
  die "the profile is moving from $old_profile; run ./uninstall.sh first, then install with the new --profile"
fi
# The marker says what uninstall may do: "created" (delete the profile) or "adopted" (keep it).
# An existing marker is never changed; anything else in it stops here.
mark=""
if [ -e "$CCR_PROFILE/$CCR_MARK" ] || [ -L "$CCR_PROFILE/$CCR_MARK" ]; then
  [ -f "$CCR_PROFILE/$CCR_MARK" ] && [ ! -L "$CCR_PROFILE/$CCR_MARK" ] \
    || die "$CCR_PROFILE/$CCR_MARK is not a regular file; inspect it and remove it by hand"
  mark="$(<"$CCR_PROFILE/$CCR_MARK")"
  [[ $mark == (created|adopted) ]] \
    || die "$CCR_PROFILE/$CCR_MARK holds '$mark', not created or adopted; inspect the profile, then write 'adopted' into the marker to keep the directory on uninstall"
elif [ -d "$CCR_PROFILE" ] && [ -n "$(ls -A "$CCR_PROFILE")" ]; then
  [ -n "$adopt" ] || die "$CCR_PROFILE exists and was not created by this tool; pick another --profile, or pass --adopt"
  [ -f "$CCR_PROFILE/.claude.json" ] \
    || die "--adopt: $CCR_PROFILE does not look like a Claude Code config dir (no .claude.json; a project's .claude/ folder is not one)"
  new_mark=adopted
else
  new_mark=created
fi

# Check everything that will be written before writing anything, so a refusal changes nothing.
ccr_no_links "$CCR_HOME" "$CCR_TOKENS" "$CCR_CONF" "$CCR_KEY" "$CCR_HDR" "$CCR_HOME/config.yaml" "$CCR_VENV"
[ -n "$mark" ] || ccr_no_links "$CCR_PROFILE/$CCR_MARK"
# State files a rerun reads: a malformed one must stop the install here, not halfway. Without a
# marker they are leftovers that the fresh marker below clears, so they are not checked.
st=()
if [ -n "$mark" ]; then
  for f in .ccr-kit-prev.json .ccr-shared-keys.json; do
    [[ -e $CCR_PROFILE/$f || -L $CCR_PROFILE/$f ]] && st+=("$CCR_PROFILE/$f")
  done
fi
"$(ccr_merge_python)" -I "$CCR_LIB/settings_merge.py" check "$CCR_PROFILE/settings.json" "${st[@]}"

[ "$(uname)" = Darwin ] || die "macOS only for now"
[ "$(uname -m)" = arm64 ] || die "Apple Silicon only (the locked cryptography wheel is arm64-only on macOS)"
command -v claude >/dev/null || die "Claude Code not on PATH"
ccv="$(claude --version 2>/dev/null | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
if [ -n "$ccv" ]; then
  autoload -Uz is-at-least
  is-at-least 2.1.304 "$ccv" || echo "warning: Claude Code $ccv is older than 2.1.304; run 'claude update' (older versions don't retry rejected request features)" >&2
fi
command -v uv >/dev/null || die "uv missing: brew install uv"
[ -s "$here/requirements.lock" ] || die "requirements.lock missing"

mkdir -p "$CCR_HOME" "$CCR_TOKENS"
chmod 700 "$CCR_HOME" "$CCR_TOKENS"
ccr_save_conf

echo "==> LiteLLM (hash-locked, wheels only) into $CCR_VENV"
[ -x "$CCR_VENV/bin/python" ] || uv venv --python 3.12 "$CCR_VENV"
uv pip sync --python "$CCR_VENV/bin/python" --require-hashes --only-binary :all: "$here/requirements.lock"
py="$CCR_VENV/bin/python"

if [ ! -s "$CCR_KEY" ]; then
  k="$(openssl rand -hex 32)"
  [[ $k =~ '^[0-9a-f]{64}$' ]] || die "openssl rand failed"
  printf 'sk-%s' "$k" > "$CCR_KEY"; unset k
fi
chmod 600 "$CCR_KEY"
ccr_key_ok
key="$(<"$CCR_KEY")"
printf 'x-api-key: %s\n' "$key" > "$CCR_HDR"; unset key
chmod 600 "$CCR_HDR"

echo "==> proxy config and profile $CCR_PROFILE"
"$py" -I "$CCR_LIB/settings_merge.py" config "$CCR_HOME/config.yaml" "$CCR_SONNET" "$CCR_OPUS" "$CCR_HAIKU"
mkdir -p "$CCR_PROFILE"
# Recheck right before the marker exists, so an aborted install never leaves a marker
# without the state uninstall needs.
"$py" -I "$CCR_LIB/settings_merge.py" check "$CCR_PROFILE/settings.json" "${st[@]}"
if [ -z "$mark" ]; then
  # a fresh marker: drop any state left from an earlier, half-removed install
  rm -f -- "$CCR_PROFILE/.ccr-kit-prev.json" "$CCR_PROFILE/.ccr-shared-keys.json" "$CCR_PROFILE/.ccr-linked-from"
  print -r -- "$new_mark" > "$CCR_PROFILE/$CCR_MARK"
fi
"$py" -I "$CCR_LIB/settings_merge.py" kit "$CCR_PROFILE/settings.json" "$CCR_PROFILE/.ccr-kit-prev.json" "$CCR_KEY" \
  "http://127.0.0.1:$CCR_PORT" "$CCR_SONNET" "$CCR_OPUS" "$CCR_HAIKU" "$CCR_MAIN"
ccr_write_alias

[ -n "$unlink" ] && ccr_unlink
[ -n "$link_from" ] && ccr_link_from "${link_from:A}" $no_hooks

echo
echo "Done. Alias '$CCR_ALIAS' added to ~/.zshrc (open a new shell or: exec zsh)."
echo "Next: ./login.sh, ./models.sh, ./run.sh, then ./smoke.sh in another terminal."
echo "Optional: keep tokens out of Time Machine: tmutil addexclusion \"$CCR_HOME\""
