# Preflight and missing permissions

Run the checks your recipe's tooling already performs. If you need SDK-level diagnostics, read them from the Command Line Tools' Swift. They are not permission requests and none of them alone proves that input is safe.

- `CGSessionCopyCurrentDictionary()`: console session, login finished, running UID, matching session, lock state. A `nil` lock flag is not proof of unlocked.
- `CGDisplayIsActive` / `CGDisplayIsAsleep`: the display that shows the target. Do not send input while locked, asleep, at loginwindow, or when the target display is unknown.
- `AXIsProcessTrusted()`: Accessibility. Cases that post `CGEvent`s also need `CGPreflightPostEventAccess()`.
- `CGPreflightScreenCaptureAccess()`: Screen Recording for real captures. It is separate from Accessibility and from the user saying "go ahead and take screenshots".

If screen-capture preflight is false, do not call a capture API; the image cases are **blocked**. Independent accessibility cases continue. Do not substitute offscreen/export/synthetic images; if you used one, record it as a different kind of observation.

## When a permission is missing

Report **what is missing, for which process, what the user should do, and when you will resume** - not just "blocked". Consent to capture/operate and the OS permission are different things. Do not ask for permissions the case does not need, or for ones already granted.

If the user **declines**, stop asking and stop trying. Keep the dependent required cases blocked, and do not let independent passes stand for the whole. Dropping a required check needs an explicit scope change from the user. Do not ask again until the user offers.

1. List the preconditions of the pending cases. A locked screen, display sleep or another console is **not** a permission problem: ask the user to wake/unlock the target.
2. **Identify the process that must be allowed**, from the host, the user, the parent app's PID/bundle/path, and any read-only OS attribution available. The app under test, the terminal/IDE that launched you, and the helper that calls the SDK are three different things. If needed, match the responsible/subject process in a narrowly scoped TCC log query; never read the TCC database, keys or credentials. Do not guess the target from the CLI name or from a success in another terminal. If you cannot determine it, say exactly which boundary is unknown.
3. Ask the user, in System Settings -> Privacy & Security, to allow the **confirmed** process under the right item (Accessibility; Screen Recording - called "Screen & System Audio Recording" on current macOS, where the audio-only list does **not** count; for event posting, the item the API's contract and OS attribution require - do not blanket-require Input Monitoring). Use the item names the running OS version and language actually show. If the OS asks for a quit/relaunch, the user saves their work and does it; you never terminate the user's host app. An entry that is missing or cannot be added is not permission.
4. After the user reports a change, read the **same non-prompting probe** once on the **same execution path**. The user's statement is not evidence; keep the preparation and the SDK reading as separate, timestamped facts. If still false, narrow the mismatch (host, allowed subject, relaunch condition) instead of asking "did you do it?" again or rerunning everything.
5. When it turns true, confirm session, display, required input permissions and candidate ownership, then resume **only unfinished cases** in a new private run. Keep earlier passes if the binary identity and related conditions are unchanged. Past blocked/fail records stay as they were.
6. If a case fails *after* permission checks succeeded (focus lost, comparison mismatch), do not reclassify it as a permission problem or ask for the permission again.

Example request: *"The screen-capture preflight is false, so the image cases did not run. Please allow `<observed app name, path>` under Screen Recording. If macOS asks you to relaunch it, do that; I will re-read the check afterwards."* Fill the target from observation. Never drive the permission dialog, call a permission-request API, change TCC/OS/credentials, or re-sign/register a helper on the user's behalf.
