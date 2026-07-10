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

## Hardware Visibility Rule

When ST-LINK, USB-TTL, SWD, or serial hardware appears missing, check Windows visibility before assuming a physical hardware problem:

1. Run `powershell.exe -NoProfile -Command "usbipd list"` from WSL/Codex and confirm ST-LINK and USB-TTL are visible on the Windows side.
2. If a device is `Shared` but not `Attached`, attach it into WSL with `powershell.exe -NoProfile -Command "usbipd attach --wsl --busid <BUSID>"`; do this for both ST-LINK and USB-TTL when needed.
3. Only after Windows/usbipd state is clear, check WSL-side `lsusb`, `/dev/ttyACM*`, `/dev/ttyUSB*`, and `tools/diagnose-swd.sh`.
4. If the device is missing from Windows too, then investigate cable, power, reset/BOOT, SWD wiring, common ground, or Windows tools holding ST-LINK.

## Subagent Practical Note

Codex may not expose native tools named exactly `elon`, `tom`, and `gill`. When spawning generic subagents, pass the relevant `.claude/agents/*.md` role instructions into the subagent prompt and require it to follow that role's responsibility boundary.
