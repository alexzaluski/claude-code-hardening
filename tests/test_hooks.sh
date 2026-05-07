#!/usr/bin/env bash
# Tests for the Bash hook + drift check between newproj-safe heredocs
# and the standalone template files. Run from any directory; resolves
# its own paths.
#
# Cases come from the Phase 9 audit: the four boring positives, plus
# two that previously broke the hook (the /dev/null false positive and
# the regex-pattern false positive).
#
# Exit 0 if all green, 1 if anything failed.
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
        diff <(extract_heredoc "$marker") "$tpl_file" | head -40
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
if [ "$fail" -eq 0 ]; then
    echo "All checks passed."
else
    echo "One or more checks failed."
fi
exit $fail
