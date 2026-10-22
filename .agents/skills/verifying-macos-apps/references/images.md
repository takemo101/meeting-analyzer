# Screenshots and image judgement

## What you may capture

Check both the user's authorisation to capture and the OS permission of the API you use. If the screen-capture preflight is false, do not call the capture API: **blocked** (see preflight). Never change permission dialogs or OS settings.

Capture **only windows you own**: identify the candidate's window by PID, window ID, geometry and ownership first, and save only that window or panel, locally. Do not capture other apps or the desktop, do not send images off the machine, and do not use new documents or profiles that contain sensitive data.

Window-level vs region capture matters:

- `screencapture -l <windowID>` (or ScreenCaptureKit's per-window capture) gives the window's own content and **no background**.
- `screencapture -R x,y,w,h` is the **composited screen** and picks up other apps and the desktop. Use it only over a backdrop you launched yourself (for example for a transparency check), and **only after confirming that no other window intersects the region**: list the on-screen windows (front to back) and require that the only ones inside the rectangle are your candidate's and your backdrop. Windows of other apps that sit behind a translucent window under test, the Dock, the menu bar, notification banners and HUDs all show through or over a backdrop that is one level below normal windows. The reference backdrop covers the main display only; keep the region on it. If anything else is in front of the backdrop inside the region, do not capture (blocked). Run the check again right after the capture and discard the image if it now fails (a banner or HUD may have appeared in between). Allow only your own candidate and backdrop; a third-party process may be allowed only when you have established that it draws nothing in the region and the user agrees. `region-clear --backdrop-pid <backdrop> --allow-pid <candidate>` in the reference probe does this check, and also fails if the backdrop does not cover the region - for example because it already exited ([probes](probes.md)).
- A system dialog **raised by your candidate** (a permission or quit prompt that the case depends on) is the one non-owned window you may capture: take that single window by its window ID (`screencapture -l`), never a screen region and never a full screen.

## Defining an image check

Decide before capturing: the **region, the sample times, the expected relation and the tolerance**.

- Animation: the required region changes. Static screen: stable/identical. A result of an operation: the required display. "Something somewhere changed" is not a pass.
- Record exclusions (clock, cursor, a see-through background) as a region/mask that fits the requirement, and never mask the thing under test. Do not mix samples from before and after an acknowledgement.
- Check decode, size, scale and colour space. An empty, uniform or transparent image is either a capture failure or a legitimately empty canvas; tell them apart from the requirement and the capture evidence, and do not fail a legitimate empty canvas unconditionally.
- A pixel difference does not prove correct text, sound, physical sync or visual quality. Use another observation for those. A comparator's self-test is not acceptance of an app image.

## Transparency and blur: measure against a controlled backdrop

A wallpaper is a poor reference: it can already be soft, so "blur on" and "blur off" look the same and prove nothing. Instead:

1. Put a window **you own**, full-screen on the (main) display you capture, high-frequency (8-point black/white squares), **behind** the window under test. It must stay behind whatever the launch order (give it a window level one below normal). Move other windows of the app out of the capture region.
2. Check the region is clear of other windows (`region-clear`), then capture the region of the window under test with the setting on, off and on again.
3. Compute the mean absolute difference of horizontally adjacent pixels over the centre. A sharp checker is around 0.06 at 2x; a blurred one is near 0.
4. If on and off give the same number, the setting does nothing (a real case: the framework's default material did not blur on the current macOS). A measurement says the effect exists; tint, strength and taste remain a human judgement.

The reference probe in `../scripts/` has `backdrop` and `sharpness` for this ([probes](probes.md)).
