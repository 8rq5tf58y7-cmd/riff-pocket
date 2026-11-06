# Riff Pocket

A native iPhone app (iOS 26) for your Plaud Note Pro recordings: transcripts, AI summaries, and "ask your recording" chat. You can run the AI on the phone, on your own Ollama server, with an API key, or by signing in to a provider. Plaud sign-in works the same way as [Riffado](https://github.com/riffado/riffado), including **Apple-account sign-in**.

> Independent project, not affiliated with Plaud. It uses Plaud's unofficial cloud API with your own account.

See [VISION.md](VISION.md) for the design.

## How recordings get to the phone

```
Note Pro → official Plaud app → Plaud cloud → Riff Pocket (on your iPhone)
```

To connect your Plaud account, open Settings → Connect Plaud and choose one method:

| Method | For | How |
|---|---|---|
| **Apple / web** | Accounts created with **Sign in with Apple** (and email accounts) | Opens `web.plaud.ai` in the app. You tap *Continue with Apple*, and the app captures the `pld_ut` account token, the same token Riffado's Connector reads |
| **Email code** | Accounts created with email and password | Plaud emails you a one-time code |
| **Paste token** | **Google** accounts, or as a fallback | Google blocks sign-in inside apps. On a computer, open web.plaud.ai → DevTools → Application → Local Storage → copy `pld_tokenstr` |

The token lasts about 300 days and is stored in the iOS Keychain. Pull down on Recordings to sync. When Plaud has already made a transcript or summary, the app uses it. Otherwise it transcribes and summarizes with the provider you chose.

## Layout

| Path | What |
|---|---|
| `Packages/RiffCore` | Pure Swift: Plaud client (a port of Riffado's `src/lib/plaud`), AI clients (OpenAI-compatible/Ollama, Anthropic), summarizer. **Builds and tests on Windows** |
| `App/Sources` | SwiftUI app: Plaud sign-in web view, sync, recordings, detail views, mic recorder, settings |
| `project.yml` | XcodeGen spec. CI generates the Xcode project, so you never need Xcode locally |
| `.github/workflows/ios.yml` | Linux runs RiffCore tests. macOS builds the app and produces an unsigned `.ipa`. TestFlight upload is optional |

## Building from Windows (no Mac)

### 1. Shared logic, locally (optional)

**Through WSL Ubuntu** (Swift 6.4+ via [swiftly](https://www.swift.org/install/linux/)). From PowerShell, with your clone path:

```powershell
wsl -d Ubuntu -- bash -lc 'source ~/.local/share/swiftly/env.sh && cd /mnt/c/path/to/riff-pocket && swift test --package-path Packages/RiffCore --scratch-path ~/riffcore-build'
```

Alternatively, install Swift for Windows natively. It needs Visual Studio Build Tools; follow https://www.swift.org/install/windows/ (winget):

```powershell
winget install --id Swift.Toolchain -e
```

Then run the RiffCore tests:

```bash
swift test --package-path Packages/RiffCore
```

For editing, use VS Code with the **Swift** extension (swiftlang.swift-vscode).

### 2. The iPhone app, on GitHub Actions

1. Create a GitHub repo and push this folder.
   - A **public** repo gets free macOS minutes.
   - A private repo uses macOS minutes at 10× the Linux rate.
2. Each push runs **iOS** and uploads an **`RiffPocket-unsigned-ipa`** artifact.
3. Download the artifact and unzip it to get `RiffPocket-unsigned.ipa`.

### 3. Install on your iPhone 16

**Free option: [SideStore](https://sidestore.io)**

SideStore runs on the iPhone and installs and refreshes apps itself. You need the Windows PC once, to set it up. Its full guide is at [docs.sidestore.io](https://docs.sidestore.io/docs/installation/prerequisites).

*One-time setup*
1. **On the iPhone:**
   - Install **[LocalDevVPN](https://apps.apple.com/app/localdevvpn/id6755608044)** from the App Store.
   - Open it, tap **Connect** and allow the VPN.
   - You'll need Wi-Fi.
2. **On the PC:**
   - Install **[iTunes](https://www.apple.com/itunes/download/win64)** (Apple's direct download) for the iPhone USB driver.
   - Install **[iloader](https://iloader.app)** ([MSI](https://github.com/nab138/iloader/releases/latest/download/iloader-windows-x64.msi)).
3. Plug the iPhone in by USB and trust the computer.
4. Open iloader, sign in with your Apple ID, pick your iPhone, and choose **Install SideStore (Stable)**.
5. **Back on the iPhone:**
   - Go to Settings → General → **VPN & Device Management**.
   - Under *Developer App*, tap your Apple ID, then **Trust**.
   - Then go to Settings → Privacy & Security → turn on **Developer Mode**. The phone restarts.
6. Open **SideStore** and sign in with the same Apple ID.
7. In **My Apps**, tap SideStore's **7 DAYS** counter to refresh it once.

*Install Riff Pocket*
1. Open the latest **iOS** run under [Actions](https://github.com/8rq5tf58y7-cmd/riff-pocket/actions) and download **RiffPocket-unsigned-ipa**.
   - Downloading needs a signed-in GitHub account.
   - On the iPhone, the zip lands in Files; tap it to unzip.
   - Or download it on the PC and move `RiffPocket-unsigned.ipa` to the iPhone with iCloud Drive.
2. Make sure **LocalDevVPN** is connected and you're on Wi-Fi.
3. In SideStore → **My Apps**, tap **+** and pick `RiffPocket-unsigned.ipa`. SideStore signs it with your Apple ID and installs it.

*Keeping it running*
- **Refreshing:** free Apple ID signatures last **7 days**. SideStore refreshes apps in the background, or you can tap the app's day counter in My Apps. Keep LocalDevVPN connected and stay on Wi-Fi when it refreshes.
- **Updating:** install a newer `.ipa` the same way. It replaces the old one and keeps your notes.
- **Free Apple ID limits:** 3 active apps, including SideStore itself, and 10 new app IDs per week.
- **If installs start failing:** your pairing file may have expired. This can happen after an iOS update or reset. Follow SideStore's pairing-file guide.

No special entitlements are needed, so a free Apple ID works.

**Paid option ($99/yr Apple Developer): TestFlight from CI**
1. Change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` to your own ID.
2. Create an App Store Connect API key and the app record.
3. Add these repo secrets:
   - `ASC_KEY_ID`
   - `ASC_ISSUER_ID`
   - `ASC_KEY_P8_BASE64` (the .p8 file, base64)
   - `APPLE_TEAM_ID`
4. Actions → iOS → *Run workflow* → tick **testflight**.

### Debugging without Xcode

Use the iPhone console (e.g. via 3uTools or idevicesyslog), error messages in the app, and the `swift test` suite for logic. For the occasional hard bug, rent a cloud Mac for an hour.

## Your notes in Claude (claude.ai and the Claude iPhone app)

The **[Riff Pocket connector](connector/README.md)** is a small server you deploy once to your free Cloudflare account. Add it to Claude as a custom connector, and Claude can search and read your notes on the web, desktop and iPhone. Next to Claude's Notion connector, it can also file your notes into Notion. Setup takes about 10 minutes and is in the connector README.

## Desktop companion

**[Riff Desk](desktop/README.md)** runs on your computer and syncs with the iPhone. **Windows:** download **RiffDesk-windows** (a single `RiffDesk.exe`, nothing to install) from the latest run under [Actions](https://github.com/8rq5tf58y7-cmd/riff-pocket/actions). **Mac/Linux, or from source:** `python riffdesk.py` in `desktop/`, or double-click `Start Riff Desk.bat` on Windows.
- **Processing while your phone sleeps:** it pulls new Plaud recordings and transcribes, summarizes and names them. Your phone downloads just the results.
- **Desktop app:** a local web app for notes, folders, attachments and chat.
- **Pairing:** scan its QR code with the iPhone Camera.

## Features

- **Notes:** recordings synced from Plaud, mic recordings, or imported files. They're grouped by day, searchable, and can be sorted into **folders**.
- **Per-note tabs:** Summary (with templates), timestamped Transcript (tap a line to jump the audio there), and Ask (chat about that one note).
- **Chat tab (Library chat):** ask across **all notes**, **Unfiled**, or **one folder**. Long collections are handled by picking the most relevant excerpts and citing which note each answer came from.
- **Model chip on every chat and summary:** switch the **source** and **model** on the fly. You can also set it as the default.
- **Plaud 4.0 accounts:** these are detected automatically (status `-1800907`) and switched to the `/file-app/v4` API. This is ported from Riffado PR #328.
- **AI naming:** after summarizing, each note gets a short, specific, Plaud-style title (for example "Sprint Planning Q4 Roadmap"). Names you type yourself are never replaced, and you can optionally rename the recording in Plaud too.
- **Attachments:** add PDFs, text, Markdown, CSV, RTF or photos to a note. Their text, including on-device OCR for photos, is included in Ask and Library chat.
- **Processing that survives leaving the app:** transcribe → summarize → name runs as an iOS 26 continued-processing task, with a system progress Live Activity. On-iPhone transcription stays off the GPU so it can continue in the background. iOS doesn't let on-iPhone LLMs (MLX) use the GPU in the background, so pair Riff Desk or use a cloud/Ollama model for summaries that finish while you're away.
- **Summary styles:** set the format (bullets, prose, outline, Q&A), length, tone, sections, timestamps, language and your own instructions for each note. Eight built-in templates are included, you can save your own, and you can pick a default for new notes.
- **While you're away:** background refresh syncs new Plaud recordings and notifies you. Background processing can auto-transcribe and summarize, optionally only while charging. Work you started finishes after you leave the app, and leftovers run when you return. iOS decides the timing, and on-iPhone MLX models only run in the foreground.
- **Look:** warm ivory and charcoal surfaces, terracotta accent, serif headings, chat-style composer. Follows light and dark mode.

## AI sources

| Task | Options |
|---|---|
| Transcription | Plaud's own · **WhisperKit** on the phone · OpenAI/Groq Whisper (API key) |
| Summaries / Ask / Chat | Plaud's own summary · **Apple Foundation Models** · **Local models on the iPhone (MLX)** · **Ollama** on your computer (over Tailscale) · **Ollama Cloud** (API key) · OpenAI-compatible (API key) · **Anthropic** (API key) · **OpenRouter** (API key or sign in) |

**Local models (MLX):** download from the model picker or Settings → Local models.
- **Recommended:** Qwen3 1.7B (≈1 GB, default), Gemma 3 1B, Llama 3.2 3B, Phi-3.5 mini, Qwen3 4B.
- **Others:** any `mlx-community/…` model ID from Hugging Face. Up to about 4B parameters works well on an iPhone 16.
- **Privacy:** everything runs on the device, and only one model is loaded at a time.

## Status

Scaffold.
- **RiffCore** (Plaud client incl. 4.0, auth, sync planning, AI clients, summarizer, Library chat context) builds, and all 23 tests pass on Swift 6.4.2 (Linux/WSL).
- **The iOS app** compiles in CI with no warnings (49 MB app, including MLX and WhisperKit). It has not been tested on a device yet.

Known gaps:
- The Riffado `connect-token` call needs a Riffado session. Check whether your Riffado version accepts API keys there.
- Background sync, SpeechAnalyzer, and MLX models are not built yet (see VISION.md roadmap).

## License

Licensed under the [GNU AGPL-3.0](LICENSE). The Plaud sign-in, sync and Plaud 4.0 logic is a Swift port of [Riffado](https://github.com/riffado/riffado) (AGPL-3.0), including its Plaud 4.0 support from [riffado/riffado#328](https://github.com/riffado/riffado/pull/328). Thanks to the Riffado contributors.

## Disclaimer

Riff Pocket is an independent project. It isn't affiliated with, endorsed by, or connected to Plaud. It uses Plaud's unofficial cloud API with your own account, which can change or break at any time. Check Plaud's terms before you use it. Your API keys and Plaud token are stored only in your iPhone's Keychain. Nothing is sent to the authors of this project.
