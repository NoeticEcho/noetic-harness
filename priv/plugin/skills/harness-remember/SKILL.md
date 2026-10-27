---
name: harness-remember
description: Write what this session learned into the harness's append-only project memory, so that the next session does not repeat it. Invoke as /harness-remember followed by the lesson in one sentence.
allowed-tools: Bash(noetic-harness:*), Bash(echo:*)
---

Record this: **$ARGUMENTS**

## What is already there

!`noetic-harness memory --query "$ARGUMENTS" 2>&1 | head -30`

---

If the section above says `noetic-harness` was not found, the engine is not
installed and there is no memory to write to. Say so, and give the user the
record below as text, so that it can be added once the engine is installed.

If a record above already covers it, write a new record that supersedes it.
The memory is append-only and nothing in it is deleted, because its value is
its provenance. Otherwise add one:

```bash
noetic-harness memory --add \
  --kind lesson \
  --title "<the lesson as a claim, not a topic>" \
  --body "<what happened, what you expected, what was true, and how you found out>" \
  --scope "<comma-separated areas>" \
  --confidence observed
```

What makes a record worth keeping:

- **The title is a claim.** "Anchor routing keywords at the start of a word"
  is a record; "routing" is a folder name.
- **The body says how you know.** `--confidence observed` means you ran it and
  watched it happen, `inferred` that you reasoned to it, and `reported` that
  something told you. Do not promote one to the next.
- **It says what the alternative would have broken.** A record that only says
  what to do is ignored the moment it is inconvenient.
