---
description: Pull latest commits on each submodule's tracked branch
allowed-tools: Bash(git submodule:*), Bash(git status:*), Bash(git diff:*)
---

Sync all submodules to the latest commit of their tracked branch (set in .gitmodules):

1. Run `git submodule update --remote --checkout`.
2. Run `git status` and report which submodule pointers moved (old → new short SHA, use `git diff --submodule=log`).
3. Do NOT commit — just report. The user commits the pointer bumps via /commit when ready.
