#!/usr/bin/env bash
# PreToolUse hook for Bash: block commands whose path arguments resolve
# outside $CLAUDE_PROJECT_DIR. Enforces the project boundary for any
# Bash call that reads or writes file content (`cat`, `grep`, `find`,
# `python3 -c 'open(...)'`, etc.). The Read tool has narrower
# pattern-based denies in settings.json; this hook is what stops
# subprocess-mediated bypasses of those.
#
# Heuristic: scan the command for path-looking tokens (start with /, ~,
# or ./), resolve each to a realpath, reject if any are outside project.
#
# KNOWN LIMITS (defense-in-depth, not a fortress):
#   - Misses paths inside command substitutions: `cat $(cmd)`
#   - Misses paths inside script string literals:
#     `python3 -c 'open("/etc/hosts")'`
#   - Misses paths constructed via env vars set in the same command
#   - REGEX PATTERN ARGUMENTS: tokens containing regex metacharacters
#     (|, (, ), [, ], ^, $, \, +) are treated as patterns, not paths,
#     so a `/`-prefixed substring inside `grep -E '...|/private/tmp|...'`
#     does not trip the heuristic. Trade-off: a constructed path that
#     happens to contain one of those chars (e.g. `/some/$VAR/file`)
#     is also skipped — same category as the env-var limit above.
#   - SYMLINKS: paths are realpath-resolved before the in/out check.
#     A symlink inside the project pointing outside resolves outside
#     and is correctly blocked. The flip side: a project-internal
#     symlink to a vendored or sibling-workspace directory (e.g. a
#     `node_modules` link that points outside the tree) will also be
#     blocked. Inbound symlinks like `/tmp/foo -> <project>/secret`
#     resolve back inside and pass — not exploitable here, since
#     anything able to plant such a symlink could read the target
#     directly, but worth noting.
#   CLAUDE.md still asks the model to respect the spirit of the rule
#   for cases this script can't see into.
#
# SECOND RULE — .env PATHS:
#   settings.json denies `Read(./.env*)` and `Read(./**/.env*)`, but those
#   bind only the Read tool; a subprocess like `cat .env` or
#   `grep KEY .env.local` reaches the same files unimpeded. The check at the
#   bottom of this file mirrors those globs for Bash, so the deny is
#   mechanical rather than a matter of the model honoring CLAUDE.md.
#
#   Heuristic: reject any argument with a path component starting with `.env`.
#   Matches the Read globs exactly, so committed `.env*` templates are blocked
#   too; a template meant to stay readable is named so it does not start with
#   `.env` (e.g. `foo.env.example`).
#
#   Blocks path REFERENCES, not just reads: cheaper than enumerating which
#   subcommands read content. A script that loads a .env internally is
#   unaffected — the path never appears on the command line.

set -euo pipefail

command -v python3 >/dev/null 2>&1 || {
    echo "BLOCKED by deny-bash-outside-project.sh: python3 not on PATH" >&2
    echo "This hook needs python3; install it or remove the hook entry from .claude/settings.json." >&2
    exit 2
}

payload=$(cat)

cmd=$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(d.get("tool_input", {}).get("command", ""))
')

[ -z "$cmd" ] && exit 0

project="${CLAUDE_PROJECT_DIR:-$PWD}"
project_real=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$project")

violations=$(python3 - "$cmd" "$project_real" <<'PY'
import os, re, shlex, sys
cmd, project = sys.argv[1], sys.argv[2]

# Allow-list: commands whose first word is one of these get pass-through.
# These don't read file content; they manipulate paths or report metadata.
SAFE_FIRST_WORDS = {
    "realpath", "basename", "dirname",
    "which", "type", "command",
    "echo", "printf", "true", "false", "test", "[",
}

# Strip leading env assignments (FOO=bar baz=qux cmd ...) to find the
# actual command name.
work = cmd.strip()
first = ""
while work:
    head = work.split(None, 1)[0]
    if "=" in head and not head.startswith("="):
        rest = work.split(None, 1)
        work = rest[1] if len(rest) > 1 else ""
        continue
    first = head
    break

if first in SAFE_FIRST_WORDS:
    sys.exit(0)

# Regex / glob metacharacters that real filesystem paths almost never
# contain. If a whole shell argument contains any of these, the
# argument is treated as a pattern (regex / glob / alternation), not as
# something that bears a file path, and is skipped before path
# extraction. Catches the common false positive where a `grep -E`
# pattern contains a `/`-prefixed substring.
REGEX_META = set("|()[]^$\\+")

# Shell-tokenize first. `punctuation_chars=True` splits shell operators
# (`|`, `;`, `&`, `<`, `>`, `(`, `)`) into their own tokens even when
# they're not surrounded by whitespace, so `cat /etc/passwd|head`
# tokenizes to ['cat', '/etc/passwd', '|', 'head'] rather than
# ['cat', '/etc/passwd|head'] — closing the no-space-pipe bypass that
# previously let the REGEX_META skip drop the whole argument.
# Quoted regex args (e.g. `grep -E 'a|b'`) stay grouped, so the
# metacharacter skip below still applies to them.
# On malformed quoting, fall back to scanning the raw command — the
# strict path; better than silently passing.
try:
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    shell_args = list(lex)
except ValueError:
    shell_args = [cmd]

# Find tokens that look like paths: start with /, ~, or ./, at a word
# boundary (start of string or preceded by whitespace / shell separator).
pattern = re.compile(
    r"(?:(?<=^)|(?<=[\s=:|;<>&(]))((?:~|/|\./)[^\s'\"<>|;&)]+)"
)
tokens = []
for arg in shell_args:
    if any(c in arg for c in REGEX_META):
        continue
    tokens.extend(pattern.findall(arg))

# Allow-list: kernel devices and special files. Not real filesystem reads;
# reading/writing them leaks nothing about project layout. Common in
# `2>/dev/null`, `< /dev/stdin`, etc.
SAFE_PATHS = {
    "/dev/null", "/dev/stdin", "/dev/stdout", "/dev/stderr",
    "/dev/tty", "/dev/zero", "/dev/random", "/dev/urandom",
}

# Opt-in: allow reads from Claude Code's own background-task output
# buffers. By default these live under /private/tmp/claude-<uid>/...,
# which the hook denies — making run_in_background unusable. Uncomment
# the prefix below ONLY if you accept that any process writing under
# /private/tmp/claude-* becomes readable. The strict default keeps
# /private/tmp blocked entirely.
SAFE_PATH_PREFIXES = (
    # "/private/tmp/claude-",
)

bad = []
for tok in tokens:
    tok_clean = tok.rstrip(",;)]'\"")
    if not tok_clean:
        continue
    if tok_clean in SAFE_PATHS:
        continue
    expanded = os.path.expanduser(tok_clean)
    try:
        abs_path = os.path.realpath(expanded)
    except Exception:
        abs_path = os.path.abspath(expanded)
    if abs_path == project or abs_path.startswith(project + os.sep):
        continue
    if any(abs_path.startswith(p) for p in SAFE_PATH_PREFIXES):
        continue
    bad.append((tok_clean, abs_path))

for tok, abs_path in bad:
    print(f"{tok}\t{abs_path}")
PY
)

if [ -n "$violations" ]; then
    echo "BLOCKED by deny-bash-outside-project.sh: command references path(s) outside project" >&2
    echo "Project: $project_real" >&2
    echo "Outside-project tokens:" >&2
    printf '%s\n' "$violations" | while IFS=$'\t' read -r token resolved; do
        echo "  $token  ->  $resolved" >&2
    done
    echo >&2
    echo "If this lookup is genuinely needed, ask the user; do not retry without their say-so." >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# .env guard — Bash mirror of settings.json `Read(./**/.env*)`
#
# Independent of the boundary scan above on purpose: this one applies to
# in-project paths (which the scan deliberately allows) and does NOT skip
# regex-looking arguments, since a secrets guard should err toward refusing.
# ---------------------------------------------------------------------------
env_hits=$(python3 - "$cmd" <<'PY'
import shlex, sys

cmd = sys.argv[1]

try:
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    args = list(lex)
except ValueError:
    args = [cmd]

hits = []
for arg in args:
    # Match on path COMPONENTS so `a/b/.env.local` is caught while
    # `--env-file` and `environment` are not. Mirrors the `.env*` glob.
    if any(part.startswith(".env") for part in arg.split("/")):
        hits.append(arg)

for h in dict.fromkeys(hits):
    print(h)
PY
)

if [ -n "$env_hits" ]; then
    echo "BLOCKED by deny-bash-outside-project.sh: command references a .env* path" >&2
    echo "settings.json denies Read(./**/.env*); this mirrors that deny for Bash," >&2
    echo "so secrets are not reachable via cat/grep/python/etc." >&2
    echo "Matched token(s):" >&2
    printf '%s\n' "$env_hits" | while IFS= read -r token; do
        echo "  $token" >&2
    done
    echo >&2
    echo "Do not work around this. If the operation is genuinely needed, ask the user to run it." >&2
    exit 2
fi

exit 0
