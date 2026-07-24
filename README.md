# NUEditor

The AI-native video editor — the front-end of the **NUEDIT** post-production system.

NUEditor is a native macOS video editor (Swift, macOS 26, Apple Silicon) with a built-in
**MCP server** on `127.0.0.1:19789`, driven by the **NUEDIT** backend (ingest, VLM captioning,
transcript, A-roll/B-roll classification, script matching, and generation). See `CLAUDE.md` and
`docs/NUEDIT_ROADMAP.md` for the architecture and roadmap.

Forked from Palmier Pro (GPLv3); being rebuilt as a self-owned, local-first editor.

## Build

Requires macOS 26+, Xcode 16+, Swift 6.2.

```bash
swift build && swift run       # or: ./scripts/dev.sh  (debug .app + OSLog stream)
swift test
```
Use `swift build --traits BundledSpeech` for on-device speech/transcription work.

## License

GPLv3 — see [LICENSE](LICENSE).
