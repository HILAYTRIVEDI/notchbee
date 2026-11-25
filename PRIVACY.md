# Privacy

Notchbee’s built-in engine stores chat and workflow history and operational logs locally. The Usage page reads local provider history and can fetch account quotas and public prices. Notchbee sends no product telemetry, analytics, crash reports, or diagnostic traces. Sparkle system profiling is disabled.

When you run a session, providers and agents you configure may receive prompts, attachments, workspace context, and other data needed for that session. Sign-in and quota checks contact the relevant provider. An independently installed agent, tool, or extension can make its own requests and handle data under its own policies.

The Core ML dictation models download from Hugging Face and run on your Mac. If Apple Speech is used as a fallback, macOS may download an Apple-managed speech asset. Sending a transcript as a prompt or asking a provider to clean up or process dictation shares that text with the selected provider. Optional cloud speech supported by the engine sends audio to the configured speech service when used.

Notchbee uses its bundled engine and keeps its data separate from T3 Code. The Claude and Cursor SDKs download from `registry.npmjs.org` only after you review the named package, vendor terms and version and choose to install. The engine verifies the pinned SHA-512 hashes and extracts the packages into its private data directory without running install scripts.

Notchbee does not modify these vendor SDKs. If you choose to use Cursor, Cursor’s SDK may send usage events to Cursor under [Cursor’s privacy policy](https://cursor.com/privacy). The same applies to any provider you sign in to: its own software and service handle your data under its own terms. Notchbee itself sends nothing.

Git operations follow configured remotes. Provider discovery and installation, public pricing and catalogs, and app updates can contact their respective hosts. Update checks read the appcast attached to the latest GitHub Release. See the [engine network inventory](engine/NETWORK.md) for destinations and purposes.
