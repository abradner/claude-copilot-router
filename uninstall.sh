#!/bin/zsh -f
# Removes the router (venv, tokens, key, config), its Claude Code profile and the alias.
# An --adopt'ed profile is kept: only the router's keys, links and marker are removed from it,
# and the settings the router replaced are put back.
# Asks first. Never follows links out of the profile (shared skills/CLAUDE.md stay intact), and
# never writes through a symlinked settings.json.
set -eu
here="${0:A:h}"; source "$here/lib/common.sh"; ccr_load_conf
# Only the paths matter here: a stale port or model in router.conf must not block uninstall.
[ ! -L "${CCR_PROFILE:a}" ] || die "$CCR_PROFILE is a symlink; remove the link by hand, then rerun"
CCR_PROFILE="${CCR_PROFILE:A}"
ccr_validate_profile

mark="" profile_action=skip why="no $CCR_MARK marker, so it was not created by this tool"
if [ -e "$CCR_PROFILE/$CCR_MARK" ] || [ -L "$CCR_PROFILE/$CCR_MARK" ]; then
  if [ -f "$CCR_PROFILE/$CCR_MARK" ] && [ ! -L "$CCR_PROFILE/$CCR_MARK" ]; then
    mark="$(<"$CCR_PROFILE/$CCR_MARK")"
  fi
  case $mark in
    created) profile_action=delete ;;
    adopted) profile_action=clean; py="$(ccr_merge_python)"
      # stop before the prompt, not halfway, if settings.json cannot be edited safely
      "$py" -I "$CCR_LIB/settings_merge.py" check "$CCR_PROFILE/settings.json" ;;
    *) why="its $CCR_MARK marker holds '$mark', not created or adopted; inspect it and remove it by hand" ;;
  esac
fi

echo "This deletes:"
echo "  $CCR_HOME  (venv, GitHub token, proxy key, config)"
case $profile_action in
  delete) echo "  $CCR_PROFILE  (router's Claude Code profile)" ;;
  clean) echo "  the router's settings and links in $CCR_PROFILE (adopted: the directory stays)" ;;
  skip) echo "  nothing in $CCR_PROFILE: $why" ;;
esac
echo "  the claude-copilot-router alias in ~/.zshrc"
printf 'Type yes to continue: '; read -r a; [ "$a" = yes ] || exit 1

case $profile_action in
  delete) rm -rf -- "$CCR_PROFILE" ;;
  clean)
    ccr_unlink
    "$py" -I "$CCR_LIB/settings_merge.py" unkit "$CCR_PROFILE/settings.json" "$CCR_PROFILE/.ccr-kit-prev.json" "$CCR_KEY"
    rm -f -- "$CCR_PROFILE/$CCR_MARK" ;;
  skip) echo "skipped $CCR_PROFILE: $why" ;;
esac
rm -rf -- "$CCR_HOME"
ccr_drop_alias
echo "Now revoke the GitHub token: github.com > Settings > Applications > Authorized GitHub Apps > GitHub Copilot Plugin."
echo "If you ran /login inside the router profile, delete its extra 'Claude Code-credentials' Keychain item."
