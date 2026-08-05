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

### Phase 13 — Skill compatibility, model misattribution, and a Claude Code semantics drift

Three findings surfaced during follow-up testing of the post-audit profile in a fresh project. The first two are smaller; the third is the load-bearing one.

**Finding 1: `/fewer-permission-prompts` is incompatible with the strict scoping, correctly.** The skill scans `~/.claude/projects/<slug>/*.jsonl` to mine common read-only Bash patterns and propose an allow-list. The Bash hook denied the scan — `~/.claude/projects/` is outside the project tree, hook fired exactly as designed, transcript reads were refused. The skill offered an in-session fallback ("suggest from this conversation only"), which is the right answer: smaller signal, no boundary crossed. Take-away: harness skills that need `~/.claude/**` access conflict with strict project scoping by construction. Use the in-session fallback they offer; do not relax the hook for skill convenience. Open design question — should the hook treat the project's own transcripts (`~/.claude/projects/<this-project-slug>/`) as in-scope, since they're physically outside the tree but logically project data? Deferred until a second skill hits the same wall; for now the strict default holds and costs nothing in normal operation (the model never reads its own transcript file during a live session; `/compact` and `/resume` go through harness code paths the hook doesn't intercept).

**Finding 2: model-side misattribution under deny-heavy regimes.** While testing in a separate hardened project, Bash prompts kept getting denied (default `ask` mode, no curated allow list yet) while in-project `Read` calls had session-cached approval. The session's assistant narrated this as *"permissions tightened mid-session"* — a clean hallucination explaining the asymmetry. The actual mechanism (Read got approved earlier in the session, Bash always re-prompts) wasn't recognised. The model later doubled down, claiming "the Read tool is denying access to all files" while several Read calls in the same transcript had quietly returned content with no error line. Pattern is broader than this project: **a model under a deny-heavy regime will sometimes invent a story for the friction rather than recognising the permission-prompt mechanism, and once it has a story it will keep narrating reality to fit it.** Worth noting because it shapes downstream decisions — in the test case, the misdiagnosis nudged the assistant toward defensive Edit-without-Read sequences and led the operator to add allow rules that didn't actually fix the (mis-described) problem.

**Finding 3 — load-bearing: `Read(~/**)` started over-matching project files after a Claude Code version shift.** Same separate project, fresh Cmd-Q restart, no per-path session approvals: every `Read` of an in-project file returned *"File is in a directory that is denied by your permission settings."* Removing `Read(~/**)` from the project's `.claude/settings.json` and restarting fixed it on the next try. So `Read(~/**)` — present in the profile since **Phase 1** — was matching files inside the project, not just outside.

Mechanism (best reconstruction): the Read tool's path argument now gets normalised to an absolute path before deny rules are checked. A file under `~/dev/<project>/foo.md` is under `/Users/<user>/...`, which `Read(~/**)` expands to. So every project file under home matches the deny. This is *not* how the rule behaved on initial design — Phase 1 trusted it to mean "block cross-project reads of other directories under home." Either Claude Code's matcher changed how it resolves `Read` arguments, or `~` expansion in deny patterns is now eager where it used to be lazy, or session-approval logic stopped masking the over-match. Without an older Claude Code build to A/B against, the exact knob can't be pinned down — but the practical conclusion is the same.

Why this took so long to surface:
- Long-running sessions accumulated per-path read approvals. Files I'd already read got cached as approved; new files in the same session worked because the harness had grace. The rule was bites only fresh sessions on never-read files — exactly the case skills like `/fewer-permission-prompts` and end-of-session compactions tend to trigger.
- The error message ("File is in a directory that is denied") looks like a project-scope violation, not a self-referential one. It nudges debugging in the wrong direction.
- The misattribution in Finding 2 makes the in-session model's report unreliable as a diagnostic signal. The model will often confidently mislabel the cause.

**Fix applied:** removed `Read(~/**)` from the project template, project copies, and the `newproj-safe` heredoc. The global template was already using the narrow-deny approach (`Read(~/.ssh/**)`, `~/.aws/**`, `~/.gnupg/**`, `~/.config/gh/**`) and didn't need changing — confirming, in retrospect, that the right pattern was always enumeration of sensitive subdirs, not a blanket home-deny. Updated the Bash hook's header comment to drop the now-stale reference to "closes the `Read(~/**)` loophole."

**Gap this opens:** without `Read(~/**)`, the project-level `Read` deny list no longer blocks absolute-path reads of neighbouring projects under home. `Read(../**)` covers relative-up paths and the Bash hook covers Bash-mediated outside-project access via `realpath` against `$CLAUDE_PROJECT_DIR`, but a model that does `Read("/Users/<user>/other-project/file")` via the Read tool would now slip through. Two reasonable shapes for closing that:

1. **Narrow-deny enumeration**, matching the global template's pattern: enumerate sensitive home dirs and obviously-other-project trees. Declarative; simple; gets stale as you add new project parents (`~/dev/`, `~/work/`, etc.).
2. **Read-side PreToolUse hook**, mirroring the Bash hook. Same `realpath`-vs-`$CLAUDE_PROJECT_DIR` enforcement, but for the `Read` tool. Removes the deny-list approach entirely for the project-boundary question and unifies enforcement under one mechanism.

Leaning option 2 because (a) it matches the Bash-hook design — one enforcement model instead of two — and (b) the deny-list approach is now demonstrably fragile against path-normalisation changes in the harness, while a `realpath` check against `$CLAUDE_PROJECT_DIR` is much harder to silently break with a Claude Code version bump. Deferred for a follow-up commit; the previous commit was the artifact cleanup.

**Option 2 applied (follow-up commit).** The existing `deny-outside-project.sh` already extracted `file_path` from `tool_input` and realpath-checked it — same logic the Read tool needs. So the change collapsed to: extend the PreToolUse matcher from `Write|Edit|NotebookEdit` to `Write|Edit|NotebookEdit|Read`, and reframe the hook's header comment plus error messages from write-specific (`"write target"`, `"forbids outside-project writes"`) to tool-generic (`"tool target"`, `"forbids outside-project access"`). No new script, no new heredoc section — one matcher edit, one comment edit, one error-message edit, across the three usual locations (template, project copy, `newproj-safe` heredoc). Added three behaviour tests against `deny-outside-project.sh` directly (in-project allow, outside-project absolute path blocked, outside-project `~`-prefixed path blocked) so the file-path enforcement has its own regression coverage independent of the Bash hook. Closes the gap: Read tool calls to absolute or `~`-rooted paths outside the project are now denied at Layer 3, by the same `realpath`-vs-`$CLAUDE_PROJECT_DIR` mechanism the Bash hook uses for subprocess paths.

**Test suite extended to three layers.** Running the existing `tests/test_hooks.sh` against the pre-Phase-11 templates passed clean — it caught behaviour regressions in the Bash hook and drift between the template and the `newproj-safe` heredoc, but it had no way to notice that the audit-driven deny entries (`Bash(history:*)`, `Bash(git remote add:*)`, the key-file globs) had ever been added or that `Read(~/**)` had ever been removed. Added a third "Invariants" block: JSON validity, hook executability, a *forbidden-patterns* list (currently one entry: `Read(~/**)`, with the Phase 13 reason inline), and a *required-patterns* list (one representative per audit-driven category). Negative-tested by reintroducing `Read(~/**)` to confirm the forbidden assertion fires. Fixed an unrelated early-exit bug in the drift handler discovered along the way — a failing `diff | head -40` pipeline under `pipefail` was short-circuiting the rest of the script, so the invariants section never ran when drift failed; explicit `|| true` on that line restores full execution.

**Larger lesson — harness-version drift as a failure class.** A rule that was correct under Claude Code version N can silently change meaning under version N+k without any error, warning, or release note flagging the affected rules. The hardening's most fragile layer turned out to be the declarative deny list, exactly because its semantics are interpreted by the harness rather than by code we control. Layer 3 (hooks) is more robust here: it encodes its own enforcement logic (`realpath`, prefix check) in code that doesn't shift under us. This is one reason to prefer hook-based enforcement for boundary rules going forward — the deny list remains useful for pattern-based matches (`*.pem`, `*.env*`) that don't depend on path semantics, but anything shaped like "outside the project" is better expressed as a hook check. Worth flagging now as a recurring risk rather than treating this incident as a one-off; if a second deny rule turns out to have silently changed meaning, that confirms the pattern and the migration argument gets stronger.

### Phase 14 — Where things stand now (post-cleanup)

- Layer 1 (prompt) — global `~/.claude/CLAUDE.md` + project `CLAUDE.md` (domain-specific only; the project file should **not** restate the global rules, only add project context).
- Layer 2 (permissions) — deny list covers network, destructive Bash, secret reads, cross-project reads, outside-project writes.
- Layer 3 (Claude-time hooks) — both `deny-outside-project.sh` (Write/Edit/NotebookEdit) and `deny-bash-outside-project.sh` (Bash). Closes the read-loophole.
- Layer 4 (git-time hook) — `.githooks/pre-commit` blocks commits matching configured token regexes.
- Scaffold propagates Layers 2 + 3 + 4 to every new project, with optional `git init`.

### Phase 13 — Hardening meets harness skills (the `/fewer-permission-prompts` test)

A new project hardened with the post-audit profile produced two
findings worth recording, plus one open design question.

**Finding 1: `/fewer-permission-prompts` blocked at the hook, correctly.**
The skill scans `~/.claude/projects/<slug>/*.jsonl` to mine common
read-only Bash patterns and propose an allow-list. The Bash hook
denied the scan — `~/.claude/projects/` is outside the project
tree, hook fired exactly as designed, transcript reads were refused.
The skill offered an in-session fallback ("suggest from this
conversation only"), which is the right answer: smaller signal, no
boundary crossed. Take-away: **harness skills that need
`~/.claude/**` access are incompatible with the strict scoping by
construction, and that's fine.** Use the in-session fallback they
offer; do not relax the hook for skill convenience.

**Finding 2: model-side misattribution under deny-heavy regimes.**
While testing in the same project, Bash prompts kept getting denied
(default `ask` mode, no curated allow list yet) while in-project
`Read` calls had session-cached approval. The session's assistant
narrated this as *"permissions tightened mid-session"* — a clean
hallucination explaining the asymmetry. The actual mechanism (Read
got approved earlier in the session, Bash always re-prompts) wasn't
recognised. Pattern is broader than this project: **a model under a
deny-heavy regime will sometimes invent a story for the friction
rather than recognising the permission-prompt mechanism.** Worth
noting because it can shape downstream decisions — here the
misdiagnosis nudged the assistant toward defensive Edit-without-Read
sequences, which is not the failure mode the hardening was designed
to encourage.

**Open question — should the hook recognise the project's own
transcripts as in-scope?** Project transcripts live at
`~/.claude/projects/<slug>/*.jsonl` — physically outside the project
tree, but logically project data (the harness writes them as a
record of *this project's* sessions). The current setup blocks them
as part of the broader `~/.claude/**` block. That's
conservative-but-correct under the current design: the model never
needs to re-read these during normal operation (live context lives
in memory, `/compact` summarises in-place, `/resume` loads them
through harness code paths the hook doesn't intercept), so blocking
them costs nothing in normal use — and the only case that breaks
(`/fewer-permission-prompts`) has a fallback. Approaches if this
proves inconvenient later:

1. **Status quo — keep strict, document the trade-off.** Skills that
   want broader signal use their in-session fallback. Simplest;
   no per-project hook logic. Current default.
2. **Static per-project carve-out via `SAFE_PATH_PREFIXES`.** Edit
   the hook in a specific project to allow
   `~/.claude/projects/-Users-<…>-<project-name>/`. Easy, but
   manual; the path encodes the project location, so it breaks if
   the project moves.
3. **Slug-derived auto-allow.** Compute the slug from
   `$CLAUDE_PROJECT_DIR` at hook-run time (replace `/` with `-`)
   and allow that one transcript directory. Tracks the project
   automatically, but adds Claude-Code-specific knowledge to the
   hook (the slug-derivation rule). Worth doing only if option 2
   gets used in more than one project.
4. **Make the carve-out skill-specific, not path-specific.** Don't
   change the hook; instead, when a skill needs transcripts, run
   it manually with a temporarily-relaxed permission profile, then
   revert. Avoids encoding harness internals into the hook at the
   cost of session-level operational toil.

Leaning toward option 1 until evidence accumulates that more than
one skill needs this. Revisit if a second skill bumps into the same
boundary.

### Phase 15 — Tool-scoped denies don't reach subprocesses (`.env` case)

Found preventively while checking whether a claim held up, not by
observing a leak. In a hardened project, a file was placed on the
assumption that it "shouldn't be readable to coding agents." Checking
that assumption against the actual controls showed the two relevant
mechanisms left a hole between them.

**The gap.** `settings.json` denies `Read(./.env*)` and
`Read(./**/.env*)`, and that deny genuinely works — a probe file was
refused with *"File is in a directory that is denied by your permission
settings."* But it binds only the **Read tool**. The Bash hook, meanwhile,
enforces only the *project boundary*: paths resolving outside
`$CLAUDE_PROJECT_DIR`. An in-project `.env` file satisfies both — the
Read deny doesn't apply to Bash, and the boundary hook allows in-project
paths by design. Neither was buggy; the file simply fell between their
scopes. A plain `cat <in-project>/.env*` reached the contents, and the
only thing left standing was the global CLAUDE.md line *"Bash is not an
escape hatch for Read denies"* — policy, not enforcement, effective only
while the model complies.

**Why this counts as an inconsistency rather than a nitpick.**
`settings.json` already denies `printenv`, `env`, and `history` — the
config's intent to stop secret leakage *through Bash* was already
expressed. Environment variables were mechanically blocked; the files
holding those same values were not. The fix makes the Bash side
consistent with intent that was already there.

**Fix applied.** A second, independent guard at the bottom of the Bash
hook mirroring the `.env*` globs. Deliberately separate from the
boundary scan above it: it applies to **in-project** paths (which the
scan allows by design) and does **not** skip regex-looking arguments,
since a secrets guard should err toward refusing. Matching is on path
*components*, so `a/b/.env.local` is caught while `environment` and
`--env-file` are not. It tracks the Read glob exactly — a committed
`.env.example` is blocked too; a template meant to stay readable is
named so it doesn't lead with `.env` (e.g. `foo.env.example`). It blocks
path *references* rather than trying to enumerate which subcommands read
content; a script that loads a `.env` internally is unaffected, since the
path never appears on the command line.

Known limit: the joined form `--env-file=.env` tokenizes as a single
argument with no `.env`-leading component and passes; the
space-separated form is caught. Same category as the pre-existing
constructed-path and command-substitution limits.

Six behaviour tests lock in the heuristic and both intentional
non-matches, so the guard can't silently loosen or start over-blocking.
The drift check did its job — the `newproj-safe` heredoc was updated
only because the test caught the mismatch.

**Lesson — scope-gap analysis between controls.** Both mechanisms were
individually correct and individually tested. The hole existed only in
the space *between* their scopes, which is exactly what per-control
review doesn't surface. The generalizable question: for each control,
what does it bind to (a tool? a path class? a command?), and does
anything a neighbouring control was meant to protect fall outside all of
them? Here the answer was "a tool-scoped deny doesn't survive the jump
to a subprocess" — a shape likely to recur wherever a Layer 2 pattern
deny protects something Bash can also reach.

**Method note.** The gap was identified by comparing the two mechanisms'
declared scopes, not by executing the bypass — attempting it is what the
rule forbids. Preventive findings like this should be raised as a caveat
for the operator to decide on, not acted on unilaterally.


### Phase 16 — One wrapper voided the whole Bash side

Found by re-reading a session transcript from another of my projects,
one running this profile, and checking whether everything the agent did
in it was according to the rules.

The profile was live there. The agent tried to write an auto-memory
file, was refused, and reported *"the project's deny-outside-project
hook blocks writes to the memory directory"*, then asked whether to put
the note in `CLAUDE.md` instead. That names the file-path hook; both
hooks register from the same `settings.json`, so the Bash hook was
loaded in that session too.

**What happened.** The agent couldn't run the test suite — `node`, `npm`
and `npx` weren't on the Bash tool's `PATH`, so every run went: agent
prints the commands, I run them in my terminal, I paste the output back.
After several rounds I told it to fix that and test its own changes from
then on. It found the cause — nvm puts node on `PATH` from `~/.zshrc`,
which only interactive shells read, and the Bash tool doesn't get one —
and settled on `zsh -ic '<cmd>'`. From then on it ran everything that
way: tests, typecheck, build, `npm install`. It worked, and I was
satisfied with it at the time.

`zsh -ic` is also a general-purpose re-entry into the shell. Every one
of those calls ran against a live copy of this profile and was allowed:

```
ALLOW  zsh -ic 'printenv'                   ← Bash(printenv:*) is denied
ALLOW  zsh -ic 'history'                    ← Bash(history:*) is denied
ALLOW  zsh -ic 'git push'                   ← Bash(git push:*) is denied
ALLOW  zsh -ic 'curl example.com'           ← Bash(curl:*) is denied
ALLOW  zsh -ic 'cat ~/.ssh/id_rsa | head'   ← rule 1, project boundary
ALLOW  zsh -ic 'cat .env.local'             ← rule 2, the Phase 15 guard
ALLOW  command cat /etc/passwd              ← rule 1 again, via a runner
```

Every rule the Bash side has, defeated by one wrapper. I expected the
command denies to fall, since the harness matches on the first word and
that is now `zsh`. I did not expect the path scan to fall with them. It
does: the inner script is a single quoted token, so an operator anywhere
inside it (`| head`) puts a `|` into that token and the `REGEX_META`
skip discards the whole script as a regex pattern argument. That's the
Phase 11 bypass one quoting level down — `punctuation_chars=True` splits
operators only at the level shlex is parsing, and inside a quoted
argument the Phase 9 metacharacter skip then throws the argument away.
Two fixes, each correct alone, with a hole between them; the same shape
as Phase 15.

One case nearly hid it. `zsh -ic 'curl https://example.com'` *was*
blocked, but not because of `curl`: `://` matches the path regex's
`(?<=:)` lookbehind, so `//example.com` resolved outside the project.
Drop the scheme and it passes.

**Fix.** Recursively extract inner scripts from shell wrappers and
runner prefixes (`env`, `xargs`, `nohup`, `command`, `sudo`), then scan
each as its own top-level command. That alone restores the boundary and
`.env` rules at every nesting level, since a script scanned at the top
level tokenizes normally. It also closed `command cat /etc/passwd`, open
for a duller reason: `command` is in `SAFE_FIRST_WORDS`, so the whole
call took the early exit.

Then a third rule for the command denies. Copying the deny list into the
hook would duplicate what the drift test exists to catch and go stale on
the first edit to `settings.json`, so the hook **reads the deny entries
out of `settings.json` at run time** and re-applies the `Bash(...)` ones
to extracted scripts — extracted scripts only, since bare commands are
the harness's job. The hook also now **fails closed**: an internal
error, or a `settings.json` that doesn't parse, blocks rather than
passes.

The old hook had no shell awareness at all — `bash -c`, `sh -c`,
`dash -c` and `ksh -c` behaved exactly like `zsh -ic`. So the wrapper
list covers every shell, and the script argument is found by scanning to
the end of the arguments for a `-c`-bearing flag. My first version
stopped at the first non-flag argument, which let `bash -o pipefail -c`
and the multi-call form `busybox sh -c` through.

**A second bypass, found while testing the first.** Checking that the
`echo hi 2>/dev/null` allowance still held, I tried a two-command line:

```
ALLOW  echo one; cat /etc/hosts     ← against the PREVIOUS committed hook
ALLOW  true && cat /etc/hosts
ALLOW  echo hi > /etc/passwd
```

These are plain command chains with a separate cause, so unwrapping
doesn't touch them: `SAFE_FIRST_WORDS` took the first word of the
*whole line* and skipped everything after it, so one `echo` vouched for
anything chained behind it. It has been in the hook since Phase 3
and survived Phase 9, Phase 11 and the Phase 13 audit, because every
test case I had written was a single command. Fixed by splitting each
line into its component commands and judging each on its own first word,
with redirection operators counting as separators so a target is never
covered by whatever wrote to it. Unquoted newlines needed handling too —
shell ends a command at a newline, shlex treats it as whitespace — so a
pass now rewrites them to `;` outside quotes. The wrapper bypass at
least needed an unusual command shape; this one needed `echo` and a
semicolon.

**Root cause (Lesson 8).** The toolchain wasn't on `PATH` and nothing
offered a sanctioned way to put it there, so the agent built its own
route and took a layer down with it. The fix therefore ships with the
alternative: a README recipe for putting a version-manager toolchain on
`PATH` via the `env` block in `settings.json`. The wrapper rule still
allows `zsh -ic 'npx vitest run'` — the profile has no quarrel with
running tests.

**Three other things from the same session.**

*Worktree-discard was half-covered.* `git checkout -- package-lock.json`
and `git stash push -u` both ran unblocked while `git reset --hard` was
denied — an inconsistency rather than a policy. Added `git clean`,
`git restore`, `git checkout --` and `git checkout .`. It costs
something: under the new deny the agent couldn't have restored that
lockfile itself and would have had to ask me. Kept anyway, because
discarding uncommitted work should need a human, and `git stash` stays
allowed as the non-destructive way to get the same answer.

*Package managers are an unacknowledged egress and code-execution
channel.* The only thing in the session that caused damage was a bare
`npm install`: it re-resolved the tree, moved `@supabase/supabase-js`
sixty minor versions inside its caret range, and broke three untouched
files. `npm`, `npx`, `pip`, `go` and `gh` all fetch and run remote code,
and several can upload. Denying them isn't on the table — that's the
over-restriction trap. Documented in the threat model, with a Layer 1
line asking for lockfile-respecting installs and a diff check afterwards.
Enforcement would need the container.

*Two things worth recording as working.* The memory-write refusal above
is one — a counter-example to Phase 13's Finding 2, where a model
invented "permissions tightened mid-session" for the same class of
friction; here the attribution was exact. The other:
`npm run test:live:email` loaded `.env.live-test` internally, which the
Phase 15 guard allows by design because the path never reaches the
command line, and that project had its own test asserting the SMTP
password never lands in an error string. That's the division of labour
Phase 15 implied — the hook blocks path *references*, and keeping
*values* out of the transcript is the program's job. Now said in the
README.

**Lesson — a control binds to a syntactic position, and a subshell
resets it.** Phase 15: a tool-scoped deny doesn't survive the jump to a
subprocess. Here: Layer 2 binds to a command's *first word*, and
anything that spawns a shell supplies a new one. Twice makes it a class,
and it strengthens the Phase 13 argument for moving boundary-shaped
rules out of the deny list and into the hooks. The deny list is still
the right home for *what* is forbidden — rule 3 reads it as the source
of truth. What it can't be trusted with is *noticing* the forbidden
thing under a different first word.

**Lesson — re-read sessions, not just probes.** The bypass ran a dozen
times in a hardened project across a session I read at the time and was
pleased with, and several rounds of adversarial self-review hadn't found
it. Probing asks what an attacker would do; re-reading asks what the
agent actually did and whether all of it was inside the rules. The
second question found more. Related: every claim here came from a hook
invocation with an exit code. I wrote down the opposite expectation
first and was wrong on both halves, and the `curl https://…` case would
have confirmed the wrong model if I'd taken it at face value. The same
trap applies to the tests — `/bin/bash -c 'printenv'` is blocked by the
boundary rule, not the deny — so `run_case` now asserts which rule
fired.

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
Shell-wrapper re-entry ← Layer 3b rule 3 (Phase 16)        — best-effort, enforced
Package-manager fetch  ← (uncovered — needs container)
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
- Skills that mine `~/.claude/projects/**` transcripts (e.g.
`/fewer-permission-prompts`) cannot do their cross-session scan;
they fall back to in-session evidence. Smaller signal, no
hardening change needed.
- Denied commands can't be reached through `sh -c` / `zsh -ic` /
`env` (Phase 16). Wrappers themselves stay usable — only a denied
*inner* command is refused — but a version-manager toolchain should
be put on `PATH` via the `env` block in `settings.json` rather than
reached with `zsh -ic`. See the README recipe.
- Worktree-discard commands (`git clean`, `git restore`,
`git checkout --`, `git checkout .`) are denied alongside
`git reset --hard`. `git stash` remains available, which covers the
legitimate "did this failure predate my changes?" workflow.


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
11. **Every control binds to a syntactic position, and something can usually reset it.** A tool-scoped deny doesn't survive the jump to a subprocess (Phase 15); a command deny binds to the first word, and any subshell supplies a new one (Phase 16). When adding a control, ask what it binds to and what could change that thing without changing the intent.
12. **Re-read sessions, not just probes.** The Phase 16 bypass ran unnoticed for a whole session in a hardened project of mine, doing a task I had asked for. Probing tests the attacks you already imagined; re-reading a session that went well asks the duller question — *was all of that inside the rules?* — and an agent working around an obstacle produces exactly the shapes the heuristics weren't written for.