# Echo parked — 3 October 2026

## Decision

Osiris said: “this did not get built the way we want it.” He requested preserving
the code and evidence in GitHub, logging the handoff in Feedback and Karen memory,
cleaning the development area, and moving to other projects. Echo is parked.
The experiment is not accepted as the finished listening experience. Do not
resume implementation, monitoring, or automatic narration without his direction.

## Intended experience

Echo should follow the chat as soon as it is opened, without requiring a message.
Speech should start promptly, keep the favored Vivian voice, and feel as deliberate
and easy to control as the Speechify extension demonstrated on real web articles.
Play/Pause, Stop, speed and sentence movement should stay within the current work.

## Preserved implementation

- Exact connected-chat observer recovery, stale-callback protection, connection
  status and an Auto read switch. Immediate active-chat navigation is unresolved.
- Existing offline Qwen renderer emits each complete sentence. The Swift pipe
  reader uses POSIX reads so progress does not wait for the full audio file.
- Playback retains sentence audio under one reply identity, supports buffering,
  navigation, Pause/Resume and cancellation. Replay can restart a dismissed reply.
- Preparation, buffering, current sentence and position appear in the compact
  controller. Source-document word highlighting is absent.

## Evidence and practical limits

Native Swift build and signature verification passed for the local development
artifact `0.3.0-echo.6`. Executable SHA-256:
`8bb2ff05186a829381d26d439427e5205586288a0e2c1f9a03c427b7b9d46ba3`.
The production-code standalone playback checks passed. A strengthened production
renderer check delivered the first callback before sentence two or final reply
metadata existed, then cancelled and removed owned temporary audio.

That callback took **32.580 seconds** in the later test. An earlier Python-only
test emitted sentence one at 15.367 seconds and completed at 24.533 seconds;
it did not by itself prove prompt consumption by the original Swift reader.
The Python test measured 316 MiB peak process RSS excluding GPU memory. Neural
voice startup, buffer gaps and machine pressure remain material limitations.
This does not meet the desired instant-feeling experience or Karen's installed
voice performance budgets. No acoustic onset measurement was recorded.

The actual compact player was checked with Vivian: preparation, first-sentence
playback with more audio arriving, Pause/Resume, paused arrivals, Previous/Next,
Replay and Stop. Stop removed owned temporary reply files; stopping preparation
ended the synthesis child. An interruption required explicit Resume during the
live check. These checks do not supersede Osiris's rejection of the experience.

XCTest could not run because the selected Command Line Tools environment lacks
the XCTest module. Windows/Linux, standalone installation, source highlighting,
sustained resource budgets and uninterrupted listening acceptance are unverified.

Detailed records: [connection investigation](CHAT_CONNECTION_REPAIR.md),
[Speechify comparison and playback evidence](SPEECHIFY_REFERENCE_AND_PROGRESSIVE_PLAYBACK.md).
Private runtime data, model weights, account data, chat IDs and personal screenshots
are excluded from public source. Local build and QA artifacts are recoverably archived.

## Resume gates

1. Agree the actual listening workflow and observable acceptance with Osiris
   before another implementation pass. Retain Vivian unless he chooses otherwise.
2. Find a supported exact active-chat navigation signal. Verify A → B → A when
   merely opening chats; do not infer the visible chat from recency or messages.
3. Measure time to audible output, gaps, memory and CPU on the reference 8 GiB Mac.
   Evaluate the cold-start/model-lifetime tradeoff before promising instant playback.
4. Listen together and obtain acceptance of the whole experience, then choose
   whether to continue this Swift experiment or return to the separate Karen plan.

The GitHub branch/draft review preserves work; it is not a release, merge approval,
or a commitment to resume on a particular date. Feedback owns future task status.
