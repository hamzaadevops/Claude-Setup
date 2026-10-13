"""Read-only connectivity probe - the five providers that need no Django.

Runs inside the backend container via plain `python`, NOT `manage.py shell`.
That distinction is the whole point of this file: loading Django costs ~4.3s of
CPU per run, and on a 2-vCPU box that was a recurring 0.7-core burst every five
minutes, sharing cores with the latency-critical Retell webhook. These five read
plain environment variables and need none of it.

Twilio is deliberately absent - its credentials are Fernet-encrypted and need
SecretManager to decrypt, so it lives in thirdparty-probe-twilio.py and runs on
a slower timer.

Emits one line per provider:  NAME|UP|message|elapsed_ms
Never prints credential material.

-----------------------------------------------------------------------------
NEVER add the XTime write endpoints here:
    /appointments-bookings/dealer/{id}        creates a real appointment
    /appointments-cancellations/dealer/{id}   cancels a real appointment
    reschedule_appointment                    moves a real appointment
These hit a live dealership's DMS.
-----------------------------------------------------------------------------

Verdict rule: only 2xx counts as UP, carrying the provider's own error text
otherwise. A looser rule once scored AssemblyAI's 409 "Your account is
disabled" as healthy.
"""
import os
import time

import requests
from requests.auth import HTTPBasicAuth

TIMEOUT = 12


def env(key, default=""):
    return os.environ.get(key, default)


def emit(name, status, msg, ms=0):
    print(f"{name}|{status}|{msg}|{ms}")


def simple_probe(name, url, headers=None, keyname=None, keyval=None):
    if keyval is not None and not keyval:
        emit(name, "DOWN", f"{keyname} is not set in the environment")
        return
    t0 = time.time()
    try:
        r = requests.get(url, headers=headers or {}, timeout=TIMEOUT)
    except Exception as exc:
        emit(name, "DOWN", f"unreachable: {type(exc).__name__}")
        return
    ms = int((time.time() - t0) * 1000)
    if 200 <= r.status_code < 300:
        emit(name, "UP", f"HTTP {r.status_code} in {ms}ms", ms)
        return
    try:
        body = r.json()
        detail = str(body.get("error") or body.get("message") or "")[:120]
    except Exception:
        detail = r.text[:120].replace("\n", " ")
    detail = f" - {detail}" if detail else ""
    emit(name, "DOWN", f"HTTP {r.status_code}{detail}", ms)


def probe_xtime():
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

    if 200 <= r2.status_code < 300:
        emit("XTIME", "UP", f"auth {auth_ms}ms, services read {api_ms}ms", auth_ms + api_ms)
    else:
        emit("XTIME", "DOWN",
             f"auth OK but services read returned HTTP {r2.status_code}",
             auth_ms + api_ms)


probe_xtime()

simple_probe("WASSENGER",
             env("WASSENGER_API_BASE_URL", "https://api.wassenger.com/v1").rstrip("/") + "/devices",
             headers={"Token": env("WASSENGER_API_KEY")},
             keyname="WASSENGER_API_KEY", keyval=env("WASSENGER_API_KEY"))

# Plaintext in the environment - verified that settings value == raw env value,
# so no Django needed here.
simple_probe("ASSEMBLYAI", "https://api.assemblyai.com/v2/transcript",
             headers={"authorization": env("ASSEMBLY_AI_API_KEY")},
             keyname="ASSEMBLY_AI_API_KEY", keyval=env("ASSEMBLY_AI_API_KEY"))

simple_probe("RETELL",
             env("RETELL_API_BASE_URL", "https://api.retellai.com").rstrip("/") + "/list-agents",
             headers={"Authorization": "Bearer " + env("RETELL_API_KEY")},
             keyname="RETELL_API_KEY", keyval=env("RETELL_API_KEY"))

simple_probe("OPENROUTER",
             env("OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1").rstrip("/") + "/auth/key",
             headers={"Authorization": "Bearer " + env("OPENROUTER_API_KEY")},
             keyname="OPENROUTER_API_KEY", keyval=env("OPENROUTER_API_KEY"))
