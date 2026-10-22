# Project recipe template

The core skill never names your app, framework, cases or tools. A **recipe** does. Put one next to the project (for example `.agents/skills/verifying-<app>/SKILL.md`) and keep it short: it maps requirements to cases and points at what really exists.

## What to establish first

Read the project's conventions, its requirements document, and any existing runner/script `--help` and source. Do not assume a `SPEC.md`, Cargo, an initial window, or any particular report schema exists. If an observation method does not exist, say it is **unimplemented**; if a required precondition cannot be established, the case is **blocked**. Never invent CLI flags, attributes or success output.

| Item | What to pin down |
|---|---|
| Target and authority | project root, requirement references, app bundle/executable, what you may operate, capture and save |
| Launch and preparation | the real build/launch/case commands and environment; do not copy another app's flags |
| Cases | precondition -> action -> expected value/state/time -> how observed -> evidence -> stop condition |
| Isolation and cleanup | how a fresh candidate PID is identified, test-only settings/documents/storage, normal quit vs failure cleanup |
| Observation contract | accessibility selectors, time base and wait limits, image regions and expected relation, what the runner's report/exit codes mean |

Do not use the user's existing app instance or documents without their explicit permission, and never auto-discard unsaved documents or quit confirmations.

## Skeleton

```markdown
---
name: verifying-<app>
description: Use when verifying <app> ... (list the real cases and triggers)
---

# <App> verification recipe

Required: verifying-macos-apps. The requirements document is the only source of acceptance criteria.

## Entry points that exist
(commands you ran with --help; build step; where reports go)

| Target | Case / command | Requirement and what is actually observed |
|---|---|---|

## What the runner does not cover
(probe-based checks; link to references/probes.md)

## Kept for a human
(taste, sound, glass/appearance, physical timing, distribution acceptance)
```

## Writing good cases

- State the **observation**, not the operation: "menu item shows the checked mark and the settings window's slider reads 20" rather than "click the menu".
- Name the backend acknowledgement when one exists (a revision counter, a saved file, a receipt) and wait on that, with an upper bound.
- Say what the observation does **not** prove (for example "a receipt is not audible output").
- A case that needs the screen or input must say what happens when the permission is absent: blocked, and which independent cases still run.
