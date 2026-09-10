# Contributing

This document is how work lands in the repositories of Endgrain Labs LLC.

## Proposing changes

- Branch, then open a pull request; never commit to the default branch.
- Pull requests are squash-merged. Add commits on top; never amend or force-push a branch under review.
- Commit subjects follow the conventional form: `type(scope): subject`.
- A pull request states what it changes, what proves it (tests, scripts, a run against a cluster), and whether a pre-merge adversarial review was run or skipped, with the reason.

## AI coding assistants

Contributions produced with the help of AI coding assistants are welcome, subject to the same review and accountability standards as any other contribution.

**Human accountability is absolute.** If you submit a contribution produced with AI assistance, you are responsible for reading every line, verifying it is correct, and taking full responsibility for its behavior and implications. The AI is a tool you used; you are the contributor.

**AI agents do not certify contribution terms.** Do not add AI agents as `Signed-off-by` or `Co-Authored-By:` trailers. The `Author:` and `Committer:` fields of a commit must identify the human submitting the change.

**Attribution uses an `Assisted-by:` commit trailer.** When an AI tool provided material assistance with a commit, include a trailer of this form:

    Assisted-by: AGENT_NAME:MODEL_VERSION [TOOL1] [TOOL2]

`AGENT_NAME` is the assistant (for example `Claude`), `MODEL_VERSION` the specific model if known, and each optional `[TOOL]` names the agent harness (for example `claude-code`) or a specialized analysis tool the AI invoked on your behalf. Routine development tools are not listed.

    Assisted-by: Claude:claude-opus-4-6 [claude-code]

Never include links to AI sessions or conversation transcripts in commits or pull requests; sessions are private working notes, and the pull request is the record.

## Code and comments

- Comments state the why the code cannot show, in a line or two. Rationale belongs in the design record or the pull request.
- No pull request numbers, milestone names, or references to private working documents in code or comments.
- Generated code is committed and regenerated, never hand-edited.

## License

See the LICENSE file in each repository. Nothing here is open source unless a repository's LICENSE says so.
