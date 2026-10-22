# Evidence, verdicts and reports

Read the runner's real schema and exit mapping. Do not rewrite an existing format for this skill, and do not call exit 0 a PASS by itself. When you save new evidence, use a unique private run directory (0700), files 0600, and a path you never overwrite.

## Report shape

Requirement reference and selected case -> command, macOS version and arch, app version/hash -> **expected vs observed** -> local paths of this run's report, images, measurements and stderr -> verdict -> what was not done, what needs a human, and cleanup. Fill gaps the schema lacks by actually observing; if you did not, write "not confirmed".

- **fail**: a real check mismatched, or required evidence is broken/contradictory. It outranks blocked.
- **blocked**: required permission, environment or observation method is missing. Never filled with a pass.
- **pass**: all *selected required* checks were observed. Keep it apart from optional or unselected image checks and from the product as a whole.

Evidence ages: when the binary or the related conditions change, an old pass does not carry over. Past fail/blocked records are never edited into passes.

## Worked examples of false passes this skill prevents

1. **Blur that did nothing.** The user reported "blur has no effect". A first comparison over the desktop wallpaper showed a soft background with the setting on *and* off - inconclusive, because the wallpaper itself was soft. Against a sharp checker backdrop the sharpness metric was 0.0584 (on) vs 0.0582 (off): identical, so the setting really was broken (the framework's default material does not blur). After the fix: 0.0004 (on) vs 0.0584 (off), and toggling on-off-on through the settings window gave 0.0007 / 0.0601 / 0.0004. The verdict rests on a measurement against a controlled background, and says nothing about whether the look is pleasing.
2. **A reading mislabelled by leftover state.** A probe labelled its first reading "blur on", but an earlier run had already toggled the setting off and the toggle persists. The numbers were consistent only with the opposite labels. Resetting the isolated settings file before each measurement removed the ambiguity.
3. **A warning that could not be reproduced.** The install notes describe the Gatekeeper approval steps. On the build machine a hand-quarantined copy launched without any dialog, so the notes were recorded as *unconfirmed* rather than passed, with the exact condition needed to confirm (a browser download opened on a clean Mac).
4. **A tree that looked empty.** The first accessibility query after launch returned no matching element; the second found it. "Not found" in the first read was not treated as "absent".
