#!/bin/zsh -f
# Starts the pinned proxy on 127.0.0.1 only, with an allow-listed environment.
# The key goes file -> env, never argv. Never add --detailed_debug: it logs request headers.
set -eu
here="${0:A:h}"; source "$here/lib/common.sh"; ccr_load_conf; ccr_validate; ccr_scrub
ccr_key_ok
[ -s "$CCR_TOKENS/access-token" ] || die "not signed in; run ./login.sh"
bin="${$(ccr_python):h}/litellm"
[ -x "$bin" ] || die "pinned litellm missing; run ./install.sh"
if /usr/bin/nc -z -G 1 127.0.0.1 "$CCR_PORT" 2>/dev/null; then
  die "port $CCR_PORT already in use; stop that process or reinstall with --port"
fi
export LITELLM_MASTER_KEY="$(<"$CCR_KEY")"
[ -n "$LITELLM_MASTER_KEY" ] || die "empty master key"
cd "$CCR_HOME"   # LiteLLM adds the cwd to sys.path
exec "$bin" --config "$CCR_HOME/config.yaml" --host 127.0.0.1 --port "$CCR_PORT" --num_workers 1
