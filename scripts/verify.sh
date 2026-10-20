#!/bin/zsh
# Checks the app's numbers against an independent Python implementation and checks that reading
# transcripts piece by piece gives the same result as reading them in one pass. Runs on a frozen
# APFS clone of the transcripts, so sessions in progress can't skew the comparison.
set -euo pipefail

cd "$(dirname "$0")/.."
SOURCE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
WORK=$(mktemp -d /tmp/swiftusage-verify.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

swift build -c release --product swiftusage >/dev/null
BIN="$(swift build -c release --show-bin-path)/swiftusage"

mkdir -p "$WORK/snapshot"
cp -cRH "$SOURCE" "$WORK/snapshot/projects"
echo "Snapshot: $(find "$WORK/snapshot/projects" -name '*.jsonl' | wc -l | tr -d ' ') transcripts"

CLAUDE_CONFIG_DIR="$WORK/snapshot" "$BIN" --dump --provider claude --cold --json > "$WORK/app.json"
python3 -I scripts/verify/reference.py "$WORK/snapshot/projects" > "$WORK/reference.json"
echo "\nApp vs independent reference:"
python3 -I scripts/verify/compare.py "$WORK/app.json" "$WORK/reference.json"

"$BIN" --replay "$WORK/snapshot/projects" "$WORK/replay" "$WORK/replay" >/dev/null
echo "\nRead in random chunks vs reference:"
python3 -I scripts/verify/compare.py "$WORK/replay-incremental.json" "$WORK/reference.json" | grep -v '^[ {}]'
