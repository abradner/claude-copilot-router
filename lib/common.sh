# Sourced by every script. No secrets here.
# Paths and settings. Non-secret overrides live in $CCR_HOME/router.conf (written by install.sh).

CCR_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/claude-copilot-router"
CCR_TOKENS="$CCR_HOME/tokens"
CCR_VENV="$CCR_HOME/venv"
CCR_KEY="$CCR_HOME/master-key"
CCR_HDR="$CCR_HOME/hdr"
CCR_CONF="$CCR_HOME/router.conf"
CCR_MARK=".claude-copilot-router"     # marker in the profile dir: "created" or "adopted"
CCR_LIB="${${(%):-%x}:A:h}"     # this lib directory
umask 077

# Defaults (overridable by install.sh flags, persisted in router.conf)
CCR_PORT=4141
CCR_PROFILE="$HOME/.claude-copilot"
CCR_ALIAS=claude-copilot
CCR_SONNET=claude-sonnet-5.5
CCR_OPUS=claude-opus-5.5
CCR_HAIKU=claude-haiku-5.5
CCR_MAIN=sonnet

die() { echo "error: $*" >&2; exit 1; }

# Read router.conf as data (KEY=VALUE lines, known keys only), never as code.
ccr_load_conf() {
  [ -f "$CCR_CONF" ] || return 0
  local line k v
  while IFS= read -r line || [ -n "$line" ]; do
    [[ $line == \#* || -z $line ]] && continue
    k="${line%%=*}"; v="${line#*=}"
    case $k in
      CCR_PORT|CCR_PROFILE|CCR_ALIAS|CCR_SONNET|CCR_OPUS|CCR_HAIKU|CCR_MAIN) typeset -g "$k=$v" ;;
      *) echo "warning: ignoring unknown key in $CCR_CONF: $k" >&2 ;;
    esac
  done < "$CCR_CONF"
}

ccr_save_conf() {
  local k
  { echo "# claude-copilot-router settings (not secret). Change with install.sh flags."
    for k in CCR_PORT CCR_PROFILE CCR_ALIAS CCR_SONNET CCR_OPUS CCR_HAIKU CCR_MAIN; do print -r -- "$k=${(P)k}"; done
  } > "$CCR_CONF"
}

ccr_validate() {
  [[ $CCR_PORT == <1024-65535> ]] || die "port must be 1024-65535: $CCR_PORT"
  [ "$CCR_PORT" != 4000 ] || die "port 4000 is not allowed: LiteLLM silently moves to a random port when 4000 is busy"
  [[ $CCR_ALIAS =~ '^[A-Za-z][A-Za-z0-9_-]*$' ]] || die "bad alias name: $CCR_ALIAS"
  [[ $CCR_PROFILE =~ '^/[A-Za-z0-9._/@+-]+$' ]] || die "profile must be an absolute path of letters, digits and ._/@+- only: $CCR_PROFILE"
  ccr_safe_profile "$CCR_PROFILE" || die "refusing profile path $CCR_PROFILE"
  local m; for m in "$CCR_SONNET" "$CCR_OPUS" "$CCR_HAIKU"; do
    [[ $m =~ '^claude-[a-z0-9.-]+$' ]] || die "model ids must look like claude-<name>: $m"
  done
  [[ $CCR_MAIN == (sonnet|opus|haiku) ]] || die "--main must be sonnet, opus or haiku: $CCR_MAIN"
}

# A profile path we are willing to create, and later rm -rf (with the marker present).
ccr_safe_profile() {
  local p="${1%/}" h
  for h in "$HOME" "${HOME:A}"; do   # HOME itself may sit behind a symlink
    case "$p" in
      ""|/|"$h"|"$h/.claude"|"$h/.config"|"${CCR_HOME%/}"|/Users|/home|/tmp|/private|/private/tmp) return 1 ;;
    esac
  done
  [[ $p == "$HOME"/?* || $p == "${HOME:A}"/?* ]]
}

# Claude Code wants Anthropic-style names (dashes); Copilot ids may use dots.
ccr_cc_name() { print -r -- "${1//./-}"; }

# Allow-list the exported environment: anything else could make LiteLLM log
# headers, open ports, migrate a DB, load foreign Python or remote config, or
# send the GitHub token elsewhere. LITELLM_MODE=PRODUCTION stops LiteLLM loading
# a .env file (e.g. ~/.env) that would undo this.
ccr_scrub() {
  local v
  for v in ${(k)parameters[(R)*export*]}; do
    case $v in
      HOME|PATH|USER|LOGNAME|SHELL|TMPDIR|LANG|LC_*|TERM|HTTPS_PROXY|HTTP_PROXY|NO_PROXY|ALL_PROXY|https_proxy|http_proxy|no_proxy|all_proxy|SSL_CERT_FILE|SSL_CERT_DIR|REQUESTS_CA_BUNDLE) ;;
      # unset on a readonly special (PPID, status, LINENO) is fatal in zsh: un-export those instead
      *) if [[ ${parameters[$v]} == *readonly* ]]; then typeset -g +x -- "$v"; else unset -- "$v"; fi ;;
    esac
  done
  # LiteLLM reads SSL_CERT_FILE (else certifi), not REQUESTS_CA_BUNDLE or the macOS Keychain
  [[ -z ${SSL_CERT_FILE-} && -n ${REQUESTS_CA_BUNDLE-} ]] && export SSL_CERT_FILE="$REQUESTS_CA_BUNDLE"
  export GITHUB_COPILOT_TOKEN_DIR="$CCR_TOKENS" LITELLM_MODE=PRODUCTION \
    LITELLM_LOCAL_MODEL_COST_MAP=True DISABLE_ADMIN_UI=True
}

ccr_python() {
  [ -x "$CCR_VENV/bin/python" ] || die "LiteLLM not installed; run ./install.sh"
  print -r -- "$CCR_VENV/bin/python"
}
ccr_key_ok() {
  [ -s "$CCR_KEY" ] || die "missing $CCR_KEY; run ./install.sh"
  [[ "$(<"$CCR_KEY")" =~ '^sk-[0-9a-f]{64}$' ]] || die "$CCR_KEY is malformed; delete it and rerun ./install.sh"
}

# ~/.zshrc alias block: a marker line plus one alias line.
ccr_drop_alias() {
  local zrc="$HOME/.zshrc"
  [ -f "$zrc" ] || return 0
  /usr/bin/sed -i '' '/^# claude-copilot-router alias$/{N;/\nalias [A-Za-z][A-Za-z0-9_-]*=/d;}' "${zrc:A}" \
    || echo "remove the claude-copilot-router alias from ~/.zshrc by hand"
}
ccr_write_alias() {
  local zrc="$HOME/.zshrc"
  ccr_drop_alias
  [ -s "$zrc" ] && [ -n "$(tail -c1 "$zrc")" ] && echo >> "$zrc"
  # Unset any exported Anthropic credentials or provider switches so only the proxy key is used.
  print -r -- "# claude-copilot-router alias
alias $CCR_ALIAS='env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_PROFILE -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX -u CLAUDE_CODE_USE_FOUNDRY -u ANTHROPIC_CUSTOM_HEADERS CLAUDE_CONFIG_DIR=$CCR_PROFILE claude'" >> "$zrc"
}

# Share an existing Claude Code profile: link skills + CLAUDE.md, copy hooks etc.
ccr_link_one() {  # ccr_link_one SRC NAME
  local from="$1/$2" to="$CCR_PROFILE/$2"
  [ -e "$from" ] || { echo "skip $2: $from missing"; return 0; }
  if [ -L "$to" ]; then
    [ "$(readlink "$to")" = "$from" ] && { echo "ok   $2 already linked"; return 0; }
    die "$to is a link to $(readlink "$to"); remove it first"
  fi
  [ -e "$to" ] && die "$to already exists in the profile; move it aside first"
  ln -s "$from" "$to" && echo "link $2 -> $from"
}
ccr_link_from() {  # ccr_link_from SRC [--no-hooks]
  local src="${1%/}"
  [ -d "$src" ] || die "--link-from: $src is not a directory"
  [ "${src:A}" != "${CCR_PROFILE:A}" ] || die "--link-from cannot be the router profile itself"
  ccr_link_one "$src" skills
  ccr_link_one "$src" CLAUDE.md
  print -r -- "$src" > "$CCR_PROFILE/.ccr-linked-from"
  if [ "${2:-}" != --no-hooks ] && [ -f "$src/settings.json" ]; then
    "$(ccr_python)" -I "$CCR_LIB/settings_merge.py" share "$src/settings.json" "$CCR_PROFILE/settings.json" "$CCR_PROFILE/.ccr-shared-keys.json"
  fi
}
ccr_unlink() {  # state lives in the profile, so this always undoes that profile's links
  local src n
  [ -f "$CCR_PROFILE/.ccr-linked-from" ] && src="$(<"$CCR_PROFILE/.ccr-linked-from")"
  if [ -n "${src:-}" ]; then
    for n in skills CLAUDE.md; do
      if [ -L "$CCR_PROFILE/$n" ] && [ "$(readlink "$CCR_PROFILE/$n")" = "$src/$n" ]; then
        rm -- "$CCR_PROFILE/$n" && echo "unlinked $n"
      fi
    done
    rm -f -- "$CCR_PROFILE/.ccr-linked-from"
  fi
  if [ -f "$CCR_PROFILE/.ccr-shared-keys.json" ]; then
    "$(ccr_python)" -I "$CCR_LIB/settings_merge.py" unshare "$CCR_PROFILE/settings.json" "$CCR_PROFILE/.ccr-shared-keys.json"
  fi
}
