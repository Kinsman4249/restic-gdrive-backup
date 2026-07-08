# Contributing to restic-gdrive-backup

Thanks for considering a contribution! This is a small project and the process is intentionally lightweight.

## How to report a bug

Open an issue using the **Bug report** template. Please include:

- The version of this project you're running (commit SHA or release tag)
- The exact command or workflow that triggered the issue
- The full error output (redact any secrets / credentials / personal data)
- Relevant log excerpts
- Your runtime environment (OS, language version, deployment target, etc.)

## How to propose a feature

Open an issue using the **Feature request** template. Describe the use case before the implementation — knowing *why* is more useful than *what* in early discussion.

## How to submit a change

1. **Fork** the repo and create a feature branch (`git checkout -b feat/short-description`).
2. **Make your change.** Keep changes focused — one logical change per PR.
3. **Test it.** See the "Testing" section in the README for how to verify your change locally.
4. **Lint it.** Run any project-specific linters or formatters before pushing.
5. **Update documentation.** If your change alters user-visible behavior, update the README and any relevant docs (`docs/`, `CHANGELOG.md` under `[Unreleased]`, etc.).
6. **Open a PR** against `main`. Fill in the PR template.

## Coding conventions

- Follow the style of the surrounding code. Match formatting, naming, and structure of existing files.
- Comments should explain *why*, not *what*. The diff already shows what.
- **No new dependencies** without strong justification — the appeal of small projects is the small, predictable surface area.
- **No telemetry, ever.** This project must not phone home.

## Commit messages

Conventional Commits style is preferred but not required:

```
feat: add support for X
fix: handle empty response from Y
docs: clarify setup for Z
```

Keep the subject under 72 characters. Add a body if the change isn't obvious from the diff.

## Releases

Maintainers cut releases by tagging `vX.Y.Z` on `main`. Pre-1.0 versioning rules:

- `0.X.0` for any user-visible change
- `0.X.Y` for bug-fix-only patch releases

After 1.0, standard SemVer applies.
