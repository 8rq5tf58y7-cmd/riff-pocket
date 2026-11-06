# Riff Desk: desktop companion

Riff Desk runs on your computer (Windows, macOS or Linux) and syncs with **Riff Pocket** on your iPhone. It does two jobs.

**Processes notes while your phone sleeps.** When you share your Plaud sign-in with it:
1. Riff Desk pulls new Plaud recordings itself.
2. It transcribes, summarizes and names them on your computer.
3. Your iPhone downloads only the results, even during background refresh.

**Gives you a desktop app** at `http://localhost:8765`, in the same warm style as the iPhone app:
- Notes, folders and search.
- Summaries, transcripts with click-to-play timestamps, and attachments.
- Ask on a note, and Library chat across all notes or one folder.
- Audio import.

It uses only the Python standard library, so there's nothing to install except Python itself.

## Get it

- **Windows, easiest:** open the latest run under [Actions](https://github.com/8rq5tf58y7-cmd/riff-pocket/actions), download **RiffDesk-windows** and unzip it. Then double-click **`RiffDesk.exe`**: Python is bundled, so there's nothing to install. Windows SmartScreen may warn about an unsigned app; choose *More info → Run anyway*.
- **From source, on any OS:** follow the steps below. On Windows you can also double-click **`Start Riff Desk.bat`**.

## Run it

1. Install **Python 3.10 or newer** ([python.org](https://www.python.org/downloads/); on Windows tick *Add python.exe to PATH*).
2. Start it from this folder:

   ```bash
   python riffdesk.py
   ```

   Your browser opens the app. Data lives in `~/RiffDesk`, which you can change with `--data`, and the port with `--port`.

## Pair your iPhone

1. In Riff Desk, open **Settings & pairing**.
2. Point the iPhone **Camera** at the QR code and tap the link. Riff Pocket asks you to confirm.
   - Alternatively: Riff Pocket → Settings → Desktop companion → paste the link.
3. In Riff Pocket → Settings → Desktop companion, tap **Let the desktop sync Plaud**.

The phone and computer must be able to reach each other:
- **Same Wi-Fi:** works out of the box. Allow Python through the Windows firewall when asked (*Private networks*).
- **Away from home:** install [Tailscale](https://tailscale.com) on both and pair using the computer's Tailscale address (`100.x.y.z`).

## Set up the AI

Open **Settings & pairing** in Riff Desk.

| | Options |
|---|---|
| Transcription | **OpenAI-compatible Whisper**: OpenAI, Groq, or a local whisper server. Or **faster-whisper** on this computer (`pip install faster-whisper`, fully local). |
| Summaries, titles, chat | **Ollama** on this computer · **Ollama Cloud** · OpenAI-compatible · OpenRouter · Anthropic |

API keys are stored in `~/RiffDesk/config.json` on this computer only.

Each note's summary format comes from the iPhone: its own style, or your default template. Tap **Send my summary format & automation settings** in the phone's Desktop companion screen after changing them.

## Security

- **iPhone sync API:** needs the pairing token in the QR code. **Reset pairing** issues a new one, which unpairs every device.
- **Web app:** only answers requests from this computer.
- **Your data stays local:** nothing is sent anywhere except to the AI providers you configure and to Plaud, when connected.

## Tests

```bash
python -m unittest discover -s tests
```
