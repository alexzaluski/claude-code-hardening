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
FILE_HOOK="$REPO_ROOT/templates/project/.claude/hooks/deny-outside-project.sh"
NEWPROJ="$REPO_ROOT/newproj-safe"
TPL="$REPO_ROOT/templates/project"

TMPROJ=$(mktemp -d)
trap 'rm -rf "$TMPROJ"' EXIT
echo "hello" > "$TMPROJ/in_project.txt"

# The Bash hook's wrapper rule re-reads the project's own deny list at
# run time (so it can't drift from it), so the fixture project needs a
# real settings.json — otherwise that rule silently no-ops and its
# tests would pass for the wrong reason.
mkdir -p "$TMPROJ/.claude"
cp "$TPL/.claude/settings.json" "$TMPROJ/.claude/settings.json"

export CLAUDE_PROJECT_DIR="$TMPROJ"

fail=0

# run_case <name> <expected-exit> <command> [expected-substring]
#
# The optional fourth argument asserts which rule fired. Several
# commands are blocked by more than one rule, so an exit-code-only
# check can pass for a reason unrelated to what the case is named
# after — and would keep passing if that rule were deleted.
run_case() {
    local name="$1" expect="$2" cmd="$3" expect_msg="${4:-}"
    local payload
    payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$cmd")
    local output actual
    set +e
    output=$(printf '%s' "$payload" | bash "$HOOK" 2>&1)
    actual=$?
    set -e
    if [ "$actual" != "$expect" ]; then
        printf 'FAIL  %s (expected exit=%s, got=%s)\n' "$name" "$expect" "$actual"
        printf '      cmd: %s\n' "$cmd"
        printf '      output: %s\n' "$output"
        fail=1
        return
    fi
    if [ -n "$expect_msg" ] && ! printf '%s' "$output" | grep -qF "$expect_msg"; then
        printf 'FAIL  %s (blocked, but by the wrong rule)\n' "$name"
        printf '      cmd: %s\n' "$cmd"
        printf '      wanted message: %s\n' "$expect_msg"
        printf '      got: %s\n' "$(printf '%s' "$output" | head -1)"
        fail=1
        return
    fi
    printf 'PASS  %s\n' "$name"
}

WRAPPED_DENY="denied command inside a shell wrapper"
OUTSIDE_PATH="references path(s) outside project"

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

# .env guard — mirrors settings.json Read(./**/.env*) for Bash. These
# paths are in-project (or relative), so the boundary scan deliberately
# passes them; the exit=2 comes from the dedicated .env check.
run_case ".env relative read blocked"               2 "cat .env.local"
run_case ".env in nested dir blocked"               2 "cat nested/.env"
run_case "in-project .env still blocked"            2 "cat $TMPROJ/.env"
run_case ".env.example blocked (matches glob)"      2 "cat .env.example"
run_case "foo.env.example readable name allowed"    0 "cat foo.env.example"
run_case "environment substring not matched"        0 "echo environment"

# Phase 16 — the safe-first-word skip used to apply to the whole command
# line, so any command chained after a safe one was never scanned. Found
# while testing the wrapper fix; it predates it and is independent of it.
# Shell operators, redirections and unquoted newlines all start a new
# command, and each has to be judged on its own first word.
run_case "safe first word vouches for chain"        2 "echo one; cat /etc/hosts"
run_case "safe first word vouches across &&"        2 "true && cat /etc/hosts"
run_case "redirect target judged separately"        2 "echo hi > /etc/passwd"
run_case "newline starts a new command"             2 "$(printf 'echo one\ncat /etc/hosts')"
run_case "newline hides a wrapped denial"           2 "$(printf 'echo one\nsh -c \"printenv\"')"
run_case "safe chain stays allowed"                 0 "echo one; echo two"
run_case "newline inside quotes is data"            0 "$(printf "echo 'line one\nline two'")"

# Phase 16 — shell-wrapper re-entry. `zsh -ic '<script>'` used to defeat
# all three rules at once: the script is one quoted token, so its
# embedded operators tripped the REGEX_META skip and the whole thing was
# discarded, while the harness matched its denies on the outer `zsh`.
# First block: the boundary and .env rules must reach inside the wrapper.
run_case "wrapper hides outside path"               2 "zsh -ic 'cat /etc/passwd'"
run_case "wrapper + pipe hides outside path"        2 "zsh -ic 'cat ~/.ssh/id_rsa | head'"
run_case "wrapper hides .env read"                  2 "zsh -ic 'cat .env.local'"
run_case "sh -c hides outside path"                 2 "sh -c 'cat /etc/passwd'"
run_case "nested wrapper hides outside path"        2 "bash -c 'sh -c \"cat /etc/hosts\"'"
run_case "runner prefix hides outside path"         2 "command cat /etc/passwd"

# Second block: denied commands must not be launderable through a
# wrapper. These specs come from the fixture's settings.json, so the
# assertion tracks the deny list rather than restating it.
run_case "wrapper hides denied printenv"            2 "zsh -ic 'printenv'"          "$WRAPPED_DENY"
run_case "wrapper hides denied history"             2 "zsh -ic 'history'"           "$WRAPPED_DENY"
run_case "wrapper hides denied curl"                2 "zsh -ic 'curl example.com'"  "$WRAPPED_DENY"
run_case "wrapper hides denied git push"            2 "zsh -ic 'git push origin main'" "$WRAPPED_DENY"
run_case "wrapper hides denied git reset --hard"    2 "zsh -lc 'git reset --hard'"  "$WRAPPED_DENY"
# `rm -rf ~/` trips the boundary rule first, since `~/` is itself a path
# outside the project. Still blocked, but not by the deny — assert the
# rule that actually fires rather than the one the name suggests.
run_case "wrapper + rm -rf ~/ (boundary rule)"      2 "zsh -lc 'rm -rf ~/'"         "$OUTSIDE_PATH"
run_case "env runner hides denied curl"             2 "env FOO=1 curl example.com"  "$WRAPPED_DENY"
run_case "nested wrapper hides denied printenv"     2 "bash -c 'sh -c \"printenv\"'" "$WRAPPED_DENY"

# Every shell has a "run this string as a command" flag, so every shell
# is a wrapper. One case each, so a future edit to SHELL_WRAPPERS can't
# quietly drop one.
for _sh in sh bash zsh dash ksh ksh93 mksh fish csh tcsh ash pwsh powershell; do
    run_case "$_sh -c hides denied printenv"        2 "$_sh -c 'printenv'"          "$WRAPPED_DENY"
done

# Invocation forms that defeated the first version of the flag search,
# which stopped at the first non-flag argument.
run_case "shell opt before -c"                      2 "bash -o pipefail -c 'printenv'" "$WRAPPED_DENY"
run_case "multi-call binary (busybox sh -c)"        2 "busybox sh -c 'printenv'"    "$WRAPPED_DENY"
run_case "powershell -Command spelling"             2 "pwsh -Command 'printenv'"    "$WRAPPED_DENY"

# A shell named by absolute path is blocked, but by the BOUNDARY rule —
# `/bin/bash` is itself a path outside the project, and rule 1 runs
# first. Asserting the message keeps this honest: it is not evidence
# that unwrapping works, and would pass with unwrapping deleted.
# The bare-name cases above are what cover the wrapper mechanism.
run_case "absolute path to the shell"               2 "/bin/bash -c 'printenv'"     "$OUTSIDE_PATH"
run_case "runner named by absolute path"            2 "/usr/bin/env bash -c 'printenv'" "$OUTSIDE_PATH"

run_case "-c flag on a non-wrapper not a script"    0 "git commit -c HEAD"
run_case "grep -c is not a shell wrapper"           0 "grep -c pattern in_project.txt"

# Third block: the toolchain case the wrapper rule exists to tolerate.
# `zsh -ic` is how an agent reaches an nvm/pyenv-managed binary; the
# rule must not make that unusable, or it becomes the over-restriction
# trap (Lesson 8) and gets switched off wholesale.
run_case "wrapper running project toolchain allowed" 0 "zsh -ic 'npx vitest run'"
run_case "wrapper with operators still allowed"      0 "zsh -ic 'npm run build && npx tsc --noEmit'"
run_case "command -v still allowed"                  0 "command -v node"

# Fail-closed: a settings.json the hook can't parse must block, not
# silently drop the wrapper rule. Silent fail-open is the failure mode
# this profile most wants to avoid (Lesson 3).
cp "$TMPROJ/.claude/settings.json" "$TMPROJ/.claude/settings.json.bak"
echo '{ this is not json' > "$TMPROJ/.claude/settings.json"
run_case "unparseable settings.json fails closed"    2 "zsh -ic 'npx vitest run'"
mv "$TMPROJ/.claude/settings.json.bak" "$TMPROJ/.claude/settings.json"

# File-path hook (deny-outside-project.sh) — same logic for Read,
# Write, Edit, NotebookEdit. Builds a payload with `file_path` rather
# than `command`. Covers the Phase 13 follow-up: closing the
# Read-tool gap that opened when `Read(~/**)` was removed.
run_file_case() {
    local name="$1" expect="$2" path="$3"
    local payload
    payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"file_path":sys.argv[1]}}))' "$path")
    local output actual
    set +e
    output=$(printf '%s' "$payload" | bash "$FILE_HOOK" 2>&1)
    actual=$?
    set -e
    if [ "$actual" = "$expect" ]; then
        printf 'PASS  %s\n' "$name"
    else
        printf 'FAIL  %s (expected exit=%s, got=%s)\n' "$name" "$expect" "$actual"
        printf '      path: %s\n' "$path"
        printf '      output: %s\n' "$output"
        fail=1
    fi
}
echo
echo "File-path hook behavior (Read/Write/Edit/NotebookEdit):"
run_file_case "in-project path allowed"             0 "$TMPROJ/in_project.txt"
run_file_case "outside-project absolute path blocked" 2 "/etc/hosts"
run_file_case "outside-project home path blocked"   2 "$HOME/.ssh/config"

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
    'Bash(git clean:*)'
    'Bash(git restore:*)'
    'Bash(git checkout --:*)'
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
