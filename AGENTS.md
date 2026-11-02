# AIMeter contributor instructions

## Scope

Work in this checkout and use its GitHub remote as the project source. Check the branch, worktrees, and existing changes before editing. Preserve unrelated work and restrict commits to the current task.

## Build and verification

- Check running builds, memory pressure, and free disk space before starting a build. Run one Swift build or test process at a time, with `-j 2`.
- Follow `CONTRIBUTING.md` for the current SDK requirements and commands.
- Use temporary directories and synthetic fixtures for tests. Do not read personal AI histories or use real API credentials to verify changes.
- `./scripts/build_app.sh` creates a local bundle without installing it. Launch and install commands can change the running app; use them only when the task includes that operation.
- A successful build does not establish real WidgetKit, Intel, older macOS, or live API compatibility. Report skipped and untested checks.

## Public changes

- Keep the MIT license, required copyright notices, public repository URLs, and existing privacy boundaries intact.
- Check source, tests, documentation, and commit metadata for secrets, private workspace links, and personal paths before pushing. Use only synthetic screenshots or fixtures.
- Follow the existing local validation workflow; adding hosted CI is a separate change.
- App signing, notarization, publishing a Release, and changing repository visibility are separate from source changes. Follow `docs/RELEASING.md` when a task explicitly includes distribution.
- Use a focused branch and PR. Do not force-push or rewrite published history to update the app.
