#!/usr/bin/env bash
# PreToolUse hook: block Write/Edit/NotebookEdit whose target file_path
# falls outside $CLAUDE_PROJECT_DIR.
set -euo pipefail

command -v python3 >/dev/null 2>&1 || {
    echo "BLOCKED by deny-outside-project.sh: python3 not on PATH" >&2
    echo "This hook needs python3; install it or remove the hook entry from .claude/settings.json." >&2
    exit 2
}

payload=$(cat)

file_path=$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ti = d.get("tool_input") or {}
print(ti.get("file_path") or ti.get("notebook_path") or "")
')

[ -z "$file_path" ] && exit 0

abs=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$file_path")
project="${CLAUDE_PROJECT_DIR:-$PWD}"
project_real=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$project")

case "$abs" in
  "$project_real"/*|"$project_real") exit 0 ;;
  *)
    echo "BLOCKED by deny-outside-project.sh: write target" >&2
    echo "  $abs" >&2
    echo "is outside project directory" >&2
    echo "  $project_real" >&2
    echo "Project scope rule (CLAUDE.md) forbids outside-project writes." >&2
    exit 2
  ;;
esac
