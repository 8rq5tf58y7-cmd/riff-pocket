#!/usr/bin/env python3
"""Riff Desk — desktop companion for Riff Pocket.

    python riffdesk.py                  # start (opens the web app in your browser)
    python riffdesk.py --port 9000      # another port
    python riffdesk.py --data ~/Notes   # another data folder

Needs only Python 3.10+. Optional: `pip install faster-whisper` for transcription on this computer.
"""

import argparse
import os
import sys
import threading
import webbrowser
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from riffdesk import __version__  # noqa: E402
from riffdesk.config import Config  # noqa: E402
from riffdesk.server import App, serve  # noqa: E402
from riffdesk.store import Store  # noqa: E402
from riffdesk.worker import Worker  # noqa: E402


def main():
    # Windows consoles often use a legacy code page that can't print "✻" etc.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
    parser = argparse.ArgumentParser(description="Riff Desk — desktop companion for Riff Pocket")
    parser.add_argument("--data", default=os.environ.get("RIFFDESK_DATA", str(Path.home() / "RiffDesk")),
                        help="data folder (default: ~/RiffDesk)")
    parser.add_argument("--port", type=int, default=None, help="port (default 8765)")
    parser.add_argument("--host", default="0.0.0.0", help="address to listen on (default: all, so your phone can reach it)")
    parser.add_argument("--no-browser", action="store_true", help="don't open the web app")
    args = parser.parse_args()

    root = Path(args.data).expanduser()
    root.mkdir(parents=True, exist_ok=True)
    config = Config(root)
    if args.port:
        config.set("port", args.port)
    port = int(config.get("port") or 8765)

    store = Store(root)
    worker = Worker(store, config)
    app = App(store, config, worker)
    httpd = serve(app, args.host, port)
    worker.start()

    pairing = app.pairing(port)
    print(f"\n  ✻ Riff Desk {__version__}")
    print(f"    Web app:   http://localhost:{port}")
    print(f"    Data:      {root}")
    for url in pairing["urls"]:
        print(f"    Phone URL: {url}")
    print("    Pair from Riff Pocket → Settings → Desktop companion (scan the QR in the web app's Settings).\n")
    if not args.no_browser:
        threading.Timer(0.8, lambda: webbrowser.open(f"http://localhost:{port}")).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping…")
    finally:
        worker.stop()
        httpd.server_close()


if __name__ == "__main__":
    main()
