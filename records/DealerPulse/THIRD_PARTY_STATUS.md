# DealerPulse — third-party integration status

Audited **2026-09-18** by probing each provider from inside the backend
container, using the same credentials and code paths the application uses.
Every line below is a measured HTTP response, not an inference.

**Three of six are broken. All three fail silently.**

---

## Summary

| Service | Status | Evidence | Customer impact |
|---|---|---|---|
| **Twilio** | ✅ healthy | `200` in 101ms | — |
| **Wassenger** (WhatsApp) | ✅ healthy | `200` in 118ms | — |
| **XTime / Cox** | ✅ healthy | auth 652ms, services read 621ms | — |
| **AssemblyAI** | ❌ **broken** | `401 {"error":"API key is disabled"}` | No call transcripts |
| **Retell** | ❌ **key missing** | `RETELL_API_KEY` not in environment | No outbound calls |
| **OpenRouter** | ❌ **key missing** | `OPENROUTER_API_KEY` not in environment | No call analysis |

---

## The three that are broken

### AssemblyAI — the account is disabled

```
POST https://api.assemblyai.com/v2/upload
401 {"error":"API key is disabled"}

GET  https://api.assemblyai.com/v2/transcript
409 {"error":"Your account is disabled. Please contact us at
              support@assemblyai.com for more information."}
```

This is **not** a key that needs reissuing — the whole AssemblyAI account is
disabled, and their own message says to contact their support. In practice that
almost always means a billing failure or a policy action. Reissuing a key will
not fix it.

Scale of it, from the worker log over 24 hours:

- **816** rejected requests
- **149** distinct calls with no transcript
- **957** retry errors, each burning worker capacity on a doomed task

This has been failing continuously and nothing reported it.

**Action:** someone with AssemblyAI dashboard access needs to check account and
billing status, then re-enable or reissue the key.

### Retell — no API key, and confirmation calls are failing in a loop

`RETELL_API_KEY` is absent from the container environment.

Inbound is unaffected — Retell calls our webhooks and needs no key from us. What
breaks is **outbound**, and it is not theoretical:

```
ValueError: RETELL_API_KEY is not configured
  File "/app/server/apps/calls/services/retell_service.py", line 103,
       in create_phone_call
Task apps.appointments.tasks.place_confirmation_call_task[...]
     retry: Retry in 120s: ValueError('RETELL_API_KEY is not configured')
```

**75 failures in 24 hours**, retrying every 120 seconds. `place_confirmation_call_task`
is the task that rings a customer to confirm their appointment. It has not
placed a single call.

### OpenRouter — in use despite being described as unused

On 2026-09-18 the backend team stated OpenRouter is *"temporarily down… we are
not using OpenRouter temporarily… if the client asks for it, we are gonna use
it."* **The running system disagrees**, and this is worth resolving rather than
assuming either side is right:

```
[ERROR] apps.calls.tasks.notify_unbooked_booking_intent:
        [BookingFollowup] OPENROUTER_API_KEY is not configured; skipping call 39862
```

**96 distinct calls skipped in 24 hours.** The task is
`notify_unbooked_booking_intent` — follow-up for callers who did not book. Every
one of those 96 is a customer who rang, did not book an appointment, and then
received no follow-up.

Two readings, and only the backend team can say which is right: the feature was
switched on without anyone realising it needs OpenRouter, or it is meant to be
running and nobody knew it had stopped. Either way it is failing silently today.

---

## The three that are healthy

**Twilio** returns `200`. Worth recording how this was verified, because the
first attempt produced a false alarm: `TWILIO_*` values are stored
**Fernet-encrypted** in the environment and decrypted at runtime by
`SecretManager`. Probing the raw environment variable returns `401`. Only the
decrypted credential is valid — so any future check of Twilio must go through
`TwilioConfigService`, not `os.environ`.

**Wassenger** returns `200` in 118ms against `/devices`.

**XTime / Cox** is monitored continuously by `check-thirdparty.sh` every five
minutes — OAuth token plus a `services/dealer/{id}` read. Baseline is roughly
180–660ms for auth and 340–640ms for the read.

---

## Still unexplained

`GET /api/calls/<id>/get-recording/` returns **502** — around 55 occurrences on
2026-09-17, continuing. The application raises this when a recording download
from Twilio returns anything other than 200.

**Twilio credentials are now ruled out** as the cause: they authenticate
correctly. The remaining candidates are recordings that have not finished
processing on Twilio's side when the dashboard requests them, or recordings that
no longer exist. Worth a look, but it is not a credential problem.

---

## Note on the encryption split

Only the four `TWILIO_*` values pass through `SecretManager`. Every other
provider's key — AssemblyAI, Retell, OpenRouter, Wassenger, XTime — is read
straight from settings in plaintext. That inconsistency is worth raising with
the backend team: either the encryption is worth applying to all of them, or it
is not worth applying to any, but the current split means nobody can tell by
looking whether a given key is encrypted.
