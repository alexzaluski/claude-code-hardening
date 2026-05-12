# claude-code-hardening

> Hardening profile for [Claude Code](https://www.anthropic.com/claude-code) on sensitive projects: four enforcement layers plus a scaffold.

**Scope:** Claude Code CLI on Pro / Max (OAuth) — API-key auth should work too since the hardening targets the harness, not the credential. Doesn't apply to direct Anthropic SDK programs (no `~/.claude/`, no hooks); concepts carry, files don't.
**Platforms:** Tested on macOS (VS Code extension). Shell scripts are POSIX, should work on Linux. Windows: use WSL.
**Version:** Built on Claude Code `2.1.120`. Hook API and settings schema may drift across versions.

For the full build history (decisions, bugs, dead-ends), see [HISTORY.md](HISTORY.md).

---

## Why I built this

I wanted to understand where my data actually goes when I use an agentic coding tool like Claude Code, and then build a scaffold so I don't have to re-think it for every new project.

Claude Code works by reading files and sending their contents to Anthropic on every turn, with each turn also written to a local transcript on disk. Out of the box, nothing stops it from reading outside the current project, sending data to third-party services, or letting sensitive tokens drift into git history — and such actions often stay hidden unless you go digging through the transcript.

By default, project data can flow in four directions, none of them blocked or even reliably constrained:

1. **To Anthropic.** Every file Claude reads is sent off-machine on the next turn, then re-sent on every subsequent turn it stays in context. The same content lands in a plaintext transcript on disk that persists across sessions until you prune it.
2. **To third-party services.** Claude-invoked HTTP tools (`WebFetch`, `WebSearch`, `curl`, `wget`, `nc`) can post project data to any URL the model decides on. Nothing constrains the destination by default.
3. **To other projects on the same machine.** Nothing in the default configuration scopes Claude's filesystem access to the current project — it can read from neighbouring projects via the `Read` tool or via Bash subprocesses (`cat`, `grep`, …). On top of that, shared `~/.claude/**` state — auto-memory and plan mode — silently carries context between sessions you thought were unrelated.
4. **To public git history.** Tokens or identifiers in source data can slip into commits, notes, or reports — and once pushed, they're effectively permanent: any clone or mirror will carry the leak even if you rewrite history afterwards.

This repo packages a four-layer profile that constrains those flows at the harness level, where the model can't drift past them. Disk encryption, access control, and what happens before Claude is involved are out of scope.

> **What about a container?** Didn't fit a solo, local-data workflow, but it's not settled. See [Containerisation](#containerisation).

## Threat model

Here's what the four layers catch and what they don't protect against.

### Protected (high confidence)

- Model-initiated outside-project writes (denies + Write hook)
- Model-initiated outside-project Bash reads (denies + Bash hook),
  with the documented adversarial-pattern caveat
- Known secret paths: `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.config/gh`,
  `.env*`, `*.pem`, `*.key`
- Claude-invoked network egress
- Common destructive footguns
- Configured tokens reaching git history

### Not protected (residual risk)

- **Transcripts and file-history.** Written by the harness itself, not via the `Write` tool — hooks/denies are blind. Mitigations: disk encryption, periodic deletion, retention settings.
- **Adversarial Bash patterns.** Paths inside `$(...)`, quoted script literals, or env-var-constructed. The Bash hook is heuristic.
- **Symlinks into the project from outside.** A symlink at `/tmp/foo` → `<project>/secret` resolves as in-project. Hole in the abstraction, not exploitable by the model alone.
- **Subprocess-initiated I/O.** A Python/Node script started by Claude inherits process privileges; a poisoned dependency bypasses Layers 2–3. Needs OS-level isolation (container with `--network=none`).
- **Inference itself + provider-side retention.** Every turn reaches Anthropic; Pro/Max has no Zero Data Retention.
- **Compromised host.** A malicious process running as your user sees what Claude sees.
- **Harness-version drift.** The declarative deny list's semantics are interpreted by Claude Code, not by this repo. A version bump can silently change how a rule matches — Phase 13 in [HISTORY.md](HISTORY.md) documents `Read(~/**)` shifting from "blocks cross-project reads" to "blocks every project file when the project is under `~`," with no warning or release-note flag. Hook-based enforcement (Layer 3) is more robust here because the matching logic lives in code we control. The test suite's *forbidden-patterns* assertion guards against silent reintroduction of known-bad rules but cannot predict future semantic drift.

See [HISTORY.md](HISTORY.md) for the security analysis in more depth.

## The four layers

Each closes a different way data could otherwise flow out of the
project:

| # | Layer | Mechanism | What it constrains |
|---|---|---|---|
| 1 | **Prompt** | `CLAUDE.md` (global + project) | Posture-setting and rules the harness layers can't express; advisory |
| 2 | **Permissions** | `.claude/settings.json` `permissions.deny` | Reads from outside the project tree, network-egress tools (`WebFetch`/`WebSearch`/`curl`/`wget`/`nc`), destructive shell, writes into `~/.claude/**` (auto-memory, plan mode) and the `/tmp` family |
| 3 | **Hooks (Claude-time)** | Two `PreToolUse` hooks: one for `Write\|Edit\|NotebookEdit\|Read`, one for `Bash` | Generic catch for what the static patterns missed — enforces the project boundary on every file-path-bearing tool call (Read, Write, Edit, NotebookEdit) plus every Bash command, via `realpath` against `$CLAUDE_PROJECT_DIR` |
| 4 | **Hooks (git-time)** | `.githooks/pre-commit` with project-specific token regexes | Tokens or identifiers carried in source data reaching a public commit |

Layers 2–4 cost zero tokens per turn; Layer 1 carries only the
rules the harness can't enforce on its own.

## What's included

```
.
├── README.md                                          ← this file
├── HISTORY.md                                         ← build history, lessons, decisions
├── SECURITY.md                                        ← reporting + scope (process only)
├── newproj-safe                                       ← scaffold script (install to ~/bin)
├── tests/
│   └── test_hooks.sh                                  ← hook behaviour + drift + invariants checks
└── templates/
    ├── global/                                        ← copy into ~/.claude/
    │   ├── settings.json                              ← universal denies (apply everywhere)
    │   └── CLAUDE.md                                  ← privacy posture rules for all projects
    └── project/                                       ← `newproj-safe` materialises this per project
        ├── CLAUDE.md                                  ← project scope header
        ├── .gitignore
        ├── .claude/
        │   ├── settings.json                          ← project deny list + hook registrations
        │   └── hooks/
        │       ├── deny-outside-project.sh            ← Read/Write/Edit/NotebookEdit guard
        │       └── deny-bash-outside-project.sh       ← Bash path guard
        └── .githooks/
            └── pre-commit                             ← token-pattern blocker
```

The split mirrors the **global vs project scope** distinction the
README returns to throughout: `templates/global/` carries rules that
should apply to every Claude Code session you ever run; `templates/project/`
carries everything that's per-project. Run `newproj-safe <path>` to
materialise the project-side templates into a fresh directory; the
global-side files are copied manually into `~/.claude/` once.

> **Note on layout.** The repo's structure does not mirror what a
> scaffolded project looks like — same convention GitHub template
> repositories use. Files inside `templates/project/` map 1:1 onto
> the root of a freshly scaffolded project, and `templates/global/`
> maps onto `~/.claude/`.

## Getting started

### Prerequisites

- **OS**: macOS or Linux (Windows: use WSL)
- **Shell**: `bash` or `zsh`
- **`python3` on `PATH`** — both PreToolUse hooks shell out to it.
  macOS: ships with Xcode CLT (`xcode-select --install`) or
  `brew install python`. Debian/Ubuntu: `sudo apt install python3`.
  Fedora/RHEL: `sudo dnf install python3`.
- **Disk encryption** — transcripts land plaintext under `~/.claude/`,
  so encryption-at-rest is the only mitigation against a cold-machine
  attacker. Use whatever your OS provides (FileVault, LUKS, BitLocker).
- **(Optional) `gitleaks`** for periodic full-repo scans.
  macOS: `brew install gitleaks`. Linux: distro package or
  download a release from the project's GitHub.

### Verify after clone

Executable bits can be dropped by some git clients and zip downloads. Confirm:

```bash
ls -l newproj-safe templates/project/.claude/hooks/*.sh templates/project/.githooks/pre-commit
# All should be -rwxr-xr-x. If not:
chmod +x newproj-safe templates/project/.claude/hooks/*.sh templates/project/.githooks/pre-commit
```

### Install the scaffold

```bash
mkdir -p ~/bin
cp newproj-safe ~/bin/
chmod +x ~/bin/newproj-safe
grep -q 'HOME/bin' ~/.zshrc || echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

### Install the global templates (one-time, optional but recommended)

Apply to every Claude Code session. Diff first if you already have personal customisations in `~/.claude/`:

```bash
mkdir -p ~/.claude
diff templates/global/settings.json ~/.claude/settings.json 2>/dev/null
diff templates/global/CLAUDE.md     ~/.claude/CLAUDE.md     2>/dev/null
cp templates/global/settings.json ~/.claude/settings.json
cp templates/global/CLAUDE.md     ~/.claude/CLAUDE.md
```

The shipped global `CLAUDE.md` carries only privacy/security rules — extend it with your own preferences.

### Create a hardened project

```bash
cd ~/somewhere
newproj-safe my-project          # → creates ./my-project/
cd my-project
```

The scaffold prompts `Initialize a fresh git repository? [Y/n]`.

- **Answer Y** for new projects. The scaffold runs `git init -q` and
  then `git config core.hooksPath .githooks`, which tells git to look
  for hooks in this project's tracked `.githooks/` directory instead
  of the default `.git/hooks/`. That way the pre-commit token blocker
  ships with the repo and follows every clone, instead of being a
  per-machine secret.
- **Answer N** if you'll be importing an existing `.git/`. After
  dropping the old `.git/` in place, run
  `git config core.hooksPath .githooks` manually — without this, the
  pre-commit hook never fires.

### What's tracked, what's local

The scaffold creates four guardrail files: `.claude/settings.json`,
`.claude/hooks/*.sh`, `.githooks/pre-commit`, and `CLAUDE.md`. All
four are meant to be committed — the deny list and hook scripts have
to ship with the repo for the profile to apply, the pre-commit hook
is what makes Layer 4 work, and `CLAUDE.md` carries project context
that belongs alongside the code.

Personal additions go in `.claude/settings.local.json` (gitignored
by the shipped `.gitignore`). Claude Code merges it on top of
`settings.json`, so it's a useful place for extra denies you only
want on your own machine, or non-permission preferences. To relax
a project-level deny instead, edit `settings.json` itself; see
[Relaxing denies](#relaxing-denies-for-a-project-that-legitimately-needs-them).

One thing worth keeping in mind: editing a hook script or the deny
list changes what the model is allowed to do. Commenting out a deny
pattern removes that protection; adding a path to a hook's safe-paths
list lets reads through that the hook used to block. Nothing about
the running profile signals the gap afterwards — the only place it
shows is in the diff. Treat diffs to `.claude/` and `.githooks/` the
same way you'd treat a change to auth code.

### Review the guardrails before first launch

Open each of the following files and skim it before launching Claude
for the first time. Some of the shipped deny patterns will be stricter
than a given project actually needs, and the pre-commit hook ships
with all token patterns commented out — both call for project-specific
decisions:

- `.claude/settings.json` — the deny list (relax patterns the project
  legitimately needs)
- `.claude/hooks/deny-outside-project.sh` and
  `.claude/hooks/deny-bash-outside-project.sh` — confirm the heuristics
  fit how this project will use Claude
- `.githooks/pre-commit` — uncomment regex patterns matching token
  classes the project handles
- `CLAUDE.md` — add project-specific scope notes

### First-launch sanity test

In a fresh `claude` session, ask the assistant to:

1. Write to `/tmp/test.txt` → blocked by deny list
2. Write to `~/Documents/test.txt` → blocked by hook
3. Write to a file inside the project → succeeds
4. `WebFetch https://example.com` → blocked
5. `cat /etc/hosts` → blocked by Bash hook
6. (If you uncommented a token pattern in `.githooks/pre-commit`)
   stage a fake-token file and `git commit` → blocked

If any of 1–5 don't behave: confirm hooks are `-rwxr-xr-x` and
restart Claude (hooks register at session start, not per-message).

## How it works

### Layer 1 — Prompt (`CLAUDE.md`)

Global `~/.claude/CLAUDE.md` carries durable preferences (privacy
posture, response style, security defaults). Project `CLAUDE.md`
carries domain facts that can't be derived from the code (what the
data is, conventions, decisions already made). They layer; they don't
duplicate.

The prompt layer is **advisory** — the model can drift, and a
harness subsystem (plan mode, auto-memory) will sometimes override
it. Don't put security-critical rules here that the harness can
enforce instead.

### Layer 2 — Permissions (`.claude/settings.json`)

Static deny patterns. The harness intercepts each tool call before
it fires. Categories included by default:

- **Network egress**: `WebFetch`, `WebSearch`, `Bash(curl:*)`,
  `wget`, `nc`, `ssh`, `scp`, `rsync`
- **Destructive shell**: `Bash(rm -rf /:*)`, `Bash(rm -rf ~/:*)`,
  `Bash(git push:*)`, `Bash(git reset --hard:*)`
- **Secret reads**: `Read(./.env*)`, `Read(./**/*.pem)`, `*.key`
- **Cross-project reads**: `Read(../**)` (Read tool, parent-relative); the Bash hook covers absolute paths via `realpath` against `$CLAUDE_PROJECT_DIR`
- **Outside-project writes**: `Write(~/.claude/**)` + Edit /
  NotebookEdit equivalents, `/tmp/**` family

Pattern syntax is glob-style; `~` expands. `Bash(<cmd>:*)` matches
any args. See the file at
[templates/project/.claude/settings.json](templates/project/.claude/settings.json)
for the full list.

### Layer 3 — Hooks (Claude-time)

Two `PreToolUse` hooks plug the holes Layer 2 misses:

**`deny-outside-project.sh`** matches `Write|Edit|NotebookEdit|Read`.
Reads the tool-call JSON from stdin, extracts `file_path` (or
`notebook_path`), resolves to a realpath, exits 2 with a `BLOCKED`
message if the target is outside `$CLAUDE_PROJECT_DIR`. Same logic
for all four tools — catches any outside-project write the deny list
didn't enumerate, and closes the Read-tool gap left when `Read(~/**)`
was removed (see HISTORY phase 13).

**`deny-bash-outside-project.sh`** matches `Bash`. Parses the command, extracts path-looking tokens (start with `/`, `~`, or `./`), realpath-resolves each, blocks anything outside the project. Has three allow-lists (safe first-words like `echo`/`realpath`, kernel devices like `/dev/null`, regex-pattern arguments via `shlex`) and one opt-in `SAFE_PATH_PREFIXES` that restores `run_in_background` at the cost of allowing reads under `/private/tmp/claude-*`. See the script header for the full lists.

This is **defense-in-depth, not a fortress**. Paths inside command
substitutions (`cat $(cmd)`), inside quoted script literals
(`python3 -c 'open("/etc/x")'`), or constructed via env vars set
in the same line will leak through. The Layer 1 prompt asks the
model to respect spirit-of-the-law for those.

### Layer 4 — Hook (git-time)

`.githooks/pre-commit` scans only the *added* lines in staged
content for configured regex patterns; rejects the commit on match.
Runs at `git commit` — independent of Claude entirely. Zero token
cost. Bypassable by `--no-verify`, so a safety net rather than an
authorization boundary.

The shipped template has its patterns array commented out by
default. **Enabling it is a per-project decision** because the
right patterns depend on what data the project handles. See
[Customization](#customization) for examples.

Activation requires running `git config core.hooksPath .githooks`
once in the project — that setting lives in `.git/config`, which
isn't tracked in the repo, so it has to be set locally rather than
inherited from the scaffold's templates. The scaffold runs it for
you when you accept the `git init` prompt.

If the repo lives on GitHub or GitLab, enable their server-side
secret scanning / push protection too — it catches what
`--no-verify` or an unconfigured clone would slip past.

## Customization

### Token patterns for the pre-commit hook

Uncomment / extend the patterns array in `.githooks/pre-commit`.
Common classes below — token formats might change over time, so it's better to check the service's current docs before relying on a regex:

| Class | Regex |
|---|---|
| AWS access keys (long-lived / STS) | `AKIA[0-9A-Z]{16}` / `ASIA[0-9A-Z]{16}` |
| GitHub PATs (classic) | `ghp_[A-Za-z0-9]{36}` |
| GitHub fine-grained PATs | `github_pat_[A-Za-z0-9_]{82}` |
| Slack tokens | `xox[baprs]-[A-Za-z0-9-]+` |
| Stripe live keys | `sk_live_[A-Za-z0-9]+` / `rk_live_[A-Za-z0-9]+` |
| Google API keys | `AIza[0-9A-Za-z_-]{35}` |
| npm tokens | `npm_[A-Za-z0-9]{36}` |
| OpenAI-style API keys | `sk-[A-Za-z0-9]{32,}` |
| Anthropic API keys | `sk-ant-[A-Za-z0-9_-]{90,}` |
| JWTs | `eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+` |
| Vendor archive tokens (Meta `EAA*`, etc.) | project-specific |
| Internal IDs (employee, customer, patient, …) | project-specific |

The right list is whatever the project's *data* would expose if
committed by accident.

### Relaxing denies for a project that legitimately needs them

Some projects will hit a deny that's blocking legitimate work — a
sibling directory that genuinely needs reading, a `curl` that's part
of the build, a `git push` that gets old after the tenth approval
prompt. The mechanism for relaxing is just to delete the offending
line from `.claude/settings.json`; there's no separate toggle.

The risk is deleting blindly. The denials aren't equivalent — some
open privacy paths, some only restore convenience. Use the table
below to see which is which before removing anything.

| Deny entry | What enabling actually opens | Cost class |
|---|---|---|
| `WebFetch`, `WebSearch`, `Bash(curl:*)`, `Bash(wget:*)`, `Bash(nc:*)` | Path 2 — Claude can post project data to any third-party URL | **high (privacy)** |
| `Read(../**)` + the `Bash` PreToolUse hook | Path 3 — cross-project reads of any other project on the machine | **high (privacy)** |
| `Write(~/.claude/**)` family | Persistent shared state (auto-memory, plan files) carrying project context across sessions and projects | **medium (privacy)** |
| Background-task opt-in (`SAFE_PATH_PREFIXES` in the Bash hook) | Reads from anything any process writes under `/private/tmp/claude-*`. Restores `run_in_background`. | **medium (read surface)** |
| `Bash(git push:*)` | Removes the manual-push speed bump | **low (undo cost)** |
| `Bash(git reset --hard:*)` | Lost local work if the model misuses it | **low (undo cost)** |
| `Bash(rm -rf /:*)`, `Bash(rm -rf ~/:*)` | Catastrophic accidents | **low (no privacy cost; only blast radius)** |

Two pieces of guidance that hold across all of them:

- **Relax per-project, not globally.** Approving the same prompt over
  and over is the failure mode that pushes a setup toward disabling
  the deny entirely. Better to relax the pattern once, deliberately,
  in the file that owns it.
- **The high-cost rows are the ones doing the actual privacy work.**
  Disabling them by default collapses most of what the four layers
  are for; at that point the question is whether this setup fits the
  project at all, not whether to keep relaxing it.

### Disabling a hook

A hook may turn out to be a poor fit for a particular project — for
example, a monorepo where Claude legitimately needs to read sibling
directories, or a build step that legitimately writes under `/tmp`.
Two clean ways to disable: delete the hook script, or remove its
matcher block from `.claude/settings.json`. The static deny list
still covers the common targets either way.

Editing the hook script to carve out specific paths is the option I'd
avoid: a hook that accumulates per-path exceptions stops being a
generic guard and turns into a second deny list, harder to reason
about than the original. When a specific path is legitimately needed,
relaxing the matching `Read` / `Write` deny pattern is the cleaner
change.

## Global vs project scope

Both `~/.claude/settings.json` and `<project>/.claude/settings.json`
exist; deny lists from both **merge** (a global deny can't be
"allowed" from a project file). Split:

| Belongs in `~/.claude/settings.json` (global) | Belongs in `<project>/.claude/settings.json` |
|---|---|
| Universal denies you never want to relax: `Bash(rm -rf /:*)`, `Bash(rm -rf ~/:*)`, `Bash(sudo:*)`, `Read(~/.ssh/**)`, `Read(~/.aws/**)`, `Read(~/.gnupg/**)`, `Read(~/.config/gh/**)`, `Write(~/.claude/**)` + Edit/NotebookEdit equivalents | Everything project-shaped: `Read(../**)`, `Read(./.env*)` family, `WebFetch`/`WebSearch`, `Write(/tmp/**)` family, `Bash(curl:*)`/`wget`/`nc`/`ssh`/`scp`/`rsync`, **the two `PreToolUse` hook entries** |
| Things that depend on *who you are* | Things that depend on *what data the project handles* |

**Don't copy the project file verbatim into the global file.** Two
failure modes:

1. **Hook commands break in non-scaffolded projects.** The hook
   entries reference `$CLAUDE_PROJECT_DIR/.claude/hooks/deny-...`.
   That env var resolves per-session. The moment you `claude` into a
   project that doesn't have the scaffold, the script doesn't exist
   and every Write/Edit/Bash call fails the precondition.
2. **Over-restriction in legitimate work.** Globalizing
   `Read(../**)`, `WebFetch`, or `Bash(curl:*)` blocks routine work
   in non-sensitive side projects.

After changing either scope, **restart any open Claude session** —
settings register at session start.

## Verification

Run the [first-launch sanity test](#first-launch-sanity-test) above
in any new project. The same checks work as a regression test after
upgrading the scaffold or editing hooks.

For a code-grounded audit of an existing project, ask Claude to
attempt the seven probes from the test list and report results. The
audit doesn't need privileged access — every probe is a normal tool
call that the harness either allows or blocks.

If you're editing the hook scripts or the `newproj-safe` heredocs in
this repo, run the bundled regression test before publishing:

```bash
bash tests/test_hooks.sh
```

The suite runs in three layers (26 checks at time of writing; expects all green):

1. **Behaviour** — exercises the Bash hook against ten cases: the boring positives (in-project read allowed, outside-project read blocked), three regex/kernel-device false-positive shapes that have previously broken the hook, and four regression cases for the Phase 11 no-whitespace shell-operator bypass (`cat /etc/passwd|head`, `... ;...`, `... </...`, `(cat /etc/...)`).
2. **Drift** — verifies that the heredoc bodies inside `newproj-safe` match the standalone template files in `templates/project/` byte-for-byte. Catches "edited one, forgot to update the other."
3. **Invariants** — JSON validity for every shipped `settings.json`, executability for every hook script, a **forbidden-patterns** assertion (entries we deliberately removed and never want to see reintroduced — currently `Read(~/**)` with the Phase 13 reason inline), and a **required-patterns** assertion (audit-driven additions like `Bash(history:*)` and the key-file globs that would be load-bearing losses if silently dropped).

What the suite still does *not* cover: `CLAUDE.md` content, pre-commit token patterns, or the per-project decisions that are meant to vary (custom allow lists, project-specific denies). For those, use the [first-launch sanity test](#first-launch-sanity-test) inside the project itself.

The "Invariants" layer was added specifically in response to the `Read(~/**)` over-match in Phase 13 — a rule that was correct when this project was first released started silently matching every project file after a Claude Code update changed how Read-tool paths get normalised. The new assertions can't predict the *next* such shift (a static check can't simulate the harness), but they prevent the matching kind of regression — silent removal of an audit-driven deny, silent reintroduction of a known-bad pattern — from going unnoticed.

## Periodic hygiene

**Close all Claude sessions before deleting anything inside
`~/.claude/`.**

```bash
# Weekly: check disk growth + scan for staged secrets
du -sh ~/.claude/projects ~/.claude/file-history
gitleaks detect --source .   # inside each project before any push

# Monthly: prune transcripts + file-history older than 30 days
find ~/.claude/projects -name '*.jsonl' -mtime +30 -delete
find ~/.claude/file-history -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} +

# Keep only the 5 newest backup files
ls -t ~/.claude/backups/ | tail -n +6 | while read -r f; do rm "$HOME/.claude/backups/$f"; done

# Project ended: wipe its transcripts
SLUG=<absolute-project-path-with-/-replaced-by-->
rm -rf ~/.claude/projects/$SLUG
```

Exit cleanly with `/exit` rather than killing the process — killing
leaves lockfiles behind in `~/.claude/sessions/` and `~/.claude/ide/`.

## Containerisation

For a solo, local-data workflow the gain over hooks + denies 
didn't seem worth the friction to me.
 One thing I hit when sketching a setup: keeping OAuth login
across container rebuilds seems to require bind-mounting `~/.claude/`
into the container, which then has the same access to global Claude
state as the host. A separate in-container install with its own auth
avoids that, at the cost of re-login on every rebuild.

Containerisation is generally worth a look if you install many
third-party dependencies, want OS-enforced network isolation, ingest
externally-authored text that could carry prompt injection, or work
with production credentials or untrusted code execution. How well it
combines with this profile specifically, I haven't tested.

### Angles I haven't tested yet

The OAuth-bind-mount blocker isn't necessarily the end of the road; I just haven't gone past it. Four approaches that look promising on paper:

1. **Named Docker volume for `~/.claude/`** instead of a host
   bind-mount. Auth state lives in a per-container volume, so the
   host's global `~/.claude/` never enters the container. You still
   re-authenticate the first time, then the volume persists across
   rebuilds.
2. **API-key auth instead of OAuth.** API keys travel via
   environment variables, so there's no `~/.claude/` token cache to
   bind-mount in the first place. Trade-off: pay-per-token instead
   of a Pro/Max subscription. Probably the cleanest path if the
   billing model fits.
3. **Network policy as an additive layer**, regardless of the auth
   question. Running the container with `--network=none` plus an
   explicit allowlist for `api.anthropic.com` would be strictly
   tighter than what hooks can offer for the "to third-party
   services" flow. Worth combining with either of the above.
4. **A dedicated low-privilege OS user** for running Claude Code.
   A separate `claude-sandbox` account on the same machine, with
   file access only to the project directory. The kernel enforces
   the boundary on every read, so it would also catch cases where
   a script Claude runs inherits its privileges — something hooks
   can't see into. Likely simpler on Linux than macOS. (Suggested by: [@Bauero](https://github.com/Bauero))

If you've made any of these work, I'd be glad to hear about it.

## Background

The full build history — every failure, every fix, every "it
seemed robust until it wasn't" — lives in [HISTORY.md](HISTORY.md).
Read that for the *why* behind every choice in this README.

## License

Apache 2.0 — see [LICENSE](LICENSE).