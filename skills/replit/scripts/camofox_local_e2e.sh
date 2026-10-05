#!/usr/bin/env bash
# camofox_local_e2e.sh — validate @askjo/camofox-browser (REST :9400, own test
# key, loopback only) + @askjo/camofox-browser-mcp (stdio adapter) on THIS box.
# Secret handling: test key is generated into a 600-perm file, injected via
# curl --config; never printed.
set -uo pipefail

SCRATCH=/home/runner/workspace/.hermes/cache/scratch
NODE=/home/runner/workspace/.hermes/tools/node-26.7.0-linux-x64/bin/node
SRV_PKG=/home/runner/workspace/.hermes/tools/node-26.7.0-linux-x64/lib/node_modules/@askjo/camofox-browser
MCP_PKG=/home/runner/workspace/.hermes/tools/node-26.7.0-linux-x64/lib/node_modules/@askjo/camofox-browser-mcp
ROOT=/home/runner/workspace/camofox
KEYF="$SCRATCH/.e2ekey"
PIDF="$SCRATCH/.e2esrv.pid"
LOGF="$SCRATCH/npm-server-9400.log"

pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

# 1. test key (ASCII hex, header-safe)
head -c 32 /dev/urandom | sha256sum | cut -c1-64 > "$KEYF"
chmod 600 "$KEYF"
IFS= read -r KEY < "$KEYF"

# 2. server env — npm-package layout. Engine: explicit CAMOUFOX_INSTALL_DIR
# into the PERSISTENT workspace (home cache is wiped on Replit recreates).
# Do NOT reuse the old repo engine — camoufox-js@0.11.5 must get the manifest
# it fetched, else validateConfig throws "Unknown property navigator.product".
export CAMOFOX_ROOT="$ROOT"
export CAMOUFOX_INSTALL_DIR=/home/runner/workspace/.cache/camoufox/camoufox
export CAMOFOX_STATE_DIR="$ROOT/state"
export CAMOFOX_BIND_HOST=127.0.0.1
export CAMOFOX_ACCESS_KEY="$KEY"
export PATH="$ROOT/venv/bin:$PATH"
export LD_LIBRARY_PATH="$(cat "$ROOT/camofox-browser/LD_LIBRARY_PATH.txt" 2>/dev/null):/home/runner/workspace/.local/lib"

# port: use 9400, shift if occupied
PORT=9400
if env LD_LIBRARY_PATH= curl -s -m 2 "http://127.0.0.1:$PORT/health" >/dev/null; then PORT=9410; fi
export CAMOFOX_PORT=$PORT

# 3. start server
nohup "$NODE" --max-old-space-size=1536 "$SRV_PKG/server.js" > "$LOGF" 2>&1 &
echo $! > "$PIDF"
READY=no
for i in $(seq 1 45); do
  hb=$(env LD_LIBRARY_PATH= curl -s -m 3 "http://127.0.0.1:$PORT/health")
  echo "$hb" | grep -q '"engine"' && { READY=yes; break; }
  sleep 2
done
if [ "$READY" = yes ]; then ok "server up on :$PORT (browserRunning=$(echo "$hb" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("browserRunning"))'))"; else
  bad "server did not become ready"; tail -5 "$LOGF"; fi

cat > "$SCRATCH/.curlcfg" <<EOF
header = "Authorization: Bearer $KEY"
EOF

# 4. REST via curl: negative then positive
code_n=$(env LD_LIBRARY_PATH= curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")
[ "$code_n" = "401" ] && ok "no-key GET / -> 401 (auth enforced)" || bad "no-key GET / -> $code_n (expected 401)"

banner=$(env LD_LIBRARY_PATH= curl -s -m 5 --config "$SCRATCH/.curlcfg" "http://127.0.0.1:$PORT/")
echo "$banner" | grep -qi 'camo' && ok "with-key GET / -> product banner" || bad "with-key GET /: $banner"

tab=$(env LD_LIBRARY_PATH= curl -s -m 120 -X POST --config "$SCRATCH/.curlcfg" \
  -H 'Content-Type: application/json' \
  -d "{\"url\":\"https://example.com\",\"userId\":\"e2e\",\"sessionKey\":\"e2e\"}" \
  "http://127.0.0.1:$PORT/tabs")
TABID=$(echo "$tab" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tabId",""))' 2>/dev/null)
STAT=$(echo "$tab" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("httpStatus",""))' 2>/dev/null)
if [ -n "$TABID" ] && [ "$STAT" = "200" ]; then ok "POST /tabs -> tabId=${TABID%%-*}… httpStatus=200"; else bad "POST /tabs -> ${tab:0:120}"; fi

snap=$(env LD_LIBRARY_PATH= curl -s -m 60 --config "$SCRATCH/.curlcfg" "http://127.0.0.1:$PORT/tabs/$TABID/snapshot?userId=e2e")
echo "$snap" | grep -q "Example Domain" && ok "GET snapshot -> page text present" || bad "snapshot missing content"

ua=$(env LD_LIBRARY_PATH= curl -s -m 30 -X POST --config "$SCRATCH/.curlcfg" -H 'Content-Type: application/json' \
  -d '{"expression":"navigator.userAgent","userId":"e2e"}' "http://127.0.0.1:$PORT/tabs/$TABID/evaluate")
echo "$ua" | grep -q Firefox && ok "evaluate -> Firefox engine" || bad "evaluate -> ${ua:0:100}"

env LD_LIBRARY_PATH= curl -s -m 15 -X DELETE --config "$SCRATCH/.curlcfg" "http://127.0.0.1:$PORT/tabs/$TABID?userId=e2e" | grep -q '"ok":true' \
  && ok "DELETE tab -> ok" || bad "DELETE tab failed"

# 5. MCP adapter (the package Hermes spawns) — stdio handshake against :PORT
ADAPTER="$MCP_PKG/server.mjs"
[ -f "$ADAPTER" ] || ADAPTER="$SRV_PKG/mcp/server.mjs"
SKILL_SCRIPTS=/home/runner/workspace/.hermes/skills/replit/scripts
CAMOFOX_BASE_URL="http://127.0.0.1:$PORT" python3 "$SKILL_SCRIPTS/mcp_stdio_test.py" "$ADAPTER" "$KEYF" "$PORT"
mcp_rc=$?
[ $mcp_rc -eq 0 ] && ok "mcp adapter stdio e2e (tools/list + create/evaluate/close)" || bad "mcp adapter stdio e2e (rc=$mcp_rc)"

# 6. cleanup: kill our server only (exact pid), shred key + curl config
kill "$(cat "$PIDF")" 2>/dev/null && ok "test server stopped" || bad "stop failed"
rm -f "$KEYF" "$SCRATCH/.curlcfg" "$PIDF"
echo "== SUMMARY: $pass passed, $fail failed"
[ $fail -eq 0 ]
