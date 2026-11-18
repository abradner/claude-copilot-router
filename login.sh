#!/bin/zsh -f
# One-time GitHub device-flow sign-in, outside the proxy (LiteLLM refuses it inside the proxy).
# Prints a URL and a code: enter it within a minute (a new code follows if it times out) in a
# browser signed in to the GitHub account that holds your Copilot seat. Authorize SSO if asked.
set -eu
here="${0:A:h}"; source "$here/lib/common.sh"; ccr_load_conf; ccr_validate; ccr_scrub
py="$(ccr_python)"
if [ -s "$CCR_TOKENS/access-token" ]; then
  echo "Already signed in. To switch account: rm $CCR_TOKENS/* and rerun."
  exit 0
fi
"$py" -I -c 'from litellm.llms.github_copilot.authenticator import Authenticator as A; A().get_access_token(); print("signed in")'
chmod 600 "$CCR_TOKENS"/* 2>/dev/null || true
