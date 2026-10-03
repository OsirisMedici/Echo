# Echo chat connection repair — 3 October 2026

Osiris requires Echo to follow immediately when he opens a different Codex chat. This requirement is **not implemented**. Sending a message first is not an accepted substitute.

The running app was bound to an older chat rather than the current chat. The inherited bridge validates a specified chat, follows its completion records and can submit to that chat. It exposes no proven current-navigation signal. Controlled navigation between two existing chats did not update the user-activity marker or produce a chat-selection broadcast. That marker changes on messages, so its prototype was withdrawn after Osiris clarified the requirement. Computer Use rejects `com.openai.codex` for safety reasons; no alternate UI control was used. No supported active-view event was found in the documented hook/plugin APIs. These are limits of the integrations inspected, not a claim that no future integration can provide navigation.

This is historical evidence from the connection pass. The later narration experiment and parking decision supersede its running-state handoff; see [parked handoff](ECHO_PARKED_HANDOFF.md).

## Installed local repair

Built from the Echo source checkout, branch `codex/echo-connection-recovery`, baseline commit `4cc86a71a2e0501dce5cc2b77d607a4b65c1b15b` plus the recorded connection changes. Historical bundle: `app/Echo.app`, version `0.3.0-echo.2`.

Executable SHA-256: `acf8f0ce405fc2c411a37f3ca7adf89d1a0ac610ea86992e23937fe3eaad6c33`.

- Recover an enabled completion observer after unexpected termination, with a three-second retry.
- Ignore callbacks queued by an earlier observer process after the subscription changes.
- Recover only pending activities belonging to the connected chat.
- Show connected chat, current observation status/error and an Auto read switch in the floating player.
- Connected the intended exact chat locally; personal chat identifiers are excluded from this repository. Kept Karen/Qwen voice preferences and the existing channel. Before-edit private settings are in the support folder's `setup-backups`.

## Verification

Swift build passed using the existing dependency scratch directory at `SpeakEasy/app/.build`; no dependencies or voice engines changed. Deep strict ad-hoc signature check and Git whitespace check passed. An initial manual package missed the Frameworks rpath; corrected before successful launch. An initial connection edit used a numeric date instead of the store's ISO-8601 date; corrected before final accepted readback. Previous settings were backed up and existing activity records retained.

Native UI showed the intended connected chat, Auto read on and Watching. Actual observer termination produced a replacement process after about three seconds. Auto read off persisted and removed the observer process; enabling it again created a watcher. The app was running with automatic reading enabled at that historical check. Observed native process RSS about 39 MB; no sustained CPU or latency acceptance measurement. Existing transcript observer still polls at 150 ms. No Accessibility, microphone or screenshot permission added.

No fresh completed reply or audible narration from this turn can be verified before the turn finishes. To test the connected chat: send a short request and wait for its final reply; Echo should read it using the existing voice. Qwen prepares the whole response before playback and may be slow. Switching to another chat alone still will not retarget Echo. No Windows/Linux change or acceptance, Codex modification, or new hook trust was part of that check.

## Required next capability

A supported exact active-chat/navigation event (chat ID and host ID), fired on every navigation including cached chats and scoped to the focused window. Once available, feed it into subscription switching, cancel obsolete speech and verify A → B → A navigation without sending any prompt. Do not infer the visible chat from last reply, recency, title or the latest user message.

Sources checked with the OpenAI Docs skill: [Hooks](https://learn.chatgpt.com/docs/hooks), [Plugin reference](https://developers.openai.com/plugins/reference). Hook events cover turn/session lifecycle; session end does not fire immediately when switching away.
