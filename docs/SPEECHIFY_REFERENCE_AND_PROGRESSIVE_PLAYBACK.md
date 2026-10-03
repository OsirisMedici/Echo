# Speechify reference and Echo's first playback pass

This experiment is **parked and not accepted** as the desired product experience.
See [the parked handoff](ECHO_PARKED_HANDOFF.md) for the decision and resume gates.

## Outcome

Osiris wants Echo to feel as responsive and deliberate as Speechify while keeping
the Vivian voice he likes. Reading should stay close to the current work, make
its position obvious, and respond to Stop and Pause even while audio is being
prepared. Success means a long reply can begin before its entire audio file is
ready, with one coherent reply identity and reliable movement through sentences.

## Reference inspected on 2026-10-03

Osiris installed the official Speechify extension and signed into his account in
Codex's in-app Browser. The agent continued its read-aloud onboarding and used it
on [Speechify's listening article](https://speechify.com/blog/how-to-listen-faster/)
and [Paul Graham's independent essay](https://paulgraham.com/greatwork.html).
The native browser toolbar is outside the available page controls; Osiris clicked
the extension icon once on the independent essay to expose its player.

Observed in the real extension, distinct from the site's embedded demo:

- A narrow player at the page edge keeps the document visible.
- The sentence has a light highlight, with a stronger highlight on the current
  word. Highlighting advances through text while narration is active.
- Play/Pause and a remaining-time label give immediate visible state.
- The expanded controls expose voice, speed, backward/forward movement, and
  settings. The speed menu shows direct presets and optional gradual increases.
- Changing speed on the Speechify article carried over to the independent page.
  Osiris subsequently chose 1.3× himself; this setting was left intact.
- The independent essay showed roughly 49 minutes at the initially selected
  speed. The interface did not require exporting or preparing a document first.
- The fresh-start click returned its initial control state quickly, and moving
  highlighting was visible by the next screenshot about 5.3 seconds later.
  This is **not** a measured acoustic time to first sound: the tools did not
  record the speaker output, and user interaction occurred during inspection.
- The essay was left paused and the reference tabs were preserved.


No Speechify source, voices, account credentials, or proprietary assets were
copied into Echo. Its internal buffering, synthesis, and caching implementation
were not inspected. The reference informs the experience, not a claim about
Speechify's architecture or an exact latency benchmark.

## What this pass builds

Echo's development edition now accepts finished sentences from its existing
offline Qwen adapter. The first complete sentence starts playback; later ones
arrive under the same reply ID. It retains earlier audio while a reply is active
so Previous, Next, and the position slider can cross segment boundaries.

The compact controller includes Replay after Stop, and shows preparation, buffering, current sentence emphasis,
elapsed time, and whether more audio is arriving. Stop cancels synthesis rather
than merely stopping an already finished file. A paused reply stays paused when
new audio arrives. Only finishing the entire reply marks the completion activity
as announced. An interactive turn still takes priority over completion narration.

The adapter also writes the original complete WAV for the existing replay path.
Sentence audio and metadata are private temporary files. Finish, Stop, and
generation cancellation remove owned temporary files. The Python process exits
after each reply, releasing the model. No new runtime or dependency was added.

## Tradeoffs and limits

This is progressive delivery of **completed sentences**, not token streaming
from Codex and not word-aligned highlighting in Codex. The completion bridge
still delivers the final reply only. Active chat following when merely opening
another chat remains unresolved; see [the connection repair evidence](CHAT_CONNECTION_REPAIR.md).
The UI truthfully identifies its connected chat rather than claiming to follow
the foreground chat.

On this Mac, Vivian's generation may be slower than playback. Starting earlier
can therefore expose pauses while the next sentence is being generated. Echo
labels that state instead of treating it as a completed reply. A very long first
sentence still takes longer to prepare. Subsequent work should measure a buffer
policy and model readiness before claiming smooth uninterrupted playback or
instant startup. Keeping the model warm would trade additional resident memory
for reduced loading delay; that policy has not been introduced.

Speechify-style word highlighting on the source document and immediate chat
switching need reliable application integration. An estimated word clock or
guessing from recent message activity would not meet Osiris's requested behavior.

## Verification

- Native Swift package build passed against existing pinned dependencies.
- The selected XCTest suites could not compile because this Mac has Command
  Line Tools but no XCTest module. Added XCTest coverage remains available for
  an Xcode-equipped environment.
- The standalone acceptance runner compiled the production `PlaybackEngine`,
  `PlayerProtocol`, `SpeechSentences`, and `ProgressiveSpeechBuffer`, stubbing
  only unrelated HUD/configuration adapters. It passed buffering, whole-reply
  completion, Pause/Resume, retained sentence seeking, Stop, late-audio rejection,
  cleanup, and interactive-priority checks with silent WAVs.
- The packaged offline Python adapter test produced three ordered sentences in
  Vivian. The first was ready at **15.367 s**, and the complete reply at
  **24.533 s**. Concatenated sentence PCM exactly matched the complete WAV. File
  permissions were private and all temporary test audio was removed.
- That test measured peak process RSS **316.0 MiB**, excluding GPU memory.
  This optional neural voice does not meet Karen's installed-voice memory or
  sub-500 ms startup budgets. Progressive delivery does not eliminate model
  loading or inference time. No instant-start claim is warranted.
- Live follow-up found that Foundation's `FileHandle.read(upToCount: 4096)`
  waited for its requested buffer or EOF on this Mac. Python's earlier sentence
  timing alone therefore did not prove timely Swift delivery. The renderer now
  uses a POSIX pipe read that returns available bytes without filling a buffer.
- The strengthened cancellation runner uses the production Swift renderer and
  packaged resource. It asserts that the first callback arrives before sentence
  two exists and before completed-reply metadata exists, then cancels and checks
  every owned audio file is removed. It passed: first callback **32.580 s** in
  this run. This timing varies with model loading and machine pressure; it is
  not an acoustic onset measurement or an instant-start claim.
- Live Replay also exposed an old dismissed-state guard rejecting fresh audio.
  Explicit replay now succeeds while Stop still cancels the owning render task.
- Pause handles an interrupted audio engine; failed Play/Resume reports an
  error instead of claiming Playing. The progress timer stops when playback
  is interrupted. Paused arrivals retain the user's intent.
- Installed artifact: `app/Echo.app`, version `0.3.0-echo.6`, executable SHA-256
  `8bb2ff05186a829381d26d439427e5205586288a0e2c1f9a03c427b7b9d46ba3`.
  Deep/strict signature verification passed after copying finished. The prior
  `0.3.0-echo.2` bundle remains preserved at
  `/tmp/echo-progressive-check/Echo-before-progressive.app`; the v3 bundle is
  also preserved at `/tmp/echo-progressive-check/Echo-before-state-recovery.app`.
- The installed v6 app was verified unlocked in its real compact controller:
  exact connected chat, Auto on, Preparing Vivian, first-sentence playback with
  More coming, and Pause/Resume. Pause survived arrival from one to six
  sentences, and remained paused through all eight sentences. Previous/Next
  moved across retained segments. Stop returned to Idle and a filesystem check
  confirmed all owned reply/segment/metadata files were removed. A second
  Replay followed by Stop during Preparing returned to Idle and the owned
  synthesis subprocess exited. Screenshots are retained in the private local recovery archive; personal UI evidence is excluded from public source.
  The initial playback was observed paused after an interruption; explicit
  Resume returned it to Playing. No acoustic output was recorded.
- An unlocked idle process snapshot after launch showed CPU **0.0%** and RSS
  **40.1 MiB**. This is a single process sample, not a sustained real-memory
  acceptance result, and excludes the optional voice subprocess. Resource
  compression on this 8 GiB Mac makes later RSS samples poor measures of the
  neural voice's full footprint. No cross-platform or neural resource-budget
  acceptance claim is made.



Acceptance helpers are in `scripts/check-progressive-playback.swift`,
`scripts/check-qwen-progressive.py`, and `scripts/check-qwen-cancellation.swift`.
The Python helper takes an optional packaged adapter path and uses only
disposable synthetic text, the existing local model, and offline settings.

## Manual listening check

In the connected chat, request a multi-paragraph reply. Echo should show
Preparing Vivian, then start the first sentence while more audio is arriving.
Pause; arriving audio must not resume it. Try Previous, Next, and position
movement within prepared audio. Stop during preparation or playback; that reply
must not resume when a later sentence finishes. Listen for buffer gaps and
natural voice continuity. These by-ear judgments require Osiris's feedback.

The source remains on `codex/echo-connection-recovery`, based on
`4cc86a71a2e0501dce5cc2b77d607a4b65c1b15b` with the preserved experiment changes.
This is a macOS Echo development build, not a cross-platform Karen release.
