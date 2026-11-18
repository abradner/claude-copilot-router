#!/bin/zsh -f
# Tests for lib/common.sh and the installer's early checks, in a throwaway HOME.
# Needs only zsh and python3 (no uv, no network, no GitHub).
set -u
repo="${0:A:h:h}"
T="$(mktemp -d "${TMPDIR:-/tmp}/ccr-test.XXXXXX")"
[[ $T == */ccr-test.* ]] && trap 'rm -rf -- "$T"' EXIT
export HOME="${T:A}/home"; mkdir -p "$HOME"   # canonical, as common.sh makes it
unset XDG_CONFIG_HOME
pass=0; fail=0
ok()  { echo "ok   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi }

# Each case runs in a subshell so die() does not end the suite.
lib() { ( source "$repo/lib/common.sh"; eval "$1" ) >/dev/null 2>&1; }

check "defaults validate"              'lib ccr_validate'
check "port 4000 refused"              '! lib "CCR_PORT=4000; ccr_validate"'
check "port out of range refused"      '! lib "CCR_PORT=80; ccr_validate"'
check "relative profile refused"       '! lib "CCR_PROFILE=rel/dir; ccr_validate"'
check "profile = HOME refused"         '! lib "CCR_PROFILE=\$HOME; ccr_validate"'
check "profile = ~/.claude refused"    '! lib "CCR_PROFILE=\$HOME/.claude; ccr_validate"'
check "profile outside HOME refused"   '! lib "CCR_PROFILE=/opt/x; ccr_validate"'
check "profile with quote refused"     "! lib \"CCR_PROFILE='\$HOME/a b'; ccr_validate\""
check "profile with ; refused"         '! lib "CCR_PROFILE=\"\$HOME/x;id\"; ccr_validate"'
check "profile with newline refused"   '! lib "CCR_PROFILE=\"\$HOME/x\$(printf \"\\nid\")\"; ccr_validate"' 
check "bad alias refused"              '! lib "CCR_ALIAS=\"x;y\"; ccr_validate"'
check "bad model refused"              '! lib "CCR_SONNET=gpt-4o; ccr_validate"'
check "bad main refused"               '! lib "CCR_MAIN=big; ccr_validate"'
check "cc_name maps dots"              '[ "$(source $repo/lib/common.sh; ccr_cc_name claude-opus-5.5)" = claude-opus-5-5 ]'

# router.conf is data, not code
conf="$HOME/.config/claude-copilot-router"; mkdir -p "$conf"
print -r -- 'CCR_PORT=5151
CCR_ALIAS=$(touch '"$T"'/pwned)
EVIL=1' > "$conf/router.conf"
lib ccr_load_conf
check "conf never executes"            '[ ! -e "$T/pwned" ]'
print -r -- 'CCR_PORT=5151' > "$conf/router.conf"
check "conf value loads"               '[ "$(source $repo/lib/common.sh; ccr_load_conf; echo $CCR_PORT)" = 5151 ]'
rm -f -- "$conf/router.conf"

# alias block: write, rewrite, drop; follows a symlinked .zshrc; keeps other lines
mkdir -p "$HOME/dots"; printf 'export A=1\nalias keep=1' > "$HOME/dots/zshrc"; ln -s dots/zshrc "$HOME/.zshrc"
lib "ccr_write_alias; ccr_write_alias"
check "one alias block after rewrite"  '[ "$(grep -c "^# claude-copilot-router alias$" $HOME/dots/zshrc)" = 1 ]'
check "alias unsets credentials"       'grep -q "env -u ANTHROPIC_API_KEY" $HOME/dots/zshrc'
lib ccr_drop_alias
check "drop leaves user lines"         '[ "$(cat $HOME/dots/zshrc)" = "$(printf "export A=1\nalias keep=1")" ]'
check ".zshrc still a symlink"         '[ -L $HOME/.zshrc ]'

# env scrub: allow-list only, survives readonly specials
out="$(env PPID=5 LINENO=3 FOO=1 GITHUB_COPILOT_API_KEY_URL=http://evil DATABASE_URL=x REQUESTS_CA_BUNDLE=/ca.pem \
  zsh -f -c "set -eu; source $repo/lib/common.sh; ccr_scrub; /usr/bin/env" 2>&1)"
check "scrub drops unknown vars"       '! print -r -- "$out" | grep -q "^FOO="'
check "scrub drops token redirect"     '! print -r -- "$out" | grep -q "GITHUB_COPILOT_API_KEY_URL"'
check "scrub drops DATABASE_URL"       '! print -r -- "$out" | grep -q "^DATABASE_URL="'
check "scrub sets PRODUCTION"          'print -r -- "$out" | grep -q "^LITELLM_MODE=PRODUCTION$"'
check "scrub maps CA bundle"           'print -r -- "$out" | grep -q "^SSL_CERT_FILE=/ca.pem$"'

# link-from / unlink, with python3 standing in for the venv
mkdir -p "$conf/venv/bin" "$HOME/.claude-copilot" "$HOME/.claude/skills/demo"
ln -s "$(command -v python3)" "$conf/venv/bin/python"
echo '# mine' > "$HOME/.claude/CLAUDE.md"
print -r -- '{"hooks":{"Stop":[]},"permissions":{"allow":["x"]}}' > "$HOME/.claude/settings.json"
print -r -- '{"theme":"dark"}' > "$HOME/.claude-copilot/settings.json"
lib 'ccr_link_from $HOME/.claude'
check "skills linked"                  '[ "$(readlink $HOME/.claude-copilot/skills)" = "$HOME/.claude/skills" ]'
check "CLAUDE.md linked"               '[ -L $HOME/.claude-copilot/CLAUDE.md ]'
check "hooks shared"                   'grep -q hooks $HOME/.claude-copilot/settings.json'
check "permissions not shared"         '! grep -q permissions $HOME/.claude-copilot/settings.json'
check "relink is idempotent"           'lib "ccr_link_from \$HOME/.claude"'
lib ccr_unlink
check "unlink removes links"           '[ ! -e $HOME/.claude-copilot/skills ] && [ ! -e $HOME/.claude-copilot/CLAUDE.md ]'
check "unlink removes shared keys"     '! grep -q hooks $HOME/.claude-copilot/settings.json'
check "source untouched"               '[ -d $HOME/.claude/skills/demo ] && [ -f $HOME/.claude/CLAUDE.md ]'
mkdir "$HOME/.claude-copilot/skills"
check "existing skills dir not replaced" '! lib "ccr_link_from \$HOME/.claude"'
check "link-from self refused"         '! lib "ccr_link_from \$HOME/.claude-copilot"'

# key format
mkdir -p "$conf"; print -n "sk-" > "$conf/master-key"
check "malformed key refused"          '! lib ccr_key_ok'
print -n "sk-$(printf '%064d' 0 | tr 0 a)" > "$conf/master-key"
check "well-formed key accepted"       'lib ccr_key_ok'
rm -f -- "$conf/master-key"

# installer refuses bad input before installing anything
mkdir -p "$HOME/notaprofile"; echo x > "$HOME/notaprofile/file"
check "adopt needs a Claude profile"   '"$repo/install.sh" --profile "$HOME/notaprofile" --adopt 2>&1 | grep -q "does not look like a Claude Code config dir"'
mkdir -p "$HOME/oldprof"; echo created > "$HOME/oldprof/.claude-copilot-router"
print -r -- "CCR_PROFILE=$HOME/oldprof" > "$conf/router.conf"
check "profile move refused"           '"$repo/install.sh" --profile "$HOME/newprof" 2>&1 | grep -q "profile is moving"'
rm -f -- "$conf/router.conf"
check "install refuses port 4000"      '! "$repo/install.sh" --port 4000 >/dev/null 2>&1'
mkdir -p "$HOME/someprofile"; echo x > "$HOME/someprofile/file"
check "install refuses foreign profile" '"$repo/install.sh" --profile "$HOME/someprofile" 2>&1 | grep -q "not created by this tool"'
check "install refuses unknown flag"   '! "$repo/install.sh" --bogus >/dev/null 2>&1'
check "install refuses alias claude"   '"$repo/install.sh" --alias claude 2>&1 | grep -q "replace your normal claude"'
mkdir -p "$HOME/oddmark"; print -n "" > "$HOME/oddmark/.claude-copilot-router"
check "install refuses empty marker"   '"$repo/install.sh" --profile "$HOME/oddmark" --adopt 2>&1 | grep -q "not created or adopted"'

# profile paths that must never be used (and so never deleted)
mkdir -p "$HOME/dots/claude"; ln -s "$HOME/dots/claude" "$HOME/.claude-link"
mv "$HOME/.claude" "$HOME/.claude-real"; ln -s "$HOME/dots/claude" "$HOME/.claude"
check "symlinked ~/.claude refused"    '! lib "CCR_PROFILE=\$HOME/dots/claude; ccr_validate"'
check "link to ~/.claude refused"      '! lib "CCR_PROFILE=\$HOME/.claude-link; ccr_validate"'
rm "$HOME/.claude"; mv "$HOME/.claude-real" "$HOME/.claude"
check "inside ~/.claude refused"       '! lib "CCR_PROFILE=\$HOME/.claude/sub; ccr_validate"'
check "foreign CLAUDE_CONFIG_DIR refused" '! lib "CLAUDE_CONFIG_DIR=\$HOME/someprofile; CCR_PROFILE=\$HOME/someprofile; ccr_validate"'
check "own CLAUDE_CONFIG_DIR allowed"  'lib "CLAUDE_CONFIG_DIR=\$HOME/oldprof; CCR_PROFILE=\$HOME/oldprof; ccr_validate"'
check "ancestor of XDG home refused"   '! ( XDG_CONFIG_HOME=$HOME/cfg lib "CCR_PROFILE=\$HOME/cfg; ccr_validate" )'
check "XDG_CONFIG_HOME=HOME refused"   '! ( XDG_CONFIG_HOME=$HOME lib ccr_validate )'
check "empty HOME refused"             '! ( HOME= lib true )'
check "relative HOME refused"          '! ( HOME=rel lib true )'

# uninstall, from hand-built states (no uv needed)
un() { print yes | "$repo/uninstall.sh" >/dev/null 2>&1; }
setup() {  # setup PROFILE MARKER-CONTENT
  mkdir -p "$conf/venv/bin" "$1"; ln -sf "$(command -v python3)" "$conf/venv/bin/python"
  print -r -- "CCR_PROFILE=$1" > "$conf/router.conf"
  [ -n "$2" ] && print -r -- "$2" > "$1/.claude-copilot-router"
  return 0
}
setup "$HOME/p-created" created; echo h > "$HOME/p-created/history.jsonl"
un
check "uninstall deletes created profile" '[ ! -e "$HOME/p-created" ] && [ ! -e "$conf" ]'
setup "$HOME/p-adopted" adopted; echo '{}' > "$HOME/p-adopted/.claude.json"
print -r -- '{"model":"opus","apiKeyHelper":"/usr/local/bin/mine","env":{"FOO":"1"}}' > "$HOME/p-adopted/settings.json"
python3 -I "$repo/lib/settings_merge.py" kit "$HOME/p-adopted/settings.json" "$HOME/p-adopted/.ccr-kit-prev.json" /k http://127.0.0.1:4141 claude-a claude-b claude-c sonnet
rm "$conf/venv/bin/python"   # uninstall must not need the venv
un
check "uninstall keeps adopted profile" '[ -f "$HOME/p-adopted/.claude.json" ] && [ ! -e "$HOME/p-adopted/.claude-copilot-router" ]'
check "uninstall restores adopted settings" 'python3 -I -c "import json,sys; sys.exit(json.load(open(sys.argv[1])) != {\"model\": \"opus\", \"apiKeyHelper\": \"/usr/local/bin/mine\", \"env\": {\"FOO\": \"1\"}})" "$HOME/p-adopted/settings.json"'
setup "$HOME/p-odd" ""; print -n "" > "$HOME/p-odd/.claude-copilot-router"; echo h > "$HOME/p-odd/keep"
un
check "uninstall skips empty marker"   '[ -f "$HOME/p-odd/keep" ]'
setup "$HOME/p-none" ""; echo h > "$HOME/p-none/keep"
un
check "uninstall skips unmarked profile" '[ -f "$HOME/p-none/keep" ]'
mkdir -p "$HOME/ext/prof"; echo created > "$HOME/ext/prof/.claude-copilot-router"; ln -s "$HOME/ext/prof" "$HOME/p-link"
setup "$HOME/p-link/" ""
un
check "uninstall refuses symlinked profile" '[ -f "$HOME/ext/prof/.claude-copilot-router" ] && [ -d "$conf" ]'
print -r -- "CCR_PROFILE=$HOME/p-none" > "$conf/router.conf"; print -r -- "CCR_PORT=4000" >> "$conf/router.conf"
un
check "stale port does not block uninstall" '[ ! -e "$conf" ]'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
