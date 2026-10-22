---
name: verifying-meeting-analyzer
description: Use when verifying meeting-analyzer (the macOS menu-bar app and CLI in this repo): running the unit tests and the native E2E, reading the report, deciding what may be claimed, and what stays with a human (microphone, system audio, screen, permissions, echo, recognition quality, agent integration). A recipe on top of verifying-macos-apps.
---

# Verifying meeting-analyzer

A project recipe for [verifying-macos-apps](../verifying-macos-apps/SKILL.md). Read that skill first: **an observation is judged against a requirement; a successful run is not evidence**. This file maps the requirements in `SPEC.md` §8 to the cases and commands that exist **today**. It adds no requirements and no operating rights.

## What exists

| Layer | Command | Observes |
|---|---|---|
| Unit | `./scripts/test.sh` | batching rules, lifecycle, transcript, JSON shapes, endpoint checks, failure classes, argument parsing, replay flow (no audio, no screen, no network) |
| Native E2E | `./scripts/e2e.sh` (builds if needed) | the real executable: CLI exit codes and JSON, **real on-device recognition** of a `say` voice, HTTP requests received by a fake bridge, the transcript file and its permissions, the menu-bar app starting and stopping |
| Human | — | everything in "Not observed" below |

Cases (IDs are in `docs/verification.md`): Z1 `--version`, Z2 unknown command, Z3 unreadable audio, D1 `doctor`, D2 voice available, R1 replay as "相手", R2 replay as "あなた", R3 wrong token, R4 no bridge, R5 non-loopback URL, A1 starts as an accessory app and quits on SIGTERM.

## Procedure

1. **Fix the expectation before running.** For a changed behaviour, write the case's expected values first (exit code, JSON keys, speakerName, request order), then run. Do not adjust an expectation to match what you saw.
2. **Preflight, without prompting.** The E2E needs `node`, `say` with the Japanese voice **Kyoko**, and `doctor` reporting `supported` and `installed` for `ja_JP`. Missing prerequisites make the dependent cases **blocked** — report them as blocked, never as pass. Do not install voices, download models or change OS settings to make a case run; tell the user what is missing.
3. **Run on a copy.** `scripts/e2e.sh` copies the app with a different bundle ID (`dev.takemo101.meeting-analyzer.e2e`) and points the data directory (`MEETING_ANALYZER_DATA_DIR`) and the token directory (`LIVE_SUPPORT_RUNTIME_DIR`, `--token-dir`) at a private temp directory with a generated token. Never run the harness against the user's real data directory or `~/.live-support/token`.
4. **Read the real report.** The run prints `今回の report: pass=… fail=… blocked=…` and writes `build/native-e2e/run-<time>/report.json`. Exit code: 1 if any fail, 77 if any blocked (and no fail), 0 if all pass. Exit 0 is not "the product works": it is "these cases passed".
5. **Check that a failure can happen.** When adding or changing a case, mutate the system under test (for example make the fake bridge answer 503) and confirm the case fails; restore the change.
6. **Record.** Add an entry to `docs/verification.md` "実施記録": target (version, build SHA-256), environment (macOS, chip, Swift), commands, observations, evidence paths, what was **not** done. Do not rewrite an earlier failed or limited record into a success.

## Safety

- Only processes you started. The harness starts the candidate and a fake bridge, and ends the candidate by its PID. It never touches the user's running meeting-analyzer.
- Never call a permission-request API, drive a permission dialog, or change TCC. Microphone, system-audio and screen-recording permissions are **not** exercised by any current case. When capture is implemented and a case needs a permission, tell the user exactly which process needs which permission, and resume only after they grant it.
- The fake bridge binds to `127.0.0.1` on a random port and records requests to a file in the run directory. Run directories hold a generated token and synthetic speech only; no real meeting content.
- Use only synthetic audio (`say`). Never record, store or send real meeting audio for verification.

## Not observed (stays with a human)

Microphone and system-audio capture and their permissions; echo (the speaker's voice leaking into the microphone); recognition quality and latency on real meetings (the `say` voice is clean synthetic speech and much easier than a meeting); screen capture; the menu items' look and behaviour; each agent's integration and the quality of the summary; whether ad-hoc signed builds keep their permissions across rebuilds. Do not turn any of these into a pass from the automated cases.

## Reporting

Per `references/reporting.md` of the shared skill: requirement → case → command → OS/arch → app version and hash → expected vs observed → evidence paths → verdict → what was not done or needs a human. Keep unit-test, E2E and human results in separate rows.
