# voice-probe

Live end-to-end probe for `vibe.voice.v1` (docs/agent-voice-v1.md). Talks to a running
vibe-core + vibe-agent-runtime — it does not start either, and the runtime's own
environment must have a real `OPENAI_API_KEY` set for a call to actually connect upstream.

## Prerequisites
- vibe-core and vibe-agent-runtime running and reachable.
- A Bearer token for a user who participates in `--chat`, and an agent id (`--agent`)
  that user owns or that is published, with voice enabled.
- macOS for `mkaudio.sh` (uses `say`/`afconvert`). Node with the repo-root `ws` package.

## Commands

```sh
./mkaudio.sh "Hello, what is today's date?"   # -> prints the path to q.wav

node voice-probe.js --core http://127.0.0.1:4000 --token "$BEARER" \
  --agent <agentId> --chat <chatId> --wav q.wav \
  [--text "typed question"] [--runtime-ws ws://...] [--seconds 40] [--out .]

afplay ./agent-<ts>.wav   # listen to the collected agent reply
```

`--runtime-ws` overrides the `ws_url` the core returns (useful behind a tunnel/port
forward). Every inbound frame is logged with a timestamp; the run ends with a summary
JSON (`sessionId`, `readyMs`, `firstAgentAudioMs`, transcripts, `agentAudioSeconds`,
frame counts, errors). Exit 0 only if agent audio or an agent transcript arrived.
