# Robotics Codex Instructions

This repository uses the project-defined agent team in `.claude/agents`.

Before Codex handles any non-trivial task in this repository, read these files:

- `.claude/agents/README.md`
- `.claude/agents/elon.md`
- `.claude/agents/tom.md`
- `.claude/agents/gill.md`

## Agent Roles

- `elon`: project manager / architect. Clarifies requirements, defines architecture, writes interface contracts and task cards. Elon does not write functional code.
- `tom`: development engineer. Implements code according to task cards in `docs/plan/`.
- `gill`: test engineer. Independently verifies Tom's implementation against task-card acceptance criteria, and may use `tools/codex-review.sh` for a second opinion on safety-critical or complex logic.

## Default Workflow

Use this workflow for non-trivial project work:

1. If requirements, architecture, interfaces, or task boundaries are unclear, use the `elon` role first.
2. If code needs to be implemented or a bug needs to be fixed, use the `tom` role.
3. After implementation, use the `gill` role for independent verification.
4. Keep the main Codex thread as the dispatcher and integrator: read the role definitions, delegate when useful, run final verification, and summarize the outcome.

Simple status checks, file reads, single-command queries, or tiny edits may be handled directly by the main Codex thread without forcing the full three-agent workflow.

## Subagent Practical Note

Codex may not expose native tools named exactly `elon`, `tom`, and `gill`. When spawning generic subagents, pass the relevant `.claude/agents/*.md` role instructions into the subagent prompt and require it to follow that role's responsibility boundary.

