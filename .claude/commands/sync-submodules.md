---
description: Fetch submodule remotes and report divergence without changing checkouts
allowed-tools: Bash(git submodule:*), Bash(git status:*), Bash(git diff:*)
---

Refresh knowledge of every configured submodule remote without moving a submodule checkout.
The root gitlinks define the reproducible stack. Fetch branch and upstream movement for
review without automatically replacing those recorded checkouts.

1. Run `git status --short --ignore-submodules=none` and record dirty or locally divergent
   submodules. Do not alter them.
2. Run `git submodule foreach --recursive 'git fetch --all --prune'`. This fetches both
   `origin` and `upstream` where configured, but does not checkout, merge, or rebase anything.
3. Run `git submodule status`, `git status`, and `git diff --submodule=log`.
4. For each submodule, report the checked-out short SHA, its advertised branch tip, its
   upstream tip when configured, and any ahead/behind or local-only state.
5. Do **not** run `git submodule update --remote --checkout`, checkout, reset, merge, rebase,
   commit, or push. Report what would move and let the user choose whether to advance the
   root gitlinks.
