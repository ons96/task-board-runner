# Safe auto-merge policy

This repository does not auto-merge pull requests. A maintainer may enable an
external merge rule only when every condition below is true.

## Allowed

Auto-merge is limited to public, docs-only changes that:

- modify only Markdown or plain-text documentation;
- do not modify workflows, scripts, configuration, permissions, dependencies,
  secrets, or executable code;
- pass the repository self-test and all required branch checks;
- have no unresolved review comments, merge conflicts, or security findings;
- do not add, remove, or alter repository or issue labels automatically.

Mechanical dependency updates are not in the allowed set. They require review
because lockfiles and transitive code can change runtime behavior.

## Always require review

Manual review is required for source code, shell scripts, workflows, action
versions, configuration, provider/model settings, permissions, lockfiles,
secrets, authentication, deployment, migrations, and any PR with a mixed or
uncertain diff.

## Required checks

The merge actor must verify the changed-file classification, required CI, a
clean diff, no secret scan findings, and the absence of a protected-branch or
security exception. Labels or PR titles never override these checks.

This policy is documentation only. No workflow in this repository performs
automatic merging.
