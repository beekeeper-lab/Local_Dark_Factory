---
name: factory-pr
description: |
  RETIRED. Opening the pull request is controller work with no model in it —
  see factory/pipeline/pr.sh. This file remains only so that an accidental
  invocation stops rather than improvising.
---

# factory-pr — retired

Do not use this skill. If something invoked it, that is a wiring bug worth
reporting rather than working around.

Opening a pull request is `factory/pipeline/pr.sh`, and it runs no model at all.
Spec §06 stage 11 makes push and PR pure controller work, and `roles.json` has
carried a note since the fork saying that binding `pr` to the developer was
wrong: the pre-PR audit already drafts what needs saying, and everything else in
a PR body is a fact the controller can read off disk.

The reason it matters is not tidiness. This is the one step that holds a GitHub
credential. A model here would be a model inside a process that can push — to
compose prose that has already been written by the step before it.

If you were invoked anyway: **do nothing, change nothing, push nothing.** Say
that `factory-pr` is retired and that `factory/pipeline/pr.sh` is the step.
