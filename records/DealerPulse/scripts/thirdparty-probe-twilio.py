"""Read-only Twilio connectivity probe - the one that needs Django.

Runs inside the backend container via `manage.py shell`, because the TWILIO_*
values are Fernet-encrypted in the environment and only SecretManager can
decrypt them. Probing os.environ directly returns 401 and looks exactly like an
outage - that false alarm happened once during the 2026-09-18 audit, so this
file exists partly to make the distinction obvious.

Loading Django costs ~4.3s of CPU, which is why this is on a 30-minute timer
while the other five providers run every 5 minutes without it. Credentials do
not rot spontaneously; they break when somebody rotates a key, and half an hour
is a reasonable detection window for that.

Emits:  TWILIO|UP|message|elapsed_ms     Never prints credential material.
"""
import time

import requests

TIMEOUT = 12


def emit(status, msg, ms=0):
    print(f"TWILIO|{status}|{msg}|{ms}")


try:
    from apps.calls.services.twilio import TwilioConfigService
    sid = TwilioConfigService.account_sid()
    tok = TwilioConfigService.auth_token()
except Exception as exc:
    emit("DOWN", f"cannot load credentials: {type(exc).__name__}")
    raise SystemExit(0)

if not sid or not tok:
    emit("DOWN", "account sid or auth token is empty after decryption")
    raise SystemExit(0)

t0 = time.time()
try:
    r = requests.get(f"https://api.twilio.com/2010-04-01/Accounts/{sid}.json",
                     auth=(sid, tok), timeout=TIMEOUT)
except Exception as exc:
    emit("DOWN", f"unreachable: {type(exc).__name__}")
    raise SystemExit(0)

ms = int((time.time() - t0) * 1000)

if 200 <= r.status_code < 300:
    emit("UP", f"HTTP {r.status_code} in {ms}ms", ms)
else:
    try:
        detail = str(r.json().get("message", ""))[:120]
    except Exception:
        detail = r.text[:120].replace("\n", " ")
    detail = f" - {detail}" if detail else ""
    emit("DOWN", f"HTTP {r.status_code}{detail}", ms)
