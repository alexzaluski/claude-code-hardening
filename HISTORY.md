# Build history

> Companion to [README.md](README.md). The README documents *what*
> the hardening profile does and *how* to use it. This file
> documents *why* — the failures that pushed each layer into
> existence, the bugs caught during rollout, and the key takeaways. 
> If a rule in the README looks arbitrary, the reason is probably here.

---

## Timeline

### Phase 0 — Pre-work audit (baseline findings)

Before doing any hardening I wanted to know what a vanilla Claude
Code install puts on the host. Two categories: configuration the user
or harness writes once, and data the harness writes on its own.

(Audit run against Claude Code `2.1.117`.)

**Configuration the user/harness writes (one-off):**
- `~/.claude/settings.json` — present, minimal by default (just
  `effortLevel` and `model`). No hooks, permissions, or env vars
  unless you add them.
- `~/.claude.json` — app state (~21 KB on my install). OAuth account
  email, account / org UUIDs, hashed userID, cached GrowthBook
  feature flags. Permissions `600`.
- `~/.claude/backups/` — rolling backups of `~/.claude.json`,
  unpruned, grows monotonically.

**Data the harness writes on its own (per-session, ongoing):**
- `~/.claude/projects/<slug>/*.jsonl` — **full verbatim conversation
  transcripts**, plaintext. Includes every user message, tool call,
  file read into context, command output. Largest privacy surface.
- `~/.claude/file-history/<session>/` — **versioned snapshots of
  every file edited via `Edit`/`Write`**, content-addressed
  (hash-named). Easy to miss; second-biggest privacy surface after
  transcripts.
- `~/.claude/shell-snapshots/` — shell (bash/zsh) env snapshot (functions,
  aliases, PATH). Would capture any `export SECRET=...` in the
  shell.
- `~/.claude/sessions/` — PID lockfiles (metadata, not content).
- `~/.claude/ide/` — IDE-extension lockfiles (VS Code, in my case).

**Data in transit (what leaves the machine regardless of settings):**
- Inference itself — every message and tool output goes to Anthropic's API on each turn. Inherent to the hosted model.
- Telemetry — `tengu_log_datadog_events: true` + `tengu_1p_event_batch_config` point at `/api/event_logging/v2/batch`. Controls tool counts / latency / error types. This is a GrowthBook flag, **server-controlled, not user-togglable**.
- Heartbeats — `tengu_kairos_push_notifications`, `tengu_bridge_client_presence_enabled`: outbound ticks to a push/bridge service (no content, just presence).

**Baseline mitigations adopted first (not Claude-specific, still load-bearing):**
1. FileVault on. Covers the local plaintext stores while the machine is powered off.
2. Anthropic account training opt-out via `claude.ai` settings (**consumer tier, Pro/Max — NOT `console.anthropic.com`**, which is API-org only). Zero-Data-Retention is not available on consumer plans; assume some retention window regardless.
3. `gitleaks` installed as a pre-push scanner.
4. Plaintext stores cleaned up on a schedule. Key point: **close all Claude Code sessions first** — the transcript being written by an open session must not be deleted mid-write.
5. Project-level `CLAUDE.md` declaring scope + a project `.gitignore`.

From the audit, two next steps were obvious: a scaffold script that
emits a per-project `.claude/settings.json` deny list on every new
project, and a written posture in the global `~/.claude/CLAUDE.md`
that treats every project as sensitive by default.

### Phase 1 — Applying the baseline

Ran `newproj-safe` for the sensitive project. Created `.gitignore`, minimal `CLAUDE.md` scope header, and an initial `.claude/settings.json` deny list covering Bash network tools (`curl`, `wget`, `ssh`, `scp`, `rsync`, `nc`), destructive Bash patterns (`rm -rf`, `git push`, `git reset --hard`), `WebFetch`, `WebSearch`, `.env*` reads, `*.pem` / `*.key` reads, and broad cross-project read denies (`Read(../**)`, `Read(~/**)`). Updated global `~/.claude/CLAUDE.md` with a strong Privacy section.

At this point the setup felt robust. **It wasn't.**

### Phase 2 — The failure that triggered the next round

The assistant entered **plan mode** to plan an edit to `~/.claude/CLAUDE.md`. Plan mode's system prompt instructed writing the plan file to `~/.claude/plans/<slug>.md`. The assistant followed that instruction and wrote the file — **violating the project scope rule** (`Do not read outside this directory`).

The deny list at that point did not block `Write(~/.claude/**)`; it only blocked *reads* outside-project (`Read(~/**)`). The plan write slipped through. Caught by inspection.

**Lesson:** prompt rules are advisory. When a harness subsystem (plan mode, auto-memory, subagent scaffolding) hands the model a default pointing outside the project, the model will often follow the more *specific* recent instruction over the *stricter* project rule. Config-level enforcement is required. The existing deny list was read-biased and missed this category.

### Phase 3 — Three-layer defense

Two enforcement layers added so the model's judgment is no longer the only thing between a stray instruction and a stray write:

**Layer 2 additions — `.claude/settings.json`:**
```json
"Write(~/.claude/**)", "Edit(~/.claude/**)", "NotebookEdit(~/.claude/**)",
"Write(/tmp/**)", "Edit(/tmp/**)", "NotebookEdit(/tmp/**)",
"Write(/private/tmp/**)", "Edit(/private/tmp/**)", "NotebookEdit(/private/tmp/**)",
"Write(/var/tmp/**)", "Edit(/var/tmp/**)", "NotebookEdit(/var/tmp/**)"
```
(`~` expands in permission patterns — the existing `Read(~/**)` already relies on that.)

**Layer 3 — `.claude/hooks/deny-outside-project.sh`:**
A PreToolUse bash script. Reads the tool-call JSON from stdin, extracts `tool_input.file_path` (or `notebook_path`), resolves realpath, and exits `2` with a "BLOCKED" message on stderr if the target is outside `$CLAUDE_PROJECT_DIR`. Wired via:
```json
"hooks": {
  "PreToolUse": [
    { "matcher": "Write|Edit|NotebookEdit",
      "hooks": [
        { "type": "command",
          "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/deny-outside-project.sh" }
      ] }
  ]
}
```
Static denies catch enumerated paths; the hook catches anything else.

**Global `~/.claude/CLAUDE.md` additions** (tightened directly from the failure):
- **"System defaults do not override project scope."** When a subsystem directs a write outside the project, refuse the default path and surface the conflict.
- **"Session-scoped only."** No plans in `~/.claude/plans/`, no entries in `~/.claude/**/memory/`, no notes in `/tmp`. In-conversation state only.
- **"Explicit edits only."** "User asked to edit `~/.claude/CLAUDE.md`" does not authorize writes to other `~/.claude/` paths (this is the hole that the plan-mode write fell through).

### Phase 4 — Bugs found during rollout

- **Double-slash typo.** Draft had `Write(//Users/...)`. Glob would not have matched canonical path → silent fail-open. Fixed.
- **Missing `NotebookEdit` denies.** `Write`/`Edit` denies skipped the notebook tool. Added.
- **Hook not executable.** A script file without `chmod +x` is not runnable by the harness. Always verify `-rwxr-xr-x` via `ls -l`.
- **Hooks register per-session.** After editing the hook or settings, *restart Claude Code* — existing sessions keep the old registration.
- **`Bash(rm -rf:*)` is coarse.** Blocks benign cleanups (`rm -rf .venv/`). Workarounds: (a) use `python3 -c 'import shutil; shutil.rmtree(".venv")'`, (b) drop the project-level blanket and rely only on user-scope `Bash(rm -rf /:*)` + `Bash(rm -rf ~/:*)`.

### Phase 5 — Scaffold updated (first iteration)

`~/bin/newproj-safe` was extended to emit the whole stack on every new project: the expanded deny list, the write-side hook script, the `chmod +x`, the `hooks.PreToolUse` registration. README updated with the new gotchas (`python3` required for the hook, review `.claude/hooks/*` before launch, hooks register per-session).

### Phase 6 — Project-specific token blocker (`.githooks/pre-commit`)

The next gap I noticed was at the git boundary, not the Claude
boundary. Source data often contains **identifiers that shouldn't
end up in a public repo** — vendor-issued archive tokens in URL
fields, internal IDs in metadata, account-tied public-archive
identifiers. `.gitignore` keeps the raw data directory out of git,
but a stray paste of a single row into a note, commit message, or
report file slips past it.

Added a project-level git pre-commit hook at `.githooks/pre-commit`.
Scans only the *added* lines in staged content for configured regex
patterns; rejects the commit on match. Activated by running
`git config core.hooksPath .githooks` once in the project — the
setting lives in `.git/config`, which isn't tracked in the repo. The scaffold's template ships
with the patterns array commented out — **enabling it is a per-project
decision, not a universal default**, because the right patterns
depend on what the project handles. (Common pattern classes are
documented in the README's Customization section.)

Notes:
- This is a **git-time** hook (runs at `git commit`), not a Claude-time hook. Independent of the Claude Code permission system.
- Zero token cost — never enters the model's context.
- Bypassable by `--no-verify`. Safety net, not authorization boundary.
- Doesn't scan history or working-tree-only files. For full repo scans before pushing, run `gitleaks detect --source .`.

### Phase 7 — The Bash read-loophole, and the token-cost reckoning

Another Claude session ran a self-audit and reported a clear failure
mode: the Read deny rules (`Read(~/**)`, `Read(../**)`) cover the **Read
tool**, but the **Bash tool** can run `cat`, `grep`, `find`,
`python3 -c 'open(...)'` and read anything. The hook from Phase 3
matched only `Write|Edit|NotebookEdit`, so Bash reads went uncaught.
Layer 2 was read-biased; Layer 3 was write-biased. Result: the model
made seven outside-project reads in a single conversation, including
echoing PII into the transcript.

**Layer 3 extension:** added `.claude/hooks/deny-bash-outside-project.sh`.
Matches `Bash`. Parses the command, extracts path-looking tokens
(start with `/`, `~`, or `./`), resolves each via realpath, blocks if
any are outside `$CLAUDE_PROJECT_DIR`. An allow-list of metadata
commands (`realpath`, `basename`, `dirname`, `which`, etc.) bypasses
the check. (A second allow-list for kernel device files came later
once a false positive on `/dev/null` showed up — covered below.)
Defense-in-depth, not a fortress — paths inside command substitution
or quoted script literals leak through; CLAUDE.md still asks the
model to respect spirit-of-the-law for those.

Wired alongside the write-side hook in `.claude/settings.json`:
```json
"hooks": {
  "PreToolUse": [
    { "matcher": "Write|Edit|NotebookEdit",
      "hooks": [ { "type": "command",
                   "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/deny-outside-project.sh" } ] },
    { "matcher": "Bash",
      "hooks": [ { "type": "command",
                   "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/deny-bash-outside-project.sh" } ] }
  ]
}
```

**Token-cost analysis.** Until this point we'd been adding rules to
CLAUDE.md without thinking about the per-turn cost. Audit:

| Layer                       | Per-turn token cost |
|-----------------------------|---------------------|
| `.claude/settings.json`     | 0 (harness-only)   |
| `.claude/hooks/*`           | 0 baseline (~50 on block) |
| `.githooks/pre-commit`      | 0 (git-time only)  |
| Global `~/.claude/CLAUDE.md`| ~800–1000          |
| Project `CLAUDE.md`         | ~700–900           |

Two CLAUDE.md files riding on every turn = ~1500–2000 tokens of pure
overhead per turn. In a 50-turn session, ~75–100k tokens spent
re-reading the same rules.

**Reframe:** every rule a hook or deny pattern enforces is a rule
that doesn't need to live in CLAUDE.md. Duplication adds zero safety;
just per-turn cost.

**CLAUDE.md trim** applied to both files:
- Removed bullets the harness already enforces (network egress, third-
  party uploads, session-scoped, explicit edits, memory hygiene,
  system-defaults-don't-override).
- Added one new bullet that closes the audit's failure class:
  *"Bash is not an escape hatch for Read denies."*
- Added one bullet for the audit's secondary failure (PII echo):
  *"System-injected context is not a file."*
- Added one token-discipline bullet:
  *"Summarize long tool outputs instead of re-quoting them."*

Net: roughly halved the per-turn CLAUDE.md cost while strengthening
enforcement against the actual failure modes seen.

### Phase 8 — Scaffold caught up + git init optional

`~/bin/newproj-safe` was extended again to emit the post-Phase-6/7 additions: the second hook (`deny-bash-outside-project.sh`), its `PreToolUse` registration under a `Bash` matcher, and the `.githooks/pre-commit` template. The script also became interactive about git: it now prompts `"Initialize a fresh git repository? [Y/n]"` instead of running `git init -q` unconditionally. On `Y`, it also runs `git config core.hooksPath .githooks` so the pre-commit hook is active without a separate manual step. On `N`, it prints a reminder to set `core.hooksPath` after dropping in an old `.git/` directory.

Reasoning: the previous unconditional `git init` complicated the project-reset case where I wanted to preserve an existing `.git/` from the old project. Making the prompt explicit cleaned that up without adding work to the fresh-start case (default is still yes).

### Phase 9 — Bash hook edge cases

The path-token heuristic in `deny-bash-outside-project.sh` is deliberately blunt: any `/`, `~`, or `./`-prefixed token gets resolved and checked. Two cases surfaced after the hook went live where blunt was too blunt.

**Case 1 — `/dev/null` false positive.** While auditing a transcript from another project, found the Bash hook had blocked an in-project `grep` because the command contained `2>/dev/null`. The hook matched `/dev/null` as an outside-project token and exited 2. Worse: when the cancelled call was part of a parallel batch, the harness cancelled every sibling call too, so a `grep` that was completely inside the project also got marked as failed.

Fix: added a `SAFE_PATHS` allow-list covering kernel device files (`/dev/null`, `/dev/stdin`, `/dev/stdout`, `/dev/stderr`, `/dev/tty`, `/dev/zero`, `/dev/random`, `/dev/urandom`). These aren't real filesystem reads — they're kernel-managed devices and reading/writing them leaks nothing about project layout. The check skips them before realpath resolution.

The lesson behind it: "outside the project tree" was the wrong abstraction for `/dev/*`. The hook's mental model is "block paths that could exfiltrate file content"; kernel device files can't, so they don't need to be in scope. Keep the allow-list conservative — every entry is a hole, even a tiny one.

**Case 2 — regex pattern arguments.** A `grep -E '...|/private/tmp|...'` issued during a later audit got blocked because `/private/tmp` inside the regex looked like a path token. The pattern was a literal string in a search argument, not a filesystem reference.

The first attempt at a fix was wrong: skipping any *bare token* containing regex metacharacters didn't help, because the path-extraction regex splits on `|` and pulls `/private/tmp` out of the surrounding pattern as a clean token with no metacharacters left in it. Verified by running the hook against the literal failing case before claiming the fix worked.

Fix that actually works: shell-tokenize the command first with `shlex.split`, then for each shell argument check whether the *argument as a whole* contains regex metacharacters (`|`, `(`, `)`, `[`, `]`, `^`, `$`, `\`, `+`). Quoted arguments stay grouped, so a `grep -E 'foo|/private/tmp|bar'` becomes one argument containing `|`, gets recognized as a pattern, and is skipped before path extraction. A real outside-project path on the same command line (e.g. `grep -E 'a|b' /etc/hosts`) is a separate shell argument with no metacharacters, gets extracted, and is still blocked. `shlex` is Python stdlib — no new dependency.

Trade-off: a constructed path with one of those characters in it (e.g. `/some/$VAR/file`) gets skipped too, which is the same env-var limitation already noted in the hook header.

Lesson: heuristic security code needs to be tested against the case it claims to fix, not just the case the developer pictured while writing it.

**Propagation (applies to both patches):** copy into (a) the scaffold script (the heredoc that emits the hook for new projects), and (b) every existing project that already has the older hook. `find <projects-root> -name deny-bash-outside-project.sh` lists candidates. Restart Claude in each project after copying — hooks register per-session.

### Phase 11 — Audit follow-up: Bash hook bypass + deny-list breadth

A second-pass review of the deployed setup turned up four issues, one a real bypass and three breadth gaps.

**Bypass: no-whitespace shell operators slipped past the Bash hook.** The Phase 9 fix used `shlex.split(cmd, posix=True)` so quoted regex args stay grouped. Posix `shlex` does *not* split on shell operators (`|`, `;`, `&`, `<`, `>`, `(`, `)`) when they're not separated by whitespace. Result:

```
cat /etc/passwd|head     →  ['cat', '/etc/passwd|head']
```

The second token contained `|`, the `REGEX_META` skip dropped it as a "regex pattern argument," and the path was never realpath-checked. The whitespaced form (`cat /etc/passwd | head`) was correctly blocked — it tokenized to four args, with `/etc/passwd` clean. Same shape applied to `;`, `&`, `<`, `>`, and `(...)`. One missing space defeated the whole hook.

Fix: `shlex.shlex(cmd, posix=True, punctuation_chars=True)` with `whitespace_split=True`. Operators become their own tokens regardless of surrounding whitespace, so `cat /etc/passwd|head` tokenizes to `['cat', '/etc/passwd', '|', 'head']` — `/etc/passwd` reaches the path check. Quoted args (`grep -E 'a|b'`) still stay grouped because shlex respects quote boundaries before applying punctuation_chars, so the regex-arg false-positive that Phase 9 fixed stays fixed. No new dependency; `punctuation_chars` is stdlib (Python 3.6+).

Added four regression tests covering the no-whitespace `|`, `;`, `<`, and `(...)` shapes. Lesson reinforced from Phase 9: heuristic security code must be tested against the case it claims to fix. Posix-shlex's "operators-need-whitespace" behavior is documented but easy to miss when the test cases all happen to include spaces.

**Breadth: deny-list gaps.** The audit named several patterns covered in `.gitignore` but not in `.claude/settings.json` (or vice versa), plus a few exfil shapes that paired with existing denies but weren't denied themselves:

- `Read(./**/*.p12)`, `Read(./**/*.pfx)`, `Read(./**/id_rsa*)`, `Read(./**/id_ed25519*)`, `Read(./**/*.asc)`, `Read(./**/*.gpg)` — added to `settings.json`. `*.p12` was in `.gitignore` already; the rest filled in symmetrically across both files. Mechanical, no friction cost.
- `Bash(git remote add:*)`, `Bash(git remote set-url:*)` — paired with the existing `Bash(git push:*)` deny. Without these, an exfil-via-new-remote shape was open: add a remote pointing at attacker-controlled storage, push to it. Niche but cheap to close.
- `Bash(history:*)` — `history` dumps recent shell commands, which on a developer machine routinely include credentials passed inline. Same env/secret leak surface as the already-denied `printenv` and `env`.

Skipped after consideration: `Bash(export)`, `Bash(set)`, `Bash(declare)`, `Bash(alias)`. Each has legitimate everyday uses Claude needs (`export PATH=...`, `set -e`); the leak shapes are narrower forms (`export -p`, bare `set`). The Claude Code permission matcher matches by command prefix, so blanket-denying these would block legitimate use. Keeping them allowed; if a future audit finds an actual exfil via these, revisit with a more targeted pattern.

**Breadth: pre-commit pattern menu.** The commented menu in `.githooks/pre-commit` (and the matching heredoc in `newproj-safe`) gained `ASIA*` (AWS STS), `rk_live_*` (Stripe restricted), `AIza*` (Google API), `npm_*`, and `sk-ant-*` (Anthropic). All commented-out — enabling per-project remains a deliberate choice; the menu is a starting list, not a default. README's customization table updated to match.

Lesson: a fresh review is worth doing. The deny list and `.gitignore` patterns are easy to skim and judge; the hook is a small program with assumptions baked in, and someone reading it for the first time will spot the cases the original tests didn't cover.

### Phase 12 — Where things stand now (post-audit)

- Layer 1 (prompt) — global `~/.claude/CLAUDE.md` + project `CLAUDE.md` (domain-specific only; the project file should **not** restate the global rules, only add project context).
- Layer 2 (permissions) — deny list covers network, destructive Bash, secret reads, cross-project reads, outside-project writes.
- Layer 3 (Claude-time hooks) — both `deny-outside-project.sh` (Write/Edit/NotebookEdit) and `deny-bash-outside-project.sh` (Bash). Closes the read-loophole.
- Layer 4 (git-time hook) — `.githooks/pre-commit` blocks commits matching configured token regexes.
- Scaffold propagates Layers 2 + 3 + 4 to every new project, with optional `git init`.

---

## Reference appendix

### Where Claude Code writes on the host

| Path | What | Per-project? | Written by |
|---|---|---|---|
| `~/.claude/projects/<slug>/*.jsonl` | Full session transcripts, plaintext | yes | harness (not via Write tool — hook can't see) |
| `~/.claude/file-history/<session>/` | Versioned file content snapshots, hash-addressed | no | harness, on each Edit/Write |
| `~/.claude/backups/` | Rolling backups of `~/.claude.json` | no | harness |
| `~/.claude.json` | OAuth info, account UUIDs, GrowthBook flags | no | harness |
| `~/.claude/shell-snapshots/` | shell (bash/zsh) env snapshot | per-session | harness |
| `~/.claude/sessions/` | PID locks (metadata) | per-session | harness |
| `~/.claude/ide/` | IDE extension lockfiles | — | IDE extension |
| `~/.claude/plans/` | Plan mode plan files | per-conversation (slug from prompt) | plan mode |
| `~/.claude/todos/` | TodoWrite state | per-session | TodoWrite |
| `~/.claude/**/memory/` | Auto-memory entries | per-project | auto-memory |
| `~/.claude/settings.json` | Global settings | no | user |
| `~/.claude/CLAUDE.md` | Global instructions | no | user |
| `<project>/.claude/settings.json` | Project settings | yes | scaffold / user |
| `<project>/.claude/hooks/deny-outside-project.sh` | PreToolUse hook (`Write\|Edit\|NotebookEdit`) | yes | scaffold / user |
| `<project>/.claude/hooks/deny-bash-outside-project.sh` | PreToolUse hook (`Bash`) | yes | scaffold / user |
| `<project>/.githooks/pre-commit` | Git pre-commit hook (token blocker) | yes | scaffold / user |
| `<project>/CLAUDE.md` | Project instructions | yes | user |

**Slug derivation:** absolute project path with `/` → `-`. E.g. `/Users/<user>/projects/orgs/<org>/<project>` → `-Users-<user>-projects-orgs-<org>-<project>`.

**Important:** transcripts and file-history are written by the **harness itself**, not via the `Write`/`Edit` tool — Layers 2/3 don't see them. They land on disk regardless of deny rules.

### Defense depth map

```
Model behavior         ← Layer 1 (CLAUDE.md)               — advisory
Write/Edit patterns    ← Layer 2 (permissions.deny)        — static, enforced
Write/Edit paths       ← Layer 3a (Write hook)             — generic, enforced
Bash-mediated reads    ← Layer 3b (Bash hook)              — best-effort, enforced
Subprocess I/O         ← (uncovered — needs container)
Host-disk at rest      ← FileVault
Network exfil (OS)     ← (uncovered — needs container --network=none)
Retention at provider  ← claude.ai account training opt-out (Zero Data Retention only available on the commercial API tier)
Git-commit leakage     ← Layer 4 (.githooks/pre-commit) + gitleaks pre-push + .gitignore
```

### Accepted functional costs

- No web lookups (`WebFetch`, `WebSearch` denied). Approve ad-hoc when needed.
- Plan mode broken for sensitive projects (plan files can't be written). Plan inline in chat.
- `rm -rf` via Bash tool blocked (coarse). Use Python `shutil.rmtree`.
- `git push` blocked. Push manually.
- No cross-project reads (`Read(~/**)`, `Read(../**)`). Paste snippets if you need comparison.
- Auto-memory disabled in practice. Session-scoped-only is intentional.
- Background `Bash` (`run_in_background: true`) unusable by default. Output buffers land under `/private/tmp/claude-<uid>/...`, which the Bash hook denies for reads. Foreground only. A narrow opt-in (`SAFE_PATH_PREFIXES = ("/private/tmp/claude-",)` in the hook) restores it at the cost of allowing reads of anything any process writes under that prefix; the strict default keeps it blocked.

### Recurring questions

**"Restart Claude" — does that mean abandoning the conversation?**
No. Hooks load at process start, not per-message. To pick up a hook
edit: quit the `claude` process (close the CLI window or whichever
IDE extension is hosting it), relaunch, then `/resume` the same
session. The transcript continues; the next tool call uses the
patched hook.

**Is the lack of trust in defaults justified?** From what I've seen,
yes. Plan mode already wrote outside the project once (Phase 2)
because Anthropic's plan-mode system prompt told the model to. Auto-
memory has the same shape (system instruction → `~/.claude/**/memory/`).
The model also drifts away from `CLAUDE.md` over a long conversation;
hooks don't.

The defaults fit a common case where everything in the user's home directory is one trust class:
code, configs, scratch, all reachable by the same developer for the
same purposes. That model breaks down once a project's data carries
obligations the rest of the home directory doesn't share — privacy
regulations, NDAs, third-party tokens that shouldn't be republished,
client confidentiality. In those cases the question isn't "is my home
directory safe?" (an encrypted disk and a single-user account already
cover that) but "where can this *project's* data flow?". Every turn
ships project data to Anthropic; transcripts persist; auto-memory and
plan mode write across project boundaries; `curl` / `WebFetch` send
data off-machine. Hardening is the layer that constrains those flows.
Without it, the model can `cat` a file from a sibling project, echo a
token into a transcript, or paste a row into a cloud notebook with no
one having decided to allow it.

---

## Lessons:

1. **Config-level enforcement vs prompt-level.** A deny rule plus a hook holds up better than relying on the model to remember.
2. **Static deny list + generic hook.** A list can't enumerate every bad target, but the hook catches what the list missed.
3. **Silent fail-open is the dangerous failure mode.** A misconfigured deny (e.g. `//` → `/` typo) won't warn you, so it's worth verifying a match before trusting it.
4. **Hooks register per-session.** After editing guardrails, restart — a running session keeps the old registration.
5. **Harness enforcement is free; prompt rules cost tokens every turn.** Anything hooks or deny patterns already enforce shouldn't live in CLAUDE.md too — duplication adds zero safety and per-turn cost. CLAUDE.md is for what the harness can't enforce (model behavior, not file-system effects).
6. **The harness writes on its own** (transcripts, file-history). Guardrails can't stop that — only FileVault, periodic deletion, and account-level retention settings do.
7. **One global hook over per-feature whack-a-mole.** A single PreToolUse hook enforcing "write inside project, period" ages better than chasing each subsystem (plan mode, memory, agents) individually.
8. **The over-restriction trap.** A deny that's too broad — `Bash(rm -rf:*)` blocking benign `rm -rf .venv/`, for instance — produces enough day-to-day friction that the practical end state is switching it off entirely. Narrower patterns at user scope (`rm -rf /:*`, `rm -rf ~/:*`) hold up better than a project-wide blanket. A pattern that catches only what it's meant to gives stronger protection in practice than one broad enough to block legitimate work.
9. **Documentation as you build.** A week later the reason for a rule is hard to recover; six months later someone else picks it up and wonders whether to delete it. A written history is the answer.
10. **Don't copy settings between scopes verbatim.** Global and project `settings.json` answer different questions ("what should never happen anywhere" vs "what's off-limits for this data"). Promoting project denies to global over-restricts unrelated work; promoting hook entries to global breaks every non-scaffolded project.