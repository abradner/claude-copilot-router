#!/bin/zsh -f
# Removes the router (venv, tokens, key, config), its Claude Code profile and the alias.
# An --adopt'ed profile is kept: only the router's keys, links and marker are removed from it.
# Asks first. Never follows links out of the profile (shared skills/CLAUDE.md stay intact).
set -eu
here="${0:A:h}"; source "$here/lib/common.sh"; ccr_load_conf; ccr_validate
ccr_safe_profile "$CCR_PROFILE" || die "refusing to delete $CCR_PROFILE"
[[ $CCR_HOME == "$HOME"/?*/claude-copilot-router ]] || die "refusing to delete $CCR_HOME"
echo "This deletes:"
echo "  $CCR_HOME  (venv, GitHub token, proxy key, config)"
mark=""; [ -f "$CCR_PROFILE/$CCR_MARK" ] && mark="$(<"$CCR_PROFILE/$CCR_MARK")"
if [ "$mark" = adopted ]; then echo "  the router's settings and links in $CCR_PROFILE (adopted: the directory stays)"
elif [ -n "$mark" ]; then echo "  $CCR_PROFILE  (router's Claude Code profile)"; fi
echo "  the '$CCR_ALIAS' alias in ~/.zshrc"
printf 'Type yes to continue: '; read -r a; [ "$a" = yes ] || exit 1
if [ "$mark" = adopted ]; then
  ccr_unlink
  "$(ccr_python)" -I "$CCR_LIB/settings_merge.py" unkit "$CCR_PROFILE/settings.json"
  rm -f -- "$CCR_PROFILE/$CCR_MARK"
elif [ -n "$mark" ]; then
  rm -rf -- "$CCR_PROFILE"
else
  echo "skipping $CCR_PROFILE: no $CCR_MARK marker, so it was not created by this tool"
fi
rm -rf -- "$CCR_HOME"
ccr_drop_alias
echo "Now revoke the GitHub token: github.com > Settings > Applications > Authorized GitHub Apps > GitHub Copilot Plugin."
echo "If you ran /login inside the router profile, delete its extra 'Claude Code-credentials' Keychain item."
