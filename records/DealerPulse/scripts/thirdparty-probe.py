"""Read-only connectivity probe for every third-party integration.

Runs INSIDE the backend container via `manage.py shell`, so credentials never
leave it and Django-level decryption is available. Emits one line per provider:

    NAME|UP|message|elapsed_ms

Never prints credential material.

-----------------------------------------------------------------------------
NEVER add the XTime write endpoints here:
    /appointments-bookings/dealer/{id}        creates a real appointment
    /appointments-cancellations/dealer/{id}   cancels a real appointment
    reschedule_appointment                    moves a real appointment
These hit a live dealership's DMS.
-----------------------------------------------------------------------------

Verdict rule: only 2xx counts as UP. Everything else is DOWN, carrying the
provider's own error text.

An earlier, looser rule treated anything that was not 401/403 as UP, on the
reasoning that we had got past authentication. AssemblyAI proved that wrong: it
returns **409** with `{"error": "Your account is disabled..."}`, which the loose
rule scored as healthy while transcription had been dead for days. Each path
below has been verified to return 2xx when the integration is genuinely working.
"""
import os
import time

import requests
from django.conf import settings

TIMEOUT = 12


def env(key, default=""):
    return os.environ.get(key, default)


def emit(name, status, msg, ms=0):
    print(f"{name}|{status}|{msg}|{ms}")


def simple_probe(name, url, headers=None, auth=None, keyname=None, keyval=None,
                 method="GET"):
    if keyval is not None and not keyval:
        emit(name, "DOWN", f"{keyname} is not set in the environment")
        return
    t0 = time.time()
    try:
        r = requests.request(method, url, headers=headers or {}, auth=auth,
                             timeout=TIMEOUT)
    except Exception as exc:
        emit(name, "DOWN", f"unreachable: {type(exc).__name__}")
        return
    ms = int((time.time() - t0) * 1000)
    if 200 <= r.status_code < 300:
        emit(name, "UP", f"HTTP {r.status_code} in {ms}ms", ms)
        return
    # Carry the provider's own wording - it is usually far more useful than the
    # status code. AssemblyAI's 409 says "Your account is disabled", which is
    # the difference between a five-minute fix and a support ticket.
    detail = ""
    try:
        body = r.json()
        detail = str(body.get("error") or body.get("message") or "")[:120]
    except Exception:
        detail = r.text[:120].replace("\n", " ")
    detail = f" - {detail}" if detail else ""
    emit(name, "DOWN", f"HTTP {r.status_code}{detail}", ms)


# --- XTime / Cox: two stages, auth then a read ------------------------------
def probe_xtime():
    from requests.auth import HTTPBasicAuth

    base = env("COXAUTO_API_BASE_URL", "").rstrip("/")
    cid, secret = env("XTIME_CLIENT_ID"), env("XTIME_CLIENT_SECRET")
    apikey, scopes = env("XTIME_API_KEY"), env("XTIME_SCOPES")
    dealer = env("XTIME_DEALER_ID")

    for n, v in (("XTIME_CLIENT_ID", cid), ("XTIME_CLIENT_SECRET", secret),
                 ("XTIME_API_KEY", apikey), ("COXAUTO_API_BASE_URL", base)):
        if not v:
            emit("XTIME", "DOWN", f"{n} is not set")
            return

    t0 = time.time()
    try:
        r = requests.post(
            "https://auth.coxautoinc.com/token",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            data={"grant_type": "client_credentials", "scope": scopes},
            auth=HTTPBasicAuth(cid, secret), timeout=TIMEOUT)
    except Exception as exc:
        emit("XTIME", "DOWN", f"auth unreachable: {type(exc).__name__}")
        return
    auth_ms = int((time.time() - t0) * 1000)

    if r.status_code == 401:
        emit("XTIME", "DOWN", "auth rejected our credentials (401)", auth_ms)
        return
    if r.status_code != 200:
        emit("XTIME", "DOWN", f"auth returned HTTP {r.status_code}", auth_ms)
        return
    try:
        token = r.json()["access_token"]
    except Exception:
        emit("XTIME", "DOWN", "auth returned 200 but no access_token", auth_ms)
        return

    if not dealer:
        emit("XTIME", "UP", f"auth OK in {auth_ms}ms (no dealer id, read skipped)", auth_ms)
        return

    t1 = time.time()
    try:
        r2 = requests.post(
            f"{base}/services/dealer/{dealer}",
            headers={"Authorization": f"Bearer {token}", "x-api-key": apikey,
                     "Content-Type": "application/json"},
            json={"vehicle": {"year": 2020, "make": "Nissan", "model": "Altima"}},
            timeout=TIMEOUT)
    except Exception as exc:
        emit("XTIME", "DOWN", f"auth OK but API unreachable: {type(exc).__name__}", auth_ms)
        return
    api_ms = int((time.time() - t1) * 1000)

    if r2.status_code in (401, 403):
        emit("XTIME", "DOWN", f"auth OK but services read rejected ({r2.status_code})",
             auth_ms + api_ms)
    elif r2.status_code != 200:
        emit("XTIME", "DOWN", f"auth OK but services read returned HTTP {r2.status_code}",
             auth_ms + api_ms)
    else:
        emit("XTIME", "UP", f"auth {auth_ms}ms, services read {api_ms}ms", auth_ms + api_ms)


# --- Twilio: MUST use the decrypted credential ------------------------------
# TWILIO_* are stored Fernet-encrypted. Probing os.environ directly returns 401
# and looks like an outage. Always go through TwilioConfigService.
def probe_twilio():
    try:
        from apps.calls.services.twilio import TwilioConfigService
        sid = TwilioConfigService.account_sid()
        tok = TwilioConfigService.auth_token()
    except Exception as exc:
        emit("TWILIO", "DOWN", f"cannot load credentials: {type(exc).__name__}")
        return
    if not sid or not tok:
        emit("TWILIO", "DOWN", "account sid or auth token is empty")
        return
    simple_probe("TWILIO", f"https://api.twilio.com/2010-04-01/Accounts/{sid}.json",
                 auth=(sid, tok))


probe_xtime()
probe_twilio()

simple_probe("WASSENGER",
             env("WASSENGER_API_BASE_URL", "https://api.wassenger.com/v1").rstrip("/") + "/devices",
             headers={"Token": env("WASSENGER_API_KEY")},
             keyname="WASSENGER_API_KEY", keyval=env("WASSENGER_API_KEY"))

simple_probe("ASSEMBLYAI", "https://api.assemblyai.com/v2/transcript",
             headers={"authorization": getattr(settings, "ASSEMBLY_AI_API_KEY", "")},
             keyname="ASSEMBLY_AI_API_KEY",
             keyval=getattr(settings, "ASSEMBLY_AI_API_KEY", ""))

simple_probe("RETELL",
             env("RETELL_API_BASE_URL", "https://api.retellai.com").rstrip("/") + "/list-agents",
             headers={"Authorization": "Bearer " + env("RETELL_API_KEY")},
             keyname="RETELL_API_KEY", keyval=env("RETELL_API_KEY"))

simple_probe("OPENROUTER",
             env("OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1").rstrip("/") + "/auth/key",
             headers={"Authorization": "Bearer " + env("OPENROUTER_API_KEY")},
             keyname="OPENROUTER_API_KEY", keyval=env("OPENROUTER_API_KEY"))
