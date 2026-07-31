#!/usr/bin/env python3
"""buzz-bridge: receives LoggiFly webhook alerts and posts them to Buzz.

Two modes:

  Channel mode (preferred): alerts are posted as kind:9 into a community
  channel, p-tagging a buzz-acp agent so it sees the mention and can bring
  the alert up in the server. On startup the bot joins the channel with a
  kind:9021 join request (works on open channels; for private channels
  someone inside must run `buzz channels add-member`).

  DM mode (fallback): alerts are sent as DMs to a pubkey. Buzz DMs are not
  NIP-04/NIP-17 — a DM is a hidden private channel: publish kind:41010 with
  a p-tag for the recipient -> relay creates/dedupes the DM channel and
  answers with response:{"channel_id": "<uuid>"}, then kind:9 with
  h=<channel_id> and p=<recipient>.

Everything goes through the relay's HTTP bridge (POST {relay}/events with
NIP-98 auth), which is what the `buzz` CLI itself does. `nak` is used
offline to sign events; transport is plain HTTPS via urllib.

Env:
  BUZZ_RELAY_HTTP_URL   base URL of the relay HTTP bridge (default https://buzz.xyz)
  BUZZ_BOT_PRIVATE_KEY  sender key, hex or nsec (this bot's identity)   [required]
  BUZZ_ALERT_CHANNEL    channel UUID -> channel mode
  BUZZ_AGENT_PUBKEY     agent to @mention, 64-char hex [required in channel mode]
  BUZZ_OWNER_PUBKEY     DM recipient, 64-char hex      [required in DM mode]
  BRIDGE_TOKEN          if set, POSTs must send "Authorization: Bearer <token>"
  PORT                  listen port (default 8788)
"""

import base64
import hashlib
import http.server
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.request

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("buzz-bridge")

RELAY = os.environ.get("BUZZ_RELAY_HTTP_URL", "https://buzz.xyz").rstrip("/")
BOT_KEY = os.environ.get("BUZZ_BOT_PRIVATE_KEY", "")
CHANNEL = os.environ.get("BUZZ_ALERT_CHANNEL", "")
AGENT = os.environ.get("BUZZ_AGENT_PUBKEY", "").lower()
OWNER = os.environ.get("BUZZ_OWNER_PUBKEY", "").lower()
TOKEN = os.environ.get("BRIDGE_TOKEN", "")
PORT = int(os.environ.get("PORT", "8788"))

EVENTS_URL = f"{RELAY}/events"
MAX_MSG_LEN = 1800
NAK_BIN = shutil.which("nak") or "/usr/local/bin/nak"

_lock = threading.Lock()
_dm_channel = os.environ.get("BUZZ_DM_CHANNEL", "")
_joined = False


def nak_sign(kind, content, tags):
    """Build and sign an event offline with nak; returns the event dict."""
    cmd = [NAK_BIN, "--sec", BOT_KEY, "event", "-k", str(kind), "-c", content]
    for tag in tags:
        cmd += ["--tag", tag]
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        raise RuntimeError(f"nak sign failed: {out.stderr.strip()}")
    # nak prints the signed event JSON on the last stdout line
    return json.loads(out.stdout.strip().splitlines()[-1])


def post_event(event):
    """Submit a signed event to the relay HTTP bridge with NIP-98 auth."""
    body = json.dumps(event).encode()
    payload_hash = hashlib.sha256(body).hexdigest()
    auth_event = nak_sign(27235, "", [
        f"u={EVENTS_URL}",
        "method=POST",
        f"payload={payload_hash}",
    ])
    auth_b64 = base64.b64encode(json.dumps(auth_event).encode()).decode()
    req = urllib.request.Request(
        EVENTS_URL,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Nostr {auth_b64}",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read().decode()


def open_dm():
    """Publish kind:41010 and extract the DM channel UUID from the response."""
    event = nak_sign(41010, "", [f"p={OWNER}"])
    resp_text = post_event(event)
    m = re.search(r'channel_id\\?"\s*:\s*\\?"([0-9a-fA-F-]{36})', resp_text)
    if not m:
        raise RuntimeError(f"no channel_id in relay response: {resp_text[:300]}")
    return m.group(1)


def ensure_channel():
    global _dm_channel
    with _lock:
        if _dm_channel:
            return _dm_channel
        for attempt in range(1, 4):
            try:
                _dm_channel = open_dm()
                log.info("DM channel ready: %s", _dm_channel)
                return _dm_channel
            except Exception as e:
                log.warning("open_dm attempt %d/3 failed: %s", attempt, e)
                time.sleep(5 * attempt)
        raise RuntimeError("could not open DM channel with owner")


def ensure_joined():
    """Publish a kind:9021 join request for the alert channel (idempotent).

    Works on open channels. On private channels the relay rejects it and
    someone inside must add the bot: buzz channels add-member.
    Not fatal if it fails — open channels accept writes from non-members too.
    """
    global _joined
    with _lock:
        if _joined:
            return
        for attempt in range(1, 4):
            try:
                post_event(nak_sign(9021, "", [f"h={CHANNEL}"]))
                _joined = True
                log.info("joined alert channel %s", CHANNEL)
                return
            except Exception as e:
                log.warning("join attempt %d/3 failed: %s", attempt, e)
                time.sleep(5 * attempt)
        log.warning(
            "could not join %s — if the channel is private, add the bot with "
            "`buzz channels add-member --channel %s --pubkey <bot-pubkey>`",
            CHANNEL, CHANNEL,
        )


def send_alert(text):
    if CHANNEL:
        ensure_joined()
        event = nak_sign(9, text, [f"h={CHANNEL}", f"p={AGENT}"])
    else:
        channel = ensure_channel()
        event = nak_sign(9, text, [f"h={channel}", f"p={OWNER}"])
    post_event(event)


def format_alert(payload):
    """Turn LoggiFly's webhook JSON into a readable message."""
    if isinstance(payload, dict):
        title = payload.get("title") or payload.get("container_name") or "LoggiFly alert"
        body = (
            payload.get("message")
            or payload.get("log_entry")
            or payload.get("body")
        )
        if body:
            text = f"{title}\n\n{body}"
        else:
            text = json.dumps(payload, ensure_ascii=False)
    else:
        text = str(payload)
    if len(text) > MAX_MSG_LEN:
        text = text[:MAX_MSG_LEN] + "… (truncated)"
    return text


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        log.info("http: " + fmt, *args)

    def _reply(self, code, msg):
        data = msg.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            self._reply(200, "ok")
        else:
            self._reply(404, "not found")

    def do_POST(self):
        if TOKEN:
            auth = self.headers.get("Authorization", "")
            if auth != f"Bearer {TOKEN}":
                self._reply(401, "unauthorized")
                return
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            payload = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            payload = raw.decode(errors="replace")

        text = format_alert(payload)
        try:
            send_alert(text)
        except Exception as e:
            log.error("failed to deliver alert: %s", e)
            self._reply(502, f"delivery failed: {e}")
            return
        log.info("alert delivered (%d chars)", len(text))
        self._reply(200, "delivered")


def main():
    if not BOT_KEY:
        log.error("BUZZ_BOT_PRIVATE_KEY is required")
        sys.exit(1)
    if CHANNEL:
        if not AGENT:
            log.error("BUZZ_AGENT_PUBKEY is required when BUZZ_ALERT_CHANNEL is set")
            sys.exit(1)
        # Join the alert channel in the background; don't block startup.
        threading.Thread(target=lambda: ensure_joined(), daemon=True).start()
    elif OWNER:
        if not _dm_channel:
            # Warm up the DM channel in the background; don't block startup.
            threading.Thread(target=lambda: ensure_channel(), daemon=True).start()
    else:
        log.error("set BUZZ_ALERT_CHANNEL + BUZZ_AGENT_PUBKEY, or BUZZ_OWNER_PUBKEY for DM mode")
        sys.exit(1)
    server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    mode = f"channel {CHANNEL}" if CHANNEL else "DM"
    log.info("listening on :%d, relay %s, mode %s", PORT, RELAY, mode)
    server.serve_forever()


if __name__ == "__main__":
    main()
