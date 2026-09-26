#!/bin/bash
# Takes the README screenshots from the real app. Used by CI; also works locally.
# Needs screen recording permission for the terminal running it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${APP:-build/Handa.app}"
BIN="$APP/Contents/MacOS/Handa"
OUT="${OUT:-build/screenshots}"
WORK="$(mktemp -d)"
export HANDA_HOME="$WORK/home"
mkdir -p "$OUT"

system_profiler SPDisplaysDataType 2>/dev/null | grep -E "Resolution|UI Looks like" || true

# shot <name> <file or -> [VAR=value …]   (APP_ARGS adds arguments for the app)
shot() {
  local name="$1" file="$2"
  shift 2
  local ready="$WORK/$name.json"
  local args=()
  [ "$file" != "-" ] && args+=("$file")
  # shellcheck disable=SC2206
  local extra=(${APP_ARGS:-})
  # bash 3.2 on macOS treats empty arrays as unset under set -u, hence the ${x+…} dance.
  env HANDA_READY_FILE="$ready" HANDA_WINDOW_SIZE="${SIZE:-1180x760}" "$@" \
    "$BIN" ${args[@]+"${args[@]}"} ${extra[@]+"${extra[@]}"} -ApplePersistenceIgnoreState YES >"$WORK/$name.log" 2>&1 &
  local pid=$!
  for _ in $(seq 1 150); do [ -f "$ready" ] && break; sleep 0.1; done
  if [ ! -f "$ready" ]; then
    echo "No window for $name"; cat "$WORK/$name.log"; kill "$pid" 2>/dev/null || true; return 1
  fi
  # Bring the app to the front so the window is drawn as active.
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" >/dev/null 2>&1 || true
  sleep "${WAIT:-2}"
  local window
  window=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["windowNumber"])' "$ready")
  screencapture -x -l "$window" "$OUT/$name.png"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  echo "Captured $name.png"
}

# A review left over MCP, so the Reviews panel has something real to show.
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"example","version":"1"}}}' \
  "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"add_review\",\"arguments\":{\"path\":\"$PWD/Samples/Sales.csv\",\"title\":\"Sales check\",\"review\":\"**Summary.** 150 sales across three shops from 1 July to 20 August 2026, worth **\$17,134.85** in total. Every *Total* matches *Quantity × Unit Price* and there are no duplicate rows.\\n\\n**Worth a look**\\n\\n1. **Riverside is about \$1,000 behind** the other two shops (\$5,064.65 against roughly \$6,035 each).\\n2. **Rye bread** brings in the most (\$3,014.90), ahead of cinnamon buns (\$2,306.25) and cold brew (\$1,968.00).\\n3. **Cakes are the smallest category** at \$2,155.50. Two lemon tart sales on 27 and 28 July were only 2 units each.\\n\\nNothing looks wrong with the data itself.\"}}}" \
  | "$BIN" mcp >/dev/null 2>&1

shot pdf "Samples/Quarterly Report.pdf" HANDA_SIDEBAR=1
shot word "Samples/Team Meeting.docx"
shot csv "Samples/Sales.csv"
shot markdown "Samples/Opening Checklist.md" HANDA_APPEARANCE=dark
shot code "Samples/inventory.py" HANDA_APPEARANCE=dark
shot image "Samples/Harbor.png"
WAIT=4 shot quicklook "Samples/Budget.xlsx"
WAIT=3 APP_ARGS="-AIEnabled YES" shot ai "Samples/Sales.csv" HANDA_SHOW_REVIEWS=1
APP_ARGS="-AIEnabled YES" shot settings - HANDA_SHOW=settings-ai
# Last, so Recent Files lists the samples opened above.
shot welcome - HANDA_SHOW=welcome

ls -la "$OUT"
