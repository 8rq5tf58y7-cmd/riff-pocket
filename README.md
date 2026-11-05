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

**Already set up on this machine, through WSL Ubuntu** (Swift 6.4.2 via swiftly). From PowerShell:

```powershell
wsl -d Ubuntu -- bash -lc 'source ~/.local/share/swiftly/env.sh && cd /mnt/c/Users/ryanf/Downloads/openplaud && swift test --package-path Packages/RiffCore --scratch-path ~/riffcore-build'
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

**Free option: Sideloadly (Windows)**
1. Install [Sideloadly](https://sideloadly.io) and iTunes (the non-Store version, for the USB driver).
2. On the iPhone, turn on Settings → Privacy & Security → **Developer Mode**.
3. Plug in the iPhone, drop in the `.ipa`, and sign with your Apple ID.
4. The build expires after 7 days, so re-sideload it then.

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

Use console logs through the Sideloadly/3uTools device console, error messages in the app, and the `swift test` suite for logic. For the occasional hard bug, rent a cloud Mac for an hour.

## AI providers

| Task | Options |
|---|---|
| Transcription | Plaud's own · **WhisperKit** on the phone · OpenAI/Groq Whisper (API key) · Ollama-compatible Whisper server |
| Summaries / Ask | Plaud's own summary · **Apple Foundation Models** on the phone · **Ollama** (over Tailscale) · OpenAI-compatible (API key) · **Anthropic** (API key) · **OpenRouter** (sign in) |

## Status

Scaffold.
- **RiffCore** (Plaud client, auth, sync planning, AI clients, summarizer) builds, and all 16 tests pass on Swift 6.4.2 (Linux/WSL).
- **The iOS app target** hasn't been compiled yet, because it needs the iOS SDK. The first CI run will surface any errors.

Known gaps:
- The Riffado `connect-token` call needs a Riffado session. Check whether your Riffado version accepts API keys there.
- Background sync, SpeechAnalyzer, and MLX models are not built yet (see VISION.md roadmap).

## License

The Plaud sign-in and sync logic is ported from Riffado (AGPL-3.0), so this project should be **AGPL-3.0** too. Add a `LICENSE` file before publishing the repo.
