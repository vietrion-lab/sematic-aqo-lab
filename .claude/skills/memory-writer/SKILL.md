---
name: memory-writer
description: Write and manage daily work session notes in memories/ — captures decisions, progress, and context for future sessions.
user-invocable: true
allowed-tools: ["Bash", "Write", "Read", "Glob", "Grep"]
---

# Memory Writer

Write, search, and manage daily work session notes in `memories/`.

## When to Write

- End of a significant work session (code changes, debugging, architecture decisions)
- After key decisions that future sessions need to know about
- After debugging breakthroughs or bug investigations
- When the user explicitly asks to save a memory/note

## File Naming

```
memories/YYYY-MM-DD-<topic>.md
```

- Use today's date
- `<topic>` is a short kebab-case label: `bug-fix`, `feature-impl`, `experiment-run`, `refactor`, etc.
- Examples: `2026-04-02-project-scaffolding.md`, `2026-04-04-scale-mismatch-investigation.md`

## Template

```markdown
# YYYY-MM-DD — <Topic Title>

## What Was Done

### 1. <First task>
- Detail about what was accomplished
- Specific files changed or commands run

### 2. <Second task>
- ...

## Key Decisions
- **<Decision>** — <Rationale for why this choice was made>
- **<Decision>** — <Rationale>

## Open Items
- <Remaining task or question for future sessions>
- <Known issue discovered but not yet fixed>
```

## Writing a Note

1. Gather context from the current session — what was done, what decisions were made, what's left
2. Check if a note for today + topic already exists:
   ```
   ls memories/YYYY-MM-DD-*.md
   ```
3. If a matching file exists for the same topic, **append** to it rather than creating a new file
4. If no matching file exists, create a new one using the template above
5. Write the note using the Write tool

## Searching Past Notes

When the user asks about past work or context:

- **By date**: `ls memories/2026-04-02*.md`
- **By topic**: `ls memories/*bug*.md` or `ls memories/*experiment*.md`
- **By content**: Use Grep to search inside notes for keywords
- **List all**: `ls -la memories/`

## Rules

1. **One note per topic per day** — don't create `2026-04-06-bugfix.md` and `2026-04-06-bugfix-2.md`; append to the first
2. **Never delete or overwrite** old notes — they are the team's institutional knowledge
3. **Be specific** — mention file paths, function names, error messages, not just "fixed a bug"
4. **Record rationale** — future sessions need to know *why*, not just *what*
5. **Keep Open Items actionable** — each item should be clear enough to pick up without extra context
