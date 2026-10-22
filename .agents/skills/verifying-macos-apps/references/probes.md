# Probes for what a runner does not reach

A project runner covers what its authors wrote cases for. Appearance, scrollbars, edge-drag resizing, layout, or a toggle it does not exercise are not covered. You may verify those with **one-off probes against the real window**, as long as the evidence is recorded as a different kind from the runner's PASS, and as long as subjective results (look, taste, feel) stay with the human.

`../scripts/native-probe.swift` is a small reference implementation. It is one file, uses only system frameworks, and is not an automation framework. Build it once (this path is relative to the skill directory; adjust it to wherever the skill is installed):

```sh
swiftc -O scripts/native-probe.swift -o /tmp/native-probe
```

| Command | What it observes or does |
|---|---|
| `windows [--owner NAME]` | window ID, **owner PID**, owner name, on-screen flag, bounds (top-left origin, points), title |
| `region-clear --rect X,Y,W,H --backdrop-pid PID [--allow-pid PID ...]` | is the rectangle safe for `screencapture -R`? Exit 1 unless a window of the **backdrop** PID covers the whole rectangle (fails if the backdrop has exited) **and** no window of any other PID except the `--allow-pid` ones (your candidate) intersects it. Only windows stacked in front of the backdrop count (fully transparent ones are ignored). Always by PID, never by name. Run it right before the capture **and again right after it**; if the second run fails (a banner or HUD appeared), discard the image. `--allow-pid` is for your own candidate; add a third-party process only after you have established it draws nothing in the region and the user agrees (better, close that tool) |
| `drag --window-id ID --pid PID --edge bottom\|top\|left\|right\|title --by PX [--dx PX]` | drags an edge (or the title bar to move) with mouse events and prints the bounds before and after |
| `wheel --window-id ID --pid PID --dy PIXELS` | scroll-wheel events at the window centre |
| `press --pid PID --title TEXT [--role AXCheckBox]` | `AXPress` on an element found by role and title/description, retrying for 5 seconds |
| `backdrop [--seconds N]` | prints `backdrop pid=...`, then shows a full-screen checker window on the **main display**, kept behind normal windows, owned by the probe (run the compiled binary so the PID is the probe's) |
| `sharpness PNG` | mean adjacent-pixel difference over the image centre |

`drag` and `wheel` send nothing unless the window belongs to the PID you pass (your launched candidate - another instance of the same app is refused) **and** the front-most on-screen window under the pointer is that window. They need Accessibility and event-posting access for the host that runs them.

## Practical rules (each one was learned from a wrong reading)

- **Windows**: find the target in the window list by owner PID (the PID you launched) and bounds, not by a remembered ID or an owner name: the ID changes every launch and the name also matches the user's own instance. Record bounds before and after; do not judge a size from a picture.
- **A bundled app and a bare binary have different owner/process names** (the bundle name vs the executable name). Use the one you actually launched.
- **Accessibility warm-up**: the first accessibility read of a freshly launched app can return an empty tree while accessibility is switching on. Retry with an upper bound (about 5 s) before reading "not found" as "absent". After a press, confirm the effect by a separate observation (saved setting, visible state).
- **Toggles save on every press**, so reset the isolated settings file to a known fixed value before each measurement; do not trust the state left by a previous probe (a measurement once ran with the setting already flipped by an earlier run and was mislabelled "on").
- **Edge-drag limits**: drag far both ways and record where the window stops (minimum, maximum, screen edge). A window whose edge sits on the screen edge cannot be grabbed there: move it with the title bar first.
- **The backdrop expires** (`--seconds`, default 60). A long chain of commands can outlive it, and then a region capture shows the real desktop: run `region-clear` immediately before every capture, with `--backdrop-pid`, and give the backdrop a generous time.
- **Do not overlap probes with a runner or with the user's input.** They use the physical pointer. Another window of the app (a settings window) may sit on top of the capture region: move it away before measuring.
- **Isolation**: launch with a throwaway home directory and fixed settings; never touch the user's real settings or instance. End the candidate by the PID you recorded (not by process or app name).
- **Capture scope**: window-level captures are the default; use a region capture only over a backdrop you own ([images](images.md)).

## Pairing

Probe numbers (bounds, a sharpness figure, an AX value) say what happened. They are not a verdict on appearance or feel. Report them with the kind of evidence they are, and name what a human still has to judge.
