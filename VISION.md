# Vision: Riff Pocket, a native iPhone companion for Plaud recordings

Working name **Riff Pocket**. Avoid Plaud's name and logo in the product.

A **native Swift/SwiftUI app for the iPhone 16 (iOS 26)** that works like the Plaud app: recordings, transcript, AI summary, and "ask your recording" chat. It gets your Note Pro recordings **from your Plaud account**, signing in the same way **Riffado** does, and runs AI **on the phone**, on **Ollama**, through an **API key**, or through a **sign-in**. A self-hosted Riffado server is optional.

The developer uses **Windows**, so the pipeline needs no Mac (see §6).

---

## 1. Getting recordings: the Riffado approach, done on the phone

No Bluetooth or hotspot work. The Note Pro keeps syncing to Plaud's cloud through the official Plaud app, as it does today. Riff Pocket reads your recordings from there.

```
Note Pro ──BLE/Wi-Fi──▶ official Plaud app ──▶ Plaud cloud (api*.plaud.ai)
                                                    │  Bearer <user token>
                                                    ▼
                                    Riff Pocket (iPhone) ── optional ──▶ Riffado server
                                    on-device AI / Ollama / API key       (desktop, webhooks)
```

### How Riffado connects (from its source, `src/lib/plaud/*`)

| Concept | Detail |
|---|---|
| **User token (UT)** | Long-lived JWT (about 300 days), no refresh token. This is the credential to store. |
| **Workspace token (WT)** | Short-lived (about 24 h). Minted from the UT: `GET /team-app/workspaces/list?need_personal_workspace=true` → pick `workspace_type == "0"` → `POST /user-app/auth/workspace/token/{id}`. Data calls use the WT and fall back to the UT. A pasted WT has `ut_ref`/`wid` claims and must be rejected, because it dies within a day. |
| **Regions** | `api.plaud.ai` (global), `api-euc1.plaud.ai` (EU), `api-apse1.plaud.ai` (APAC), `api.plaud.cn`. On the email-code flow, `status: -302` gives the regional host in `data.domains.api`. |
| **Email-code sign-in** | `POST /auth/otp-send-code {username}` → `{token}`, then `POST /auth/otp-login {code, token}` → `access_token`. **Doesn't work for Apple or Google accounts**: it signs into a separate, empty email-only account (Riffado issue #65). |
| **Apple/Google accounts** | The Riffado Connector extension opens `web.plaud.ai`, lets you sign in normally, then reads the **`pld_ut` HttpOnly cookie** (or `localStorage.pld_tokenstr`), validates it, and posts it to Riffado `/api/plaud/auth/connect-token`. |
| **Data** | `GET /device/list` · `GET /file/simple/web?skip&limit&is_trash=0&sort_by=edit_time&is_desc=true` · `GET /file/temp-url/{id}?is_opus=0|1` → presigned audio URL · `GET /file/detail/{id}` → Plaud's own transcript and summary links (gzip JSON) |
| **Quirks** | Browser-like User-Agent required (Riffado regression #132). Back off on 429/5xx. Plaud blocks some datacenter IPs, which is why Riffado has an optional residential proxy. |

### Riff Pocket's sign-in, natively (Apple account first)

1. **Sign in with Apple, via Plaud's website (default).** The app opens `https://web.plaud.ai` in an in-app **`WKWebView`**. You tap Plaud's "Continue with Apple" button and sign in as usual. The app then reads the **`pld_ut` cookie from `WKHTTPCookieStore`**, which a native app can do even for HttpOnly cookies, falling back to `localStorage.pld_tokenstr`. It rejects workspace tokens, validates with `/team-app/workspaces/list` + `/device/list`, and stores the UT in the **Keychain**.
   - This is the Riffado Connector's approach without a browser extension.
   - The app never sees your Apple password, because Apple's own sign-in page handles it.
   - Popups (Apple's `window.open` flow) are handled with a child `WKWebView` that shares the configuration.
2. **Email code.** A native form uses the OTP endpoints, for accounts created with email.
3. **Paste token.** A last resort, with region picker and WT detection. This is also the path for **Google** accounts: Google blocks sign-in inside embedded web views (`disallowed_useragent`), so those users copy `pld_tokenstr` from a desktop browser.

**Bonus of running on the phone:** requests come from your own residential or cellular IP, so the datacenter-IP blocking that forces Riffado's proxy doesn't apply.

**Token lifetime:** about 300 days. The app decodes `exp`, warns 14 days before expiry, and shows "Reconnect" on a 401.

### Sync

- Pull-to-refresh, plus `BGAppRefreshTask` every few hours.
- List `/file/simple/web` and diff it against local records by `id` and `version_ms`.
- Download new audio with `/file/temp-url/{id}?is_opus=0`, which gives MP3/M4A that AVFoundation and WhisperKit read directly.
- **Reuse Plaud's own transcript and summary** when `is_trans`/`is_summary` is set: `/file/detail/{id}` → `content_list` → `transaction` (segments, in ms) and `auto_sum_note`. Otherwise transcribe locally.
- Read-only toward Plaud for now; renaming via `PATCH /file/{id}` comes later.

### Optional: Riffado mode

The app can also **hand the token to your Riffado server** (`POST /api/plaud/auth/connect-token`, `source: "connector"`), so Riffado's web UI, webhooks and scheduled sync work for desktop too. One sign-in on the phone connects both.

---

## 2. AI: everything selectable per task

`RiffCore` defines `Transcriber` and `ChatModel`. The app's `AIRouter` picks a backend per task (transcribe, summarize, chat).

| Backend | Transcribe | Summarize / Chat |
|---|---|---|
| **Plaud's own** | Use Plaud's transcript if it exists | Use Plaud's summary if it exists |
| **Apple on-device** | SpeechAnalyzer (iOS 26, later phase) | **Foundation Models** |
| **Open models on the device** | **WhisperKit** (Neural Engine) | **MLX Swift** (later phase) |
| **Ollama** | — | Any model, via its OpenAI-compatible API over Tailscale |
| **API key** | OpenAI / Groq Whisper | OpenAI-compatible, **Anthropic** |
| **Sign in** | — | **OpenRouter** OAuth PKCE |

Long recordings go through chunked map-reduce (`Summarizer`), so the about-4k-token on-device model can handle hour-long meetings.

---

## 3. App structure

```
openplaud/
├─ project.yml                      XcodeGen spec (the .xcodeproj is generated on CI)
├─ App/Sources/
│  ├─ RiffPocketApp.swift           tabs: Recordings · Record · Settings
│  ├─ Model/RecordingItem.swift     SwiftData (plaudId, version, audio, transcript, summary)
│  ├─ Plaud/                        WebLoginView (WKWebView + cookie capture), ConnectView, SyncService
│  ├─ AI/                           AIRouter, Foundation Models, WhisperKit, Keychain, OpenRouter sign-in
│  └─ Views/                        Recordings, Detail (Transcript/Summary/Ask), Record, Settings
├─ Packages/RiffCore/               pure Swift; builds and tests on Windows
│  ├─ Plaud/ PlaudClient, PlaudAuth (OTP, JWT claims), PlaudModels, PlaudContent
│  ├─ AI clients (OpenAI-compatible/Ollama, Anthropic), Summarizer
│  └─ RiffadoClient (health, connect-token)
└─ .github/workflows/ios.yml        Linux: RiffCore tests · macOS: app build → unsigned .ipa
```

---

## 4. Data and privacy

- **SwiftData** on the device. Audio lives in `Documents/Recordings`, which is visible in the Files app.
- **Plaud token and API keys** are stored in the **Keychain** (`AfterFirstUnlockThisDeviceOnly`).
- The `WKWebView` uses a **non-persistent data store**, so no Plaud web session lingers after the token is captured.

---

## 5. Roadmap

| Phase | Deliverable |
|---|---|
| **0** | Repo on GitHub, CI green, unsigned `.ipa` sideloaded onto the iPhone |
| **1** | Plaud connect (Apple via web view, email code, paste) → recordings list → audio playback |
| **2** | Import Plaud's transcripts and summaries; WhisperKit and Foundation Models when they're missing |
| **3** | Provider layer: Ollama, API keys, Anthropic, OpenRouter sign-in |
| **4** | Ask chat with timestamp citations, background refresh, expiry warnings |
| **5** | Riffado mode (send the token to the server), mic recording, MLX models, Shortcuts |

---

## 6. Building an iOS app from Windows

| Piece | Tool |
|---|---|
| Code | VS Code with the Swift extension |
| Shared logic | Swift for Windows → `swift test` in `Packages/RiffCore` |
| iOS build | GitHub Actions macOS runner (XcodeGen + `xcodebuild`) |
| Install, free | Unsigned `.ipa` → **SideStore** on the iPhone (set up once with iloader on Windows; free Apple ID, auto-refresh every 7 days) |
| Install, $99/yr | TestFlight from CI |
| Debugging | OSLog and an in-app log view. Rent a cloud Mac occasionally if needed |

No special entitlements are needed any more (Bluetooth and hotspot are gone), so **the free Apple ID path is enough** for this app.

---

## 7. Risks

- **The Plaud API is unofficial.** Endpoints can change. Track Riffado's `src/lib/plaud` as the canary, since they hit breakages first.
- **Web view sign-in.** Plaud's website or Apple's flow might change or block embedded views. Pasting the token is the fallback.
- **Terms of service.** This uses your own account and data, but read Plaud's terms. Not for the App Store.
- **AGPL.** Porting Riffado's TypeScript logic to Swift is a derivative work. Keep Riff Pocket **AGPL-3.0** too, and credit Riffado.
