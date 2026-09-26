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

# Prints the newest crash report macOS wrote for Handa during this run, if there is one.
touch "$WORK/started"
crash_report() {
  local report=""
  for _ in $(seq 1 20); do
    report=$(find "$HOME/Library/Logs/DiagnosticReports" -name 'Handa*' -newer "$WORK/started" 2>/dev/null | sort | tail -1)
    [ -n "$report" ] && break
    sleep 0.5
  done
  if [ -z "$report" ]; then echo "(no crash report)"; return; fi
  echo "--- crash report $(basename "$report") ---"
  python3 - "$report" <<'PY'
import json, sys
text = open(sys.argv[1]).read()
try:
    report = json.loads(text.partition("\n")[2])
except ValueError:
    print(text[:6000])
    sys.exit()
print("exception:", json.dumps(report.get("exception")))
for key in ("asi", "ktriageinfo"):
    if key in report:
        print(key + ":", json.dumps(report[key])[:3000])
images = report.get("usedImages", [])
def show(frames):
    for frame in frames[:40]:
        index = frame.get("imageIndex")
        image = images[index].get("name", "?") if index is not None and index < len(images) else "?"
        print(f"  {image:30} {frame.get('symbol', hex(frame.get('imageOffset', 0)))}")
if "lastExceptionBacktrace" in report:
    print("last exception backtrace:")
    show(report["lastExceptionBacktrace"])
for thread in report.get("threads", []):
    if thread.get("triggered"):
        print("crashed thread:")
        show(thread.get("frames", []))
PY
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
    crash_report
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
echo "Opening a file while Handa is already running (best of two):"
samples=""
for f in "Quarterly Report.pdf" "Team Meeting.docx" "Sales.csv" "Opening Checklist.md" "inventory.py" "recipes.json" "Harbor.png" "Budget.xlsx"; do
  samples="$samples:$PWD/Samples/$f"
done
samples="${samples#:}"
HANDA_READY_FILE="$WORK/bench-ready.json" HANDA_BENCH_FILES="$samples:$samples" HANDA_BENCH_RESULT="$WORK/bench.json" \
  "$BIN" "$WORK/notes.txt" -ApplePersistenceIgnoreState YES >"$WORK/app.log" 2>&1 &
pid=$!
for _ in $(seq 1 600); do alive "$pid" || break; sleep 0.1; done
if alive "$pid"; then
  fail "warm open benchmark didn't finish"
  diagnose "$pid" "benchmark"
fi
wait "$pid" 2>/dev/null || true
if [ -f "$WORK/bench.json" ]; then
  python3 - "$WORK/bench.json" <<'PY' | tee "$WORK/warm-open.txt"
import json, sys
best = {}
for entry in json.load(open(sys.argv[1])):
    key = (entry["file"], entry["kind"])
    best[key] = min(best.get(key, 1e9), entry["milliseconds"])
for (name, kind), ms in best.items():
    print(f"{name:<24} {kind:<10} {ms:6.1f} ms")
PY
  grep -q failed "$WORK/warm-open.txt" && fail "a file failed to open in the running app"
else
  fail "warm open benchmark wrote no results"
  cat "$WORK/app.log"
  crash_report
fi

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
echo "Default app:"
# Asks Launch Services which app a double-click would use.
cat > "$WORK/opens-with.js" <<'JS'
ObjC.import("AppKit")
function run(argv) {
  const app = $.NSWorkspace.sharedWorkspace.URLForApplicationToOpenURL($.NSURL.fileURLWithPath(argv[0]))
  return app.isNil() ? "nothing" : ObjC.unwrap($.NSBundle.bundleWithURL(app).bundleIdentifier)
}
JS
asks_to_confirm() { sw_vers -productVersion | awk -F. '{ if ($1 > 26 || ($1 == 26 && $2 >= 4)) print "yes"; else print "no" }'; }
if [ "$(asks_to_confirm)" = no ]; then
  if "$BIN" make-default --all >"$WORK/make-default.log" 2>&1; then
    for f in "Quarterly Report.pdf" "Team Meeting.docx" "Sales.csv" "Opening Checklist.md" "inventory.py" "Harbor.png" "recipes.json"; do
      owner=$(osascript -l JavaScript "$WORK/opens-with.js" "$PWD/Samples/$f" 2>&1 || true)
      [ "$owner" = "io.github.michael-duck.handa" ] || fail "$f opens with $owner, not Handa"
    done
    echo "make-default: ok, $(grep -c ': Handa' "$WORK/make-default.log") file types"
  else
    cat "$WORK/make-default.log"
    fail "make-default"
  fi
else
  # macOS 26.4 and later ask before Handa takes over a file type from another app. Answer "Use
  # Handa" the way a person would, through System Events, and check the change takes effect.
  cat > "$WORK/confirm.js" <<'JS'
function run() {
  const agent = Application("System Events").processes.byName("CoreServicesUIAgent")
  try {
    for (const window of agent.windows()) {
      const text = window.staticTexts.value().join(" ")
      for (const button of window.buttons()) {
        if (button.name().startsWith("Use") && button.name().includes("Handa")) {
          button.click()
          return "confirmed: " + text
        }
      }
    }
  } catch (error) { return "error: " + error }
  return "waiting"
}
JS
  printf 'plain text\n' > "$WORK/plain.txt"
  "$BIN" make-default >"$WORK/make-default.log" 2>&1 &
  pid=$!
  confirmed=0
  for _ in $(seq 1 120); do
    alive "$pid" || break
    answer=$(osascript -l JavaScript "$WORK/confirm.js" 2>&1 || true)
    case "$answer" in
      confirmed*)
        confirmed=$((confirmed + 1))
        if [ "$confirmed" -eq 1 ]; then echo "  macOS asked: ${answer#confirmed: }"; fi
        ;;
      error*) echo "  $answer" ;;
    esac
    sleep 0.5
  done
  if alive "$pid"; then
    kill "$pid" 2>/dev/null || true
    fail "make-default was still waiting after $confirmed confirmation(s)"
  fi
  wait "$pid" 2>/dev/null || true
  cat "$WORK/make-default.log"
  [ "$confirmed" -gt 0 ] || fail "macOS never asked to confirm"
  for f in "Samples/Quarterly Report.pdf" "Samples/Team Meeting.docx" "Samples/Sales.csv" "Samples/Opening Checklist.md" "$WORK/plain.txt"; do
    case "$f" in /*) path="$f" ;; *) path="$PWD/$f" ;; esac
    owner=$(osascript -l JavaScript "$WORK/opens-with.js" "$path" 2>&1 || true)
    [ "$owner" = "io.github.michael-duck.handa" ] || fail "$(basename "$f") opens with $owner, not Handa"
  done
  echo "make-default: ok after confirming $confirmed file types"
fi

{ echo "Launch to first window:"; cat "$RESULTS"; echo; echo "Open while running:"; cat "$WORK/warm-open.txt"; } > build/launch-times.txt 2>/dev/null || true

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All smoke tests passed."
