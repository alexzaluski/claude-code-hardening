#!/usr/bin/env bash
# PreToolUse hook for Bash. Three rules, one pass:
#
#   1. PROJECT BOUNDARY — block commands whose path arguments resolve
#      outside $CLAUDE_PROJECT_DIR. Covers the subprocess routes
#      (`cat`, `grep`, `find`, …) that settings.json's Read denies
#      don't bind.
#   2. .env PATHS — Bash mirror of `Read(./**/.env*)`, which binds the
#      Read tool only. Applies to in-project paths, which rule 1 allows
#      by design.
#   3. WRAPPED COMMAND DENIES — re-apply settings.json's `Bash(...)`
#      entries to scripts carried inside a wrapper, where the harness
#      matcher sees only the outer first word. Specs are read from
#      settings.json at run time, so they cannot drift from it.
#      Extracted scripts only; bare commands are the harness's job.
#
# All three run against the command and against every script extracted
# from a wrapper (`sh -c '<script>'`, `env <cmd>`, …), each scanned as
# its own top-level command. See Phase 16 in HISTORY.md.
#
# KNOWN LIMITS (defense-in-depth, not a fortress). Not seen:
#   - paths inside command substitutions, `cat $(cmd)`
#   - paths inside interpreter literals, `python3 -c 'open("/etc/x")'` —
#     an interpreter's body isn't shell syntax, so it isn't unwrapped
#   - paths built from env vars set in the same command
#   - wrapper scripts assembled at run time, or nested past depth 4
#   - arguments containing regex metacharacters (`|()[]^$\+`), skipped
#     as patterns so `grep -E '...|/private/tmp|...'` doesn't
#     false-positive; a real path containing one is skipped too
#   - inbound symlinks: `/tmp/foo -> <project>/secret` resolves inside
#     and passes. Outbound links are blocked, including a project-local
#     link to a vendored tree outside the project.
# CLAUDE.md asks the model to respect the rule where this can't see.
#
# FAILS CLOSED: an analysis error, or a settings.json that won't parse,
# blocks the call.

set -euo pipefail

command -v python3 >/dev/null 2>&1 || {
    echo "BLOCKED by deny-bash-outside-project.sh: python3 not on PATH" >&2
    echo "This hook needs python3; install it or remove the hook entry from .claude/settings.json." >&2
    exit 2
}

payload=$(cat)
project="${CLAUDE_PROJECT_DIR:-$PWD}"

cmd=$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(d.get("tool_input", {}).get("command", ""))
')

[ -z "$cmd" ] && exit 0

set +e
verdict=$(python3 - "$cmd" "$project" 2>&1 <<'PY'
import json, os, re, shlex, sys

cmd = sys.argv[1]
project_real = os.path.realpath(sys.argv[2])

if not cmd.strip():
    sys.exit(0)


def newlines_to_separators(text):
    """Turn unquoted newlines into `;`.

    A newline ends a command in shell, but shlex treats it as ordinary
    whitespace, which would flatten a two-line command into one segment.
    Newlines inside quotes are left alone — there they are data.
    """
    out = []
    quote = None
    i = 0
    while i < len(text):
        c = text[i]
        if c == "\\" and i + 1 < len(text) and quote != "'":
            out.append(c)
            out.append(text[i + 1])
            i += 2
            continue
        if quote:
            if c == quote:
                quote = None
            out.append(c)
        elif c in ("'", '"'):
            quote = c
            out.append(c)
        elif c == "\n":
            out.append(" ; ")
        else:
            out.append(c)
        i += 1
    return "".join(out)


# --------------------------------------------------------------------
# Tokenizing
#
# `punctuation_chars=True` splits shell operators into their own tokens
# even without surrounding whitespace, so `cat /etc/passwd|head` yields
# ['cat', '/etc/passwd', '|', 'head'] and the path reaches the scan
# instead of being dropped as one metacharacter-bearing token. Quoted
# args (`grep -E 'a|b'`) stay grouped, so the REGEX_META skip still
# applies. On malformed quoting, fall back to the raw string.
# --------------------------------------------------------------------
def tokenize(text):
    text = newlines_to_separators(text)
    try:
        lex = shlex.shlex(text, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        return list(lex)
    except ValueError:
        return [text]


# --------------------------------------------------------------------
# Segmenting
#
# Every rule below judges commands one at a time: a safe first word
# vouches for its own command only, never for what follows it.
#
# A token is a separator only if made ENTIRELY of operator characters,
# which keeps `;`, `&&`, `|`, `>>` while leaving a quoted regex `a|b`
# intact. Redirections separate too, so in `echo hi > /etc/passwd` the
# `echo` cannot vouch for the path after the `>`.
# --------------------------------------------------------------------
SEP_CHARS = set(";&|<>()")


def segments(tokens):
    out, cur = [], []
    for tok in tokens:
        if tok and set(tok) <= SEP_CHARS:
            if cur:
                out.append(cur)
                cur = []
        else:
            cur.append(tok)
    if cur:
        out.append(cur)
    return out


def first_word(tokens):
    """First token, skipping leading VAR=value assignments."""
    for tok in tokens:
        if "=" in tok and not tok.startswith("="):
            continue
        return tok
    return ""


# --------------------------------------------------------------------
# Wrapper unwrapping
#
# Every shell has a "run this string as a command" flag, so each
# SHELL_WRAPPERS entry carries its script as the argument to a
# `-c`-bearing flag (`-c`, `-ic`, `-lc`, `-Command`). The search runs to
# the end of the arguments — needed to reach the flag in
# `bash -o pipefail -c` and `busybox sh -c`. It may lift a non-script
# token, which then gets scanned as a command: strictness, never a miss.
#
# RUNNER_WRAPPERS take their command as trailing arguments, after flags
# and VAR=value assignments.
#
# Interpreters (`python3 -c`, `perl -e`) are excluded: their body isn't
# shell syntax.
# --------------------------------------------------------------------
SHELL_WRAPPERS = {
    "sh", "bash", "zsh", "dash", "ksh", "ksh93", "mksh",
    "fish", "csh", "tcsh", "ash", "busybox",
    "pwsh", "powershell",
}
RUNNER_WRAPPERS = {
    "env", "nohup", "timeout", "nice", "ionice", "stdbuf", "setsid",
    "command", "builtin", "exec", "script", "time", "xargs",
    "sudo", "doas", "su",
}

MAX_DEPTH = 4


def is_script_flag(tok):
    """True for the flag whose argument is a script: -c, -ic, -Command."""
    if not tok.startswith("-") or tok == "--":
        return False
    low = tok.lower()
    if low in ("-command", "--command"):
        return True
    return not low.startswith("--") and low.endswith("c")


def unwrap(text, depth=0, out=None):
    """Collect scripts carried inside shell/runner wrappers, recursively."""
    if out is None:
        out = []
    if depth >= MAX_DEPTH:
        return out
    toks = tokenize(text)
    i = 0
    while i < len(toks):
        base = toks[i].rsplit("/", 1)[-1]
        if base in SHELL_WRAPPERS:
            j = i + 1
            while j < len(toks):
                if is_script_flag(toks[j]) and j + 1 < len(toks):
                    inner = toks[j + 1]
                    out.append(inner)
                    unwrap(inner, depth + 1, out)
                    break
                j += 1
        elif base in RUNNER_WRAPPERS:
            j = i + 1
            while j < len(toks):
                a = toks[j]
                if a.startswith("-") or ("=" in a and not a.startswith("=")):
                    j += 1
                    continue
                break
            rest = toks[j:]
            if rest:
                inner = " ".join(rest)
                out.append(inner)
                unwrap(inner, depth + 1, out)
        i += 1
    return out


# Dedupe while preserving order: a runner followed by a shell
# (`env sh -c '<script>'`) reaches the same script by two routes.
inner_scripts = []
for script in unwrap(cmd):
    if script not in inner_scripts:
        inner_scripts.append(script)
variants = [cmd] + inner_scripts

# ====================================================================
# Rule 1 — project boundary
# ====================================================================

# Commands whose first word is one of these get pass-through. They
# don't read file content; they manipulate paths or report metadata.
SAFE_FIRST_WORDS = {
    "realpath", "basename", "dirname",
    "which", "type", "command",
    "echo", "printf", "true", "false", "test", "[",
}

# Regex / glob metacharacters that real filesystem paths almost never
# contain. If a whole shell argument contains any of these, the
# argument is treated as a pattern (regex / glob / alternation), not as
# something bearing a file path, and is skipped before path extraction.
# Catches the common false positive where a `grep -E` pattern contains
# a `/`-prefixed substring.
REGEX_META = set("|()[]^$\\+")

# Kernel devices and special files. Not real filesystem reads; reading
# or writing them leaks nothing about project layout. Common in
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

PATH_TOKEN = re.compile(
    r"(?:(?<=^)|(?<=[\s=:|;<>&(]))((?:~|/|\./)[^\s'\"<>|;&)]+)"
)


boundary_hits = []
for variant in variants:
    for seg in segments(tokenize(variant)):
        if first_word(seg) in SAFE_FIRST_WORDS:
            continue
        for arg in seg:
            if any(c in arg for c in REGEX_META):
                continue
            for tok in PATH_TOKEN.findall(arg):
                tok_clean = tok.rstrip(",;)]'\"")
                if not tok_clean or tok_clean in SAFE_PATHS:
                    continue
                expanded = os.path.expanduser(tok_clean)
                try:
                    abs_path = os.path.realpath(expanded)
                except Exception:
                    abs_path = os.path.abspath(expanded)
                if abs_path == project_real or abs_path.startswith(project_real + os.sep):
                    continue
                if any(abs_path.startswith(p) for p in SAFE_PATH_PREFIXES):
                    continue
                if (tok_clean, abs_path) not in boundary_hits:
                    boundary_hits.append((tok_clean, abs_path))

if boundary_hits:
    print("BLOCKED by deny-bash-outside-project.sh: command references path(s) outside project")
    print("Project: %s" % project_real)
    print("Outside-project tokens:")
    for tok, abs_path in boundary_hits:
        print("  %s  ->  %s" % (tok, abs_path))
    print("")
    print("If this lookup is genuinely needed, ask the user; do not retry without their say-so.")
    sys.exit(2)

# ====================================================================
# Rule 2 — .env paths (Bash mirror of settings.json Read(./**/.env*))
#
# Independent of rule 1: applies to IN-project paths, which rule 1
# allows by design, and does not skip regex-looking arguments — a
# secrets guard should err toward refusing. Matches on path COMPONENTS,
# so `a/b/.env.local` is caught while `--env-file` and `environment`
# are not, tracking the Read glob exactly. That includes a committed
# `.env.example`; name a readable template so it does not lead with
# `.env` (e.g. `foo.env.example`).
#
# Blocks path references, not reads. A script that loads a .env
# internally is unaffected — keeping the VALUES out of the transcript
# is the program's job, not this hook's.
# ====================================================================
env_hits = []
for variant in variants:
    for arg in tokenize(variant):
        if any(part.startswith(".env") for part in arg.split("/")):
            if arg not in env_hits:
                env_hits.append(arg)

if env_hits:
    print("BLOCKED by deny-bash-outside-project.sh: command references a .env* path")
    print("settings.json denies Read(./**/.env*); this mirrors that deny for Bash,")
    print("so secrets are not reachable via cat/grep/python/etc.")
    print("Matched token(s):")
    for tok in env_hits:
        print("  %s" % tok)
    print("")
    print("Do not work around this. If the operation is genuinely needed, ask the user to run it.")
    sys.exit(2)

# ====================================================================
# Rule 3 — command denies inside wrappers
#
# Sources merge in the order Claude Code merges them; deny is additive,
# so order only affects which file gets named in the message.
# ====================================================================
if inner_scripts:
    deny_specs = []
    for path in (
        os.path.join(project_real, ".claude", "settings.json"),
        os.path.join(project_real, ".claude", "settings.local.json"),
        os.path.join(os.path.expanduser("~"), ".claude", "settings.json"),
    ):
        if not os.path.exists(path):
            continue
        try:
            with open(path) as fh:
                cfg = json.load(fh)
        except Exception:
            print("BLOCKED by deny-bash-outside-project.sh: cannot parse %s" % path)
            print("The hook re-enforces this file's Bash denies inside subshells and")
            print("refuses to run while it is unreadable. Fix the JSON, then retry.")
            sys.exit(2)
        perms = cfg.get("permissions") or {}
        for entry in perms.get("deny") or []:
            if isinstance(entry, str) and entry.startswith("Bash(") and entry.endswith(")"):
                spec = entry[5:-1].strip()
                if spec and spec not in deny_specs:
                    deny_specs.append(spec)

    def matched_deny(seg):
        # Drop leading VAR=value assignments, then compare the rest of
        # the segment against each deny spec.
        rest = list(seg)
        while rest and "=" in rest[0] and not rest[0].startswith("="):
            rest.pop(0)
        norm = " ".join(" ".join(rest).split())
        if not norm:
            return None
        for spec in deny_specs:
            if spec.endswith(":*"):
                pre = " ".join(spec[:-2].split())
                if not pre:
                    continue
                if norm == pre:
                    return spec
                if norm.startswith(pre):
                    # A prefix ending in a word character must be
                    # followed by a space, so `curl` does not match
                    # `curlopts`. One ending in punctuation (`rm -rf /`)
                    # matches directly, as the deny glob intends.
                    if not pre[-1].isalnum() or norm[len(pre):].startswith(" "):
                        return spec
            elif " ".join(spec.split()) == norm:
                return spec
        return None

    deny_hits = []
    for script in inner_scripts:
        for seg in segments(tokenize(script)):
            spec = matched_deny(seg)
            if spec:
                piece = " ".join(seg)
                if (piece, spec) not in deny_hits:
                    deny_hits.append((piece, spec))

    if deny_hits:
        print("BLOCKED by deny-bash-outside-project.sh: denied command inside a shell wrapper")
        print("A wrapper such as `sh -c` / `zsh -ic` hides the real command from the")
        print("harness's own deny matcher, which only sees the outer first word.")
        print("Matched against settings.json:")
        for piece, spec in deny_hits:
            print("  %s   <-  Bash(%s)" % (piece, spec))
        print("")
        print("Run the command directly instead of through a wrapper. If the wrapper")
        print("exists only to reach a version-manager toolchain (nvm, pyenv, rbenv),")
        print("set PATH in .claude/settings.json `env` instead — see the README.")
        sys.exit(2)

sys.exit(0)
PY
)
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$verdict" >&2
    exit 2
fi

exit 0
