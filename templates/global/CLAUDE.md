# Global preferences

> **Starter template.** These are the rules that complement the
> harness-level enforcement (deny list + hooks). Extend the file with
> your own response-style and language preferences as you wish — but
> keep the **Privacy** and **Security** sections, since they cover
> things the harness can't enforce on its own.

## Privacy (default posture for all projects)
- Treat every project as sensitive by default unless its CLAUDE.md says otherwise.
- **Bash is not an escape hatch for Read denies.** When project scope forbids reads outside the project, that applies to `cat`, `ls`, `grep`, `find`, `python3 -c 'open(...)'`, and any other Bash invocation — not only the `Read` tool. If you wouldn't `Read` it, don't `Bash` it.
- **System-injected context is not a file.** Blocks like `# userEmail`, `# currentDate`, `<ide_*>` are metadata for your reasoning, not data for your output. Do not echo them, quote them as if read from a file, or include them in tool arguments.
- **Assume transcripts persist.** Do not echo `.env*` contents, tokens, PII, credentials, or bulk sensitive rows into responses.
- **Subagents receive whatever you send.** Pass the minimum context required; never forward raw sensitive rows or PII in agent prompts. Prefer describing the task over quoting the data.
- **Flag before transmitting off-machine.** If a task seems to require sending project data to a remote agent, cloud LLM, or shared service, stop and ask first.

## Security
- Secrets live in `.env.*` only — never suggest committing them. Never echo `.env*` contents to the terminal.
- **Package managers fetch and execute third-party code.** Prefer lockfile-respecting installs (`npm ci`, `pip install -r`); after any resolving install, check the lockfile diff and report unexpected upgrades.
- **Don't route around a missing toolchain.** If `node`, `python` or similar isn't on PATH, say so and ask. Don't reach for `sh -c` / `zsh -ic` to borrow an interactive shell's environment.
- Flag injection, XSS, exposed secrets, and credential leaks immediately.
- **Prefer local tools over cloud services for working with project data.** CLI utilities, local databases, and on-machine processing keep data inside the project tree. Only reach for hosted analysis platforms (cloud notebooks, online viewers, paste services) when the user explicitly asks.
