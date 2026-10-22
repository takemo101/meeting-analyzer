---
name: verifying-macos-apps
description: "Use when verifying a macOS desktop app through its real UI - driving it, capturing its windows, reading its accessibility tree, handling missing Accessibility or Screen Recording permission, focus loss, quitting, or deciding what counts as pass, fail or blocked and what evidence to keep. A verification-discipline layer, not an automation tool: it tells you how to judge and record what you observed, and pairs with a project-specific recipe and whatever tool actually clicks."
---

# Verifying macOS apps

**Judge observations against requirements. A successful operation is not evidence.** A click that returned 0, a screenshot that was taken, or a runner that exited 0 proves only that something ran. This skill is the layer that decides what you may claim, and what you must call unverified.

It is not an automation tool (use Peekaboo, cua-driver, AppleScript, XCUITest or your own helper to act) and not a test-writing guide. It does not name your app, framework, cases, CLI or spec file; a project-specific *recipe* supplies those.

## Verdicts

- **fail**: a real check did not match, or required evidence is corrupt or contradictory. Wins over blocked.
- **blocked**: a needed permission, environment or observation method is missing, so the case did not finish. Never filled in with a pass.
- **pass**: every *selected* required check was observed. Keep it separate from optional/unselected checks and from the product as a whole.

## Procedure

1. **Fix the recipe.** Map the requirement to a case: preconditions, action, expected value/state/time, how it is observed, evidence, stop condition. Read the project's own recipe and runner first; if none exists, write one ([recipe template](references/recipe-template.md)). If a required precondition cannot be established, the case is blocked.
2. **Preflight.** Check session/display/lock state and the permissions the case needs, without prompting for anything ([preflight and permissions](references/preflight-and-permissions.md)). Missing permission: tell the user exactly what to enable and for which process, then resume only the unfinished cases.
3. **Act on a verified target.** Launch your own candidate; record PID + start time + executable identity. Before keyboard input confirm the frontmost PID and the focused window are the target; before pointer input confirm the window under the pointer is the target ([input safety](references/input-safety.md)). Prefer accessibility actions over coordinates.
4. **Observe.** Wait on acknowledgements with an upper bound, not fixed sleeps. Read the accessibility tree for state; capture only your own windows for visuals ([images](references/images.md)). For what a runner cannot reach (blur, scrollbars, window-edge resizing, layout) use [probes](references/probes.md). For a built artifact (DMG, app bundle) see [distribution](references/distribution.md).
5. **Judge and record.** Requirement → case → command, OS/arch, app version/hash → expected vs observed → evidence paths → verdict → what was not done or needs a human ([reporting](references/reporting.md)).
6. **Clean up.** End the candidate through the path under test when the case is about quitting; a terminate/kill is cleanup, not proof of a normal quit. End only the PID you recorded (check its start time and executable), never by process or app name, which could end the user's own instance.

## Rules that are never relaxed

- Use only processes you launched, with test-only settings and storage. Never use the user's running instance, documents or real settings without their explicit permission; never discard unsaved work or auto-answer quit prompts.
- Never call a permission-request API, drive a permission dialog, or change OS permissions (TCC, privacy settings, helper signing). Asking the user to grant a specific permission to a specific process is the expected path; after they act, you re-read the non-prompting probe.
- Missing capability is **blocked**, not "probably fine". Do not invent flags, attributes, selectors or success output. An unsupported accessibility attribute is not success.
- Input is gated: no keystrokes unless the target is frontmost and focused; no pointer events unless the hit target is the target window. If you cannot confirm, do not send.
- Capture only what is yours: the candidate's own windows (window-level capture by window ID). Never capture other apps or the desktop, and never send images outside the machine. The one exception is a system dialog **raised by your candidate** (a permission or quit prompt the case depends on): capture that single window by its window ID, never a screen region. A region capture (`screencapture -R`) is allowed only over a backdrop you own, and only after checking that no other window intersects the region ([images](references/images.md)).
- Keep evidence kinds apart: source reading, unit tests, accessibility state, rendered pixels, listening/appearance judgement, physical timing, built artifacts. One does not stand in for another; subjective quality stays with the human.
- Read the runner's real report and exit mapping. Exit 0 is not PASS; a pass from before the binary changed is not carried over.
- Past fail/blocked records are never rewritten to pass; resume unfinished cases in a new private run with a fresh candidate.

## References

| File | Read when |
|---|---|
| [recipe-template.md](references/recipe-template.md) | writing or reading a project's recipe |
| [preflight-and-permissions.md](references/preflight-and-permissions.md) | checking session/permissions; a permission is missing; resuming afterwards |
| [input-safety.md](references/input-safety.md) | sending keys or pointer events; focus lost mid-case; expected observations per operation |
| [images.md](references/images.md) | capturing windows, comparing images, checking transparency or blur |
| [probes.md](references/probes.md) | checks a project runner does not cover; the reference probe tool in `scripts/` |
| [distribution.md](references/distribution.md) | verifying a DMG / app bundle / release artifact |
| [reporting.md](references/reporting.md) | writing the report; worked examples of false passes this skill prevents |
| [EVALS.md](EVALS.md) | measuring whether the skill actually helps (a design, not yet run) |
