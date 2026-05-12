#!/usr/bin/env bash
# Three layers of checks for the hardening templates:
#
#   1. Behaviour — the Bash hook does what it should on a handful of
#      representative commands (boring positives, plus the false-positive
#      cases that have previously broken the hook, plus regression
#      tests for the Phase 11 no-whitespace-operator bypass).
#   2. Drift — the heredoc bodies inside `newproj-safe` match the
#      standalone template files byte-for-byte. Catches "edited one,
#      forgot to update the other."
#   3. Invariants — design decisions we don't want silently reverted:
#      JSON validity, hook executability, the audit-driven required
#      patterns, and the forbidden patterns we removed on purpose.
#
# Run from any directory; resolves its own paths. Exit 0 if all
# green, 1 if anything failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/templates/project/.claude/hooks/deny-bash-outside-project.sh"
NEWPROJ="$REPO_ROOT/newproj-safe"
TPL="$REPO_ROOT/templates/project"

TMPROJ=$(mktemp -d)
trap 'rm -rf "$TMPROJ"' EXIT
echo "hello" > "$TMPROJ/in_project.txt"

export CLAUDE_PROJECT_DIR="$TMPROJ"

fail=0

run_case() {
    local name="$1" expect="$2" cmd="$3"
    local payload
    payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$cmd")
    local output actual
    set +e
    output=$(printf '%s' "$payload" | bash "$HOOK" 2>&1)
    actual=$?
    set -e
    if [ "$actual" = "$expect" ]; then
        printf 'PASS  %s\n' "$name"
    else
        printf 'FAIL  %s (expected exit=%s, got=%s)\n' "$name" "$expect" "$actual"
        printf '      cmd: %s\n' "$cmd"
        printf '      output: %s\n' "$output"
        fail=1
    fi
}

echo "Bash hook behavior:"
run_case "kernel device pass-through (/dev/null)"  0 "echo hi 2>/dev/null"
run_case "regex with alternation, in-project file" 0 "grep -E 'a|b' $TMPROJ/in_project.txt"
run_case "regex with character class"              0 "grep -E '[abc]' $TMPROJ/in_project.txt"
run_case "in-project read allowed"                 0 "cat $TMPROJ/in_project.txt"
run_case "outside-project read blocked"            2 "cat /etc/hosts"
run_case "regex arg + outside path: blocks path"   2 "grep -E 'a|b' /etc/hosts"
run_case "no-space pipe bypass blocked"             2 "cat /etc/passwd|head"
run_case "no-space semicolon bypass blocked"        2 "cat /etc/shadow;cat /etc/passwd"
run_case "no-space redirect bypass blocked"         2 "cat </etc/hosts"
run_case "subshell paren bypass blocked"            2 "(cat /etc/hosts)"

# Drift check: heredoc bodies inside newproj-safe must match the
# standalone template files. Markers were chosen unique per file so
# this awk extraction is unambiguous.
extract_heredoc() {
    local marker="$1"
    awk -v m="$marker" '
        index($0, "<<\x27" m "\x27") { capture=1; next }
        capture && $0 == m { exit }
        capture { print }
    ' "$NEWPROJ"
}

check_drift() {
    local name="$1" marker="$2" tpl_file="$3"
    if diff -q <(extract_heredoc "$marker") "$tpl_file" >/dev/null 2>&1; then
        printf 'PASS  drift: %s\n' "$name"
    else
        printf 'FAIL  drift: %s (heredoc %s vs %s)\n' "$name" "$marker" "$tpl_file"
        diff <(extract_heredoc "$marker") "$tpl_file" | head -40 || true
        fail=1
    fi
}

echo
echo "Heredoc / template drift:"
check_drift ".gitignore"            "GITIGNORE_EOF"  "$TPL/.gitignore"
check_drift ".claude/settings.json" "SETTINGS_EOF"   "$TPL/.claude/settings.json"
check_drift "deny-outside-project"  "WRITE_HOOK_EOF" "$TPL/.claude/hooks/deny-outside-project.sh"
check_drift "deny-bash-outside-pj"  "BASH_HOOK_EOF"  "$TPL/.claude/hooks/deny-bash-outside-project.sh"
check_drift ".githooks/pre-commit"  "PRECOMMIT_EOF"  "$TPL/.githooks/pre-commit"
check_drift "CLAUDE.md"             "CLAUDEMD_EOF"   "$TPL/CLAUDE.md"

echo
echo "Invariants:"

# JSON validity for every settings.json we ship.
for f in "$TPL/.claude/settings.json" "$REPO_ROOT/templates/global/settings.json"; do
    if python3 -m json.tool < "$f" >/dev/null 2>&1; then
        printf 'PASS  json valid: %s\n' "${f#$REPO_ROOT/}"
    else
        printf 'FAIL  json invalid: %s\n' "${f#$REPO_ROOT/}"
        fail=1
    fi
done

# Hook scripts executable. Lost +x silently turns the hook into a
# no-op (the harness logs an error but doesn't block); catch that.
for h in "$TPL/.claude/hooks"/*.sh; do
    if [ -x "$h" ]; then
        printf 'PASS  executable: %s\n' "${h#$REPO_ROOT/}"
    else
        printf 'FAIL  not executable: %s\n' "${h#$REPO_ROOT/}"
        fail=1
    fi
done

# Forbidden patterns — entries we have deliberately removed and never
# want to see come back. Each row pairs the pattern with the reason,
# so future-you understands why this assertion exists.
forbidden=(
    'Read(~/**)|Phase 13: over-matches project files when project is under ~'
)
for entry in "${forbidden[@]}"; do
    pat="${entry%%|*}"
    why="${entry##*|}"
    if grep -qF "\"$pat\"" "$TPL/.claude/settings.json"; then
        printf 'FAIL  forbidden pattern present: %s  (reason: %s)\n' "$pat" "$why"
        fail=1
    else
        printf 'PASS  forbidden pattern absent: %s\n' "$pat"
    fi
done

# Required patterns — audit-driven additions that would be load-bearing
# losses if silently dropped. One representative entry per category,
# not the full enumeration.
required=(
    'Bash(history:*)'
    'Bash(git remote add:*)'
    'Bash(git remote set-url:*)'
    'Read(./**/*.p12)'
    'Read(./**/id_rsa*)'
)
for pat in "${required[@]}"; do
    if grep -qF "\"$pat\"" "$TPL/.claude/settings.json"; then
        printf 'PASS  required pattern present: %s\n' "$pat"
    else
        printf 'FAIL  required pattern missing: %s\n' "$pat"
        fail=1
    fi
done

echo
if [ "$fail" -eq 0 ]; then
    echo "All checks passed."
else
    echo "One or more checks failed."
fi
exit $fail
