#!/bin/zsh -f
# Lists the Claude model ids your Copilot seat can use, with limits, straight from Copilot.
# Use them with: ./install.sh --sonnet ID --opus ID --haiku ID
set -eu
here="${0:A:h}"; source "$here/lib/common.sh"; ccr_load_conf; ccr_validate; ccr_scrub
py="$(ccr_python)"
"$py" -I - <<'PY'
import httpx
from litellm.llms.github_copilot.authenticator import Authenticator
from litellm.llms.github_copilot.common_utils import get_copilot_default_headers, DEFAULT_GITHUB_COPILOT_API_BASE
a = Authenticator()
key = a.get_api_key()  # first: refreshes api-key.json, which carries the account's endpoint
base = (a.get_api_base() or DEFAULT_GITHUB_COPILOT_API_BASE).rstrip("/")
r = httpx.get(f"{base}/models", headers=get_copilot_default_headers(key), timeout=30)
r.raise_for_status()
for m in r.json().get("data", []):
    mid = m.get("id", "")
    if "claude" not in mid:
        continue
    lim = m.get("capabilities", {}).get("limits", {})
    eps = ",".join(m.get("supported_endpoints", []) or [])
    print(f"{mid:32} ctx={lim.get('max_context_window_tokens')} out={lim.get('max_output_tokens')} policy={m.get('policy', {}).get('state')} endpoints={eps}")
PY
chmod 600 "$CCR_TOKENS"/* 2>/dev/null || true
