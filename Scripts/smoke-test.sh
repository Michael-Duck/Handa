#!/bin/bash
# Launches the built app with every sample file and checks it opens a window, then exercises
# the command line tools and the MCP server. Prints how long each launch took.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/Handa.app}"
BIN="$APP/Contents/MacOS/Handa"
WORK="$(mktemp -d)"
export HANDA_HOME="$WORK/home"
RESULTS="$WORK/launch-times.txt"
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

# True while the process is running (a zombie counts as finished).
alive() { local state; state=$(ps -o stat= -p "$1" 2>/dev/null); [ -n "$state" ] && [ "${state#Z}" = "$state" ]; }

# Prints where a stuck app is spending its time, then kills it.
diagnose() {
  echo "--- $2: stack sample ---"
  sample "$1" 1 -file "$WORK/sample.txt" >/dev/null 2>&1 && sed -n '1,/Binary Images/p' "$WORK/sample.txt" | head -120
  echo "--- app output ---"
  cat "$WORK/app.log"
  kill -9 "$1" 2>/dev/null || true
}

# A few extra files the samples don't cover.
head -c 4096 /dev/urandom > "$WORK/random.bin"
printf 'plain text\nwith two lines\n' > "$WORK/notes.txt"
printf '{\\rtf1\\ansi{\\fonttbl\\f0 Helvetica;}\\f0\\b Bold\\b0  and plain.}' > "$WORK/letter.rtf"

launch() {
  local file="$1" expect="$2" ready="$WORK/ready.json"
  rm -f "$ready"
  HANDA_READY_FILE="$ready" HANDA_QUIT_AFTER=0.5 "$BIN" "$file" -ApplePersistenceIgnoreState YES >"$WORK/app.log" 2>&1 &
  local pid=$!
  for _ in $(seq 1 150); do
    [ -f "$ready" ] && break
    alive "$pid" || break
    sleep 0.1
  done
  if [ ! -f "$ready" ]; then
    fail "$(basename "$file"): no window appeared"
    if alive "$pid"; then diagnose "$pid" "$(basename "$file")"; else cat "$WORK/app.log"; fi
    wait "$pid" 2>/dev/null || true
    return
  fi
  local kind ms
  kind=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kind"])' "$ready")
  ms=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["milliseconds"])' "$ready")
  for _ in $(seq 1 100); do alive "$pid" || break; sleep 0.1; done
  if alive "$pid"; then
    fail "$(basename "$file"): the app didn't quit"
    diagnose "$pid" "$(basename "$file")"
    wait "$pid" 2>/dev/null || true
  elif ! wait "$pid"; then
    fail "$(basename "$file"): app exited with an error"
    cat "$WORK/app.log"
  fi
  if [ "$kind" != "$expect" ]; then fail "$(basename "$file"): opened as $kind, expected $expect"; fi
  printf '%-24s %-10s %6s ms\n' "$(basename "$file")" "$kind" "$ms" | tee -a "$RESULTS"
  python3 -c 'import json,sys; p=json.load(open(sys.argv[1])).get("phases",{}); print("    " + "  ".join(f"{k} {v:g}" for k,v in sorted(p.items(), key=lambda x: x[1])))' "$ready"
}

# The first launch of a new build pays one-off costs (code signature checks, Launch Services
# registration, font caches), so warm up once and then measure.
RESULTS=/dev/null launch "$WORK/notes.txt" text >/dev/null

echo "Launch to first window:"
launch "Samples/Quarterly Report.pdf" pdf
launch "Samples/Team Meeting.docx" richText
launch "Samples/Sales.csv" table
launch "Samples/Opening Checklist.md" markdown
launch "Samples/inventory.py" text
launch "Samples/recipes.json" text
launch "Samples/Harbor.png" image
launch "Samples/Budget.xlsx" quickLook
launch "$WORK/random.bin" binary
launch "$WORK/notes.txt" text
launch "$WORK/letter.rtf" richText

echo
echo "Command line:"
"$BIN" --version
"$BIN" extract "Samples/Team Meeting.docx" | grep -q "Action items" || fail "extract docx"
"$BIN" extract "Samples/Quarterly Report.pdf" | grep -q "Third Quarter Report" || fail "extract pdf"
"$BIN" extract "Samples/Sales.csv" | grep -q "Cinnamon bun" || fail "extract csv"
"$BIN" extract "$WORK/letter.rtf" | grep -q "Bold and plain" || fail "extract rtf"
if "$BIN" extract "$WORK/does-not-exist.pdf" 2>/dev/null; then fail "extract should fail for a missing file"; fi
echo "extract: ok"

echo
echo "MCP server:"
mcp_out=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke-test","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"read_file\",\"arguments\":{\"path\":\"$PWD/Samples/Team Meeting.docx\"}}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"add_review\",\"arguments\":{\"path\":\"$PWD/Samples/Sales.csv\",\"review\":\"Totals look right.\",\"title\":\"Smoke test\"}}}" \
  | "$BIN" mcp 2>/dev/null)
echo "$mcp_out" | python3 -c '
import json, sys
lines = [json.loads(line) for line in sys.stdin if line.strip()]
assert [m["id"] for m in lines] == [1, 2, 3, 4], lines
assert lines[0]["result"]["serverInfo"]["name"] == "handa"
tools = [t["name"] for t in lines[1]["result"]["tools"]]
assert tools == ["list_open_files", "get_active_file", "read_file", "open_file", "add_review"], tools
assert "Action items" in lines[2]["result"]["content"][0]["text"]
assert "Saved" in lines[3]["result"]["content"][0]["text"]
print("mcp: ok,", len(tools), "tools")
' || fail "mcp"
ls "$HANDA_HOME/Reviews/"*.json >/dev/null 2>&1 || fail "mcp review was not stored"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All smoke tests passed."
cp "$RESULTS" build/launch-times.txt 2>/dev/null || true
