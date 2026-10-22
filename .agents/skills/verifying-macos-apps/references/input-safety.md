# Input safety and per-operation expectations

## Targets

Record the **PID + start time + executable/bundle identity** of the candidate you launched and tracked. Walk accessibility from `AXUIElementCreateApplication(pid)` and select elements by role and real identifier/label. Status-bar / menu-only apps need no initial window: observe their own item and the panel its operation produces.

## Keyboard

Immediately before a global key event, re-check that `NSWorkspace.shared.frontmostApplication` has the target's PID **and** that `AXFocusedWindow` is the target. `AXMain`, or the window merely being visible, is not evidence of keyboard focus. If a modal sheet or another document took over, stop.

## Pointer

Prefer `AXPress` (and similar actions) on the owned element. If coordinates are unavoidable, immediately before sending, check the coordinate system, scale and current bounds, and that the **actual hit target** belongs to and is identified as the intended window - e.g. the front-most on-screen window containing the point (CoreGraphics lists windows front to back), or `AXUIElementCopyElementAtPosition` and the element's PID/identity. Do not infer the receiver from the frontmost PID or focus alone. If you cannot confirm, send nothing and report blocked. Pointer operations on a status item or a non-key panel must not require a focused window that does not exist.

Unsupported accessibility attributes are not success. Keep message timeouts, tree depth/size and waits finite.

## When a case stops midway

Keep the saved report, images, measurements and the failure position. Observe only what is needed: the frontmost PID at the loss, the focus/window identity **of your candidate only**, bounds/window ID, session/display. Do not state a cause from values you did not read. Resume in a **new run** once you have a new observation or an environment change that distinguishes the cause. Do not remove focus guards, retry unconditionally while winning the focus back, or present partial images or failure cleanup as success.

If the old candidate and saved evidence cannot give you what you need, you may make **one diagnostic-only private run**, separate from a normal resume: confirm permission scope, session/display and preflight; state the hypothesis, the extra read-only observation that exists, and finite wait/stop conditions up front; keep the guards; stop and save evidence on loss. The diagnostic ending is not a case pass. An identical retry with no extra observation is not a diagnostic.

## What to observe per kind of check

| Check | Example observation |
|---|---|
| Settings / menu / selection | AXValue / selection / check state before and after, plus any needed backend acknowledgement - separate from "the click succeeded" |
| Focus, scroll, redraw | `AXFocusedUIElement` and target identity, real viewport change, state preserved during the operation |
| Save and recovery | change isolated settings/documents -> actual save -> close/relaunch -> read content back. "A window opened" is not restoration |
| Windows and panels | the required count, identity, geometry, minimise/recreate. Fixed size or free resize is a project requirement, not a shared one |
| Quit | the real menu/shortcut path, the owned PID disappearing, the exit result. Terminate/kill cleanup is not evidence of a normal quit |

Wait on an observable acknowledgement or state, with an upper bound. Keep source reading, builds, unit tests, accessibility operations, real rendering, listening/appearance judgement, physical timing and release artifacts as separate kinds of evidence.
