# verifying-macos-apps

An agent skill for **verifying a macOS desktop app through its real UI** - and for being honest about what that verification proves.

Most tools in this space answer *"how do I click this?"* (Peekaboo, cua-driver, AppleScript, XCUITest, accessibility helpers). This skill answers the other question: **"what am I allowed to claim from what I just observed?"** It is a verification-discipline layer you put on top of whatever drives the app.

## What it gives an agent

- A **pass / fail / blocked** model that never turns a missing permission or an unrun case into a pass, and never lets a runner's exit code stand in for an observation.
- **Permission handling without self-help**: check, do not prompt; identify *which process* must be allowed; ask the human precisely; resume only the unfinished cases. The agent never drives permission dialogs or changes TCC/OS settings.
- **Gated input**: no keystrokes unless the target is frontmost and focused; no pointer events unless the window under the pointer is the target.
- **Image-check discipline**: capture only owned windows, define region/time/relation/tolerance first, and measure transparency or blur against a **controlled backdrop**, not a wallpaper.
- **Evidence hygiene**: separate source reading, unit tests, accessibility state, pixels, subjective quality, physical timing and release artifacts; keep records of failures; do not reuse a pass after the binary changed.
- **Artifact checks** for DMGs and app bundles (checksum, signature, minos, launch, and why Gatekeeper wording stays "unconfirmed" until a browser-downloaded file is opened on a clean Mac).

## Where it sits

| Layer | Examples | This skill |
|---|---|---|
| Operate the UI | Peekaboo, cua-driver, `gui-automation`, AppleScript, community accessibility skills | uses them (or your own helper) to act |
| Write and run tests | XCUITest / Swift Testing skills, Tart Xcode Runner | complements; it is about real-window E2E, not test authoring |
| Judge and report | generic "verification before completion" skills | macOS-specific counterpart: permissions, focus, windows, captures, bundles |

It deliberately does **not** name your app, framework, cases or CLI. A small project **recipe** does ([template](references/recipe-template.md)). The repository this skill came from keeps a worked recipe for its own app next to it.

## Layout

```
SKILL.md                      core procedure and the rules that are never relaxed (read first)
references/
  recipe-template.md          how to write a project recipe
  preflight-and-permissions.md  session/permission checks, missing-permission protocol
  input-safety.md             keyboard/pointer gates, focus loss, diagnostics, per-check observations
  images.md                   capture scope, image checks, blur/transparency against a backdrop
  probes.md                   checks a project runner does not cover; the reference probe tool
  distribution.md             DMG / bundle / release verification
  reporting.md                report shape, verdicts, worked examples of false passes prevented
scripts/native-probe.swift    reference probes (windows, region-clear, drag, wheel, AX press, backdrop, sharpness)
EVALS.md                      how to measure whether the skill helps (designed, not yet run)
```

## Use

Copy the directory into your skills location (for example `.claude/skills/verifying-macos-apps/` or `.agents/skills/`), add a project recipe next to it, and let the agent load it when it verifies a macOS app. The probe is optional: `swiftc -O scripts/native-probe.swift -o /tmp/native-probe`. Installing or registering this skill globally, installing tools, or changing settings is a separate request from verifying an app - do it only when the user asks.

## Limits - read before relying on it

- **It was written and exercised on one project** (a Rust/GPUI audio app on macOS 27, Apple Silicon). Parts were also reviewed independently, but nothing has been tested on other apps, other macOS versions, or by other people. The improvement claims in `EVALS.md` are **a plan, not results**.
- It ships **no general runner**. Without a recipe and some way to act, it is guidance only.
- The probe is a reference for a few checks; it is not a test framework and is not hardened for arbitrary apps.
- Pixels, accessibility values and numbers say what happened; **look, sound, feel and the Gatekeeper warning wording remain human judgements** or separate evidence.
- macOS only. Permissions and OS behaviour change between releases; verify against the OS you run.

## License

MIT, as the repository it lives in (see the repository's `LICENSE`). If you publish this directory on its own, add a `LICENSE` file with that text.
