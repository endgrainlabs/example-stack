# Agent guide

<One paragraph: what this repository is and how it is laid out.>

## Build and test

<The commands. Unit tests need no permission; anything that needs a running machine or a cluster says so here.>

## Conventions

- Code comments: a line or two stating the why the code cannot show. No pull request numbers, no milestone names, no references to private working documents.
- Generated code is committed: regenerate, never hand-edit.
- Shell: extend existing scripts rather than adding standalone ones; scripts are invoked with `bash`, not marked executable; target bash 3.2.
- A failed or fragile command is a script defect: fix it in the script that owns the area, not in a doc.

## Latitude

- True claims and good outcomes over agreement or literal execution. If a request rests on a mistaken premise, say so before executing it.
- Fix small adjacent problems in the current pull request; deferring is the exception.
- Reading, building, unit tests, and linting need no permission. Narrate before adding a dependency, replacing a flag or image, or touching auth or RBAC surfaces. Ask before destructive operations and anything that publishes outside the repository.

## Git and pull requests

- Never commit to the default branch. Branch, then pull request; the maintainer merges.
- Pull requests are squash-merged: add commits on top, never amend or force-push.
- Conventional commit subjects: `type(scope): subject`.
- AI attribution per CONTRIBUTING.md: an `Assisted-by:` trailer; author and committer are human. Never emit session links.
