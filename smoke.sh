#!/bin/zsh -f
# Auth check, hello, streaming, tool use and model check against the running proxy.
# Usage: ./smoke.sh [copilot-model-id]   (default: your main model)
set -u
here="${0:A:h}"; source "$here/lib/common.sh"; ccr_load_conf; ccr_validate
[ -s "$CCR_HDR" ] || die "missing $CCR_HDR; run ./install.sh"
url="http://127.0.0.1:$CCR_PORT"
case $CCR_MAIN in sonnet) def=$CCR_SONNET ;; opus) def=$CCR_OPUS ;; *) def=$CCR_HAIKU ;; esac
model="$(ccr_cc_name "${1:-$def}")"
[[ $model =~ '^claude-[a-z0-9.-]+$' ]] || die "bad model id: $model"
pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }
post() { curl -q -sS --noproxy '*' --max-time 120 "$url/v1/messages" -H @"$CCR_HDR" \
  -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' "$@"; }

code="$(curl -q -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 10 "$url/v1/messages" -H 'content-type: application/json' -d '{}')"
if [ "$code" = 401 ]; then ok "auth enforced (no key -> 401)"; else bad "proxy answered $code without a key"; fi

resp="$(post -D - -d "{\"model\":\"$model\",\"max_tokens\":64,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word: pong\"}]}")"
if print -r -- "$resp" | grep -q '"type": *"message"'; then ok "hello"; else bad "hello: $(print -r -- "$resp" | tail -1)"; fi
echo "  body model: $(print -r -- "$resp" | sed -n 's/.*"model": *"\([^"]*\)".*/\1/p' | head -1)"
print -r -- "$resp" | grep -i '^x-litellm-model' | sed 's/^/  /'

sout="$(post -N -d "{\"model\":\"$model\",\"max_tokens\":64,\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"Count 1 to 5\"}]}")"
if print -r -- "$sout" | grep -q 'message_start' && print -r -- "$sout" | grep -q 'message_stop'; then ok "streaming"; else bad "streaming: $(print -r -- "$sout" | head -5)"; fi

tout="$(post -d "{\"model\":\"$model\",\"max_tokens\":256,\"tools\":[{\"name\":\"get_time\",\"description\":\"Get current time\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"tz\":{\"type\":\"string\"}},\"required\":[\"tz\"]}}],\"messages\":[{\"role\":\"user\",\"content\":\"What time is it in UTC? Use the tool.\"}]}")"
if print -r -- "$tout" | grep -q '"stop_reason": *"tool_use"'; then ok "tool use"; else bad "tool use: $tout"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
