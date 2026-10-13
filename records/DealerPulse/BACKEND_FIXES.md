# DealerPulse — backend fixes for the next release

Compiled 2026-09-18 from the 16/17 September outage investigation and a
production audit, extended 2026-09-22. Every item was verified against the
running system or against `main` at `899c747c`, with file and line references.

Ordered by impact. **P0 is broken in production today.** P1 is the difference
between a three-hour outage and thirty seconds of errors.

---

## P0 — Broken in production right now

Added 2026-09-22 from a routine sweep. All three were running silently; none
appears on any dashboard. Full detail and the questions for the backend team are
in `SMS_ISSUE_MUDASSAR.md`.

### 0a. All staff SMS notifications fail — `TWILIO_FROM_NUMBER` is not on the account

`settings.TWILIO_FROM_NUMBER = '+17473374107'`, used as the fallback sender in
`server/apps/calls/tasks/send_sms_task.py:39`:

```python
sender = from_number or settings.TWILIO_FROM_NUMBER
```

That number is not one of the 13 the Twilio account owns — verified against the
API. Every send falling back to it returns `HTTP 400 'From' ... is not a Twilio
phone number`. **3,484 failures in three days**, ongoing.

Customer messages are unaffected: `sms/appointment_confirmation` and
`sms/bdc_hourly_report` pass an explicit per-dealership `from_number`. What
fails is the staff notifications — new-booking alerts and missed-call alerts —
to **32 distinct recipients**, since at least 8 September.

From `OutboundMessage` (channel=sms): 8–12 Sep had **zero** successes against
~1,000 failures a day; 21 Sep was 42 sent against 2,328 failed.

Fix is either a valid number or the Messaging Service
`MGb1ff1ae67e06c17775739a7387b53543` created 14 September — the backend team
needs to say which. Also worth noting the task writes one `OutboundMessage` row
per retry attempt, inflating every count in that table by 4×.

**This is also a monitoring gap on our side**, not only a backend bug: the Kuma
Twilio monitor checks that the Account endpoint returns 2xx, which it does.
Valid credentials are not the same as messages being delivered. See MONITORING.md.

### 0b. `transfer_call_status_check` throws on every call, silently

`server/apps/calls/utils/transfer_call_status_check.py:56` references
`disconnection_reason`, which is never assigned in that scope — a `NameError`
every time. The bare `except Exception` at line 68 downgrades it to a WARNING,
so it has run unnoticed since at least 19 September (~50 per 12h).

Everything after line 56 is unreachable, so `SystemFailureService.log_failure`
never runs and **transfer failures are not recorded at all**.

Other services read it as `call_data.get("disconnection_reason")`.

### 0c. `get-recording` returns 502 for a recording that is merely not ready yet

`RecordingDownloadFailed` is declared as HTTP 502 in
`server/apps/calls/exceptions.py:11` and fires whenever Twilio has not finished
encoding — common, because agents play calls the moment they end. The frontend
(`use-get-call-recording.ts`, TanStack Query with stock `retry: 3`) then retries
three times, so one click writes four 502s.

~12% of playback attempts fail; nothing is permanently lost. Should be a 202 or
409 with a "processing" status so the UI can poll. Same function calls Twilio's
list API twice per request and contains a stray `print()`.

---

## P1 — Prevents another outage

### 1. No time limit on database operations

`server/coresite/settings/database.py:38`

```python
'OPTIONS': {
    'sslmode': env('SSL_MODE', default='require'),
},
```

**Nothing in the stack bounds a database wait.** No `statement_timeout`, no
`lock_timeout`, no `connect_timeout`, no TCP keepalives, and no connection
pooling. On 16 September the backend blocked on database connections that had
gone silent; threads climbed from 12 to 142 and the service stopped answering
for three hours while CPU sat at 8%. The only timeout in the entire request path
was the operating system's **two-hour** TCP keepalive default — and the outage
lasted about that long.

Suggested:

```python
'CONN_MAX_AGE': 60,
'OPTIONS': {
    'sslmode': env('SSL_MODE', default='require'),
    'connect_timeout': 5,
    'options': '-c statement_timeout=25000 -c lock_timeout=5000',
    'keepalives': 1,
    'keepalives_idle': 30,
    'keepalives_interval': 10,
    'keepalives_count': 3,
},
```

A stuck query then fails in 25 seconds instead of holding a worker forever, and
a dead connection is detected in about a minute instead of two hours.

### 2. Outbound call with no timeout, on the web request path

`server/apps/calls/services/recording_service.py:23`

```python
response = requests.get(url, auth=(self.account_sid, self.auth_token), stream=True)
```

The only `requests` call in the codebase without a timeout — every other one is
covered. It runs inside the `get-recording` view, so if Twilio accepts the
connection and then stops responding, that Django thread is held indefinitely.
Same failure mode as item 1, in a second place.

```python
response = requests.get(url, auth=(...), stream=True, timeout=(5, 30))
```

### 3. Unbounded concurrency

Every view in the application is synchronous, and Django gives each request its
own thread context, so **thread count equals concurrent unfinished requests**.
There is no ceiling, so the process accumulates load rather than shedding it —
which is how 142 stuck requests took the whole service down.

Worth setting an explicit worker/thread limit so excess requests are rejected
quickly instead of queuing forever.

### 4. `ATOMIC_REQUESTS: True` combined with synchronous third-party calls

`server/coresite/settings/database.py:37`

Every request runs in a transaction. Booking paths call XTime synchronously
inside the request, so a slow XTime holds an open database transaction for its
full duration. Those two failure domains should not be tied together — consider
disabling `ATOMIC_REQUESTS` on the webhook and booking views and managing
transactions explicitly around the database work only.

---

## P2 — Silent failures

### 5. `RETELL_API_KEY` missing in production

`place_confirmation_call_task` raises `ValueError: RETELL_API_KEY is not
configured` and retries every 120 seconds — **75 failures in 24 hours**.
Appointment confirmation calls are not being placed at all.
(Already acknowledged — listed for completeness.)

### 6. Decommissioned services are disabled by removing keys, not by disabling code

AssemblyAI and OpenRouter were switched off last month by removing their
credentials. The scheduled tasks still dispatch, still call out, and still fail:

| Service | Observed in 24h |
|---|---|
| AssemblyAI | 816 requests, all `401`; 957 retry errors; `process_call_transcript_summary` ran 1,773 times |
| OpenRouter | `notify_unbooked_booking_intent` ran and skipped **96 distinct calls** |

Three costs: retry loops consume worker capacity on a two-core box, the error
volume buries real problems in the logs, and monitoring cannot distinguish
"deliberately off" from "actually broken".

Suggested: remove the entries from `CELERY_BEAT_SCHEDULE`
(`server/coresite/settings/celery.py:18`) or gate the tasks behind a feature
flag, so nothing dispatches.

### 7. The application logs no exceptions

During the entire three-hour outage the backend recorded **zero tracebacks**.
Daphne logs request lines and nothing else, so there was no application-side
evidence of why requests were blocking. Structured error logging on the request
path would have shortened the investigation from days to minutes.

---

## P3 — Deployment and operational safety

All in `docker-compose.yml`.

### 8. `worker` and `beat` have no restart policy

`x-web-common` sets `restart: unless-stopped`; `x-all-commom`, which `worker`
and `beat` inherit, does not. If either dies it stays dead, nothing restarts it,
and the site stays green while confirmations, reminders, recovery calls and the
hourly BDC report all stop.

### 9. `worker` and `beat` have no health check

A wedged Celery process stays `Running: true` indefinitely. Docker cannot see it
and neither can we. (We have worked around this with an external check, but a
container-level health check is the right home for it.)

### 10. `beat` runs with the single-instance lock disabled

```yaml
command: celery -A coresite beat -l info --pidfile=
```

The empty `--pidfile=` disables Celery's single-instance protection. If `beat`
ever runs twice, every scheduled job fires twice — duplicate customer texts and
duplicate outbound calls. This becomes a live risk the moment a second host is
added.

### 11. Both web colours run migrations on start

`RUN_MIGRATIONS: "1"` on `x-web-common`. The pipeline serialises colours today
so they cannot race, but the new colour runs `migrate` **while the old colour is
still serving traffic** — so any non-backward-compatible schema change breaks
the running version for the length of the deploy. Moving migrations to a
separate one-shot step with `RUN_MIGRATIONS: "0"` on the web services removes
both the race and that window.

### 12. `/health/ready/` only proves the database is reachable

It opens a Postgres connection and nothing else — not Redis, not Celery, not
whether any real request can be served. A container that reaches the database
but is otherwise broken reports healthy and takes traffic. Worth extending to
Redis at minimum, since Redis is both the channel layer and the Celery broker.

---

## P4 — Security

### 13. `SECURE_PROXY_SSL_HEADER` is not set

Verified absent from `server/coresite/settings/`. **nginx already sends
`X-Forwarded-Proto`** on both `/` and `/ws/`, so nothing is blocked on our side
— Django simply ignores it and believes every request arrived over plain HTTP.

```python
SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')
```

This is a prerequisite for item 14.

### 14. Webhook signature verification is not implemented

Five webhook endpoints accept unauthenticated POSTs. A forged Twilio `STOP` can
silence a dealership's outreach. Twilio's signature is computed over the full
`https://` URL, which is why item 13 must land first.

Worth noting the pattern already exists in this codebase —
`WASSENGER_WEBHOOK_TOKEN` and `WASSENGER_WEBHOOK_SIGNATURE_HEADER` are wired up
— so this is extending something familiar rather than building it new.

### 15. The application connects to the database as `doadmin`

The managed cluster's superuser, against `defaultdb`, with no dedicated role or
database. Any SQL injection or leaked `.env` is full cluster compromise rather
than one application's data. A least-privilege role and a named database is a
migration-friendly change.

### 16. Inconsistent credential handling

Only the four `TWILIO_*` values pass through `SecretManager` and are stored
Fernet-encrypted. AssemblyAI, Retell, OpenRouter, Wassenger and XTime keys are
read straight from settings in plaintext. Nobody can tell by looking which is
which — this briefly produced a false "Twilio is down" during the audit, because
probing the raw environment variable returns `401`.

Either apply it consistently or drop it, but the split is a trap.

---

## P5 — Minor

### 17. `BACKEND_URL` is not set

The application logs `Using default BACKEND_URL https://app.backend.dealerpulse.cloud`
on every start. The fallback happens to be correct, so nothing is broken — but
it should be explicit rather than accidental.

---

## Not in scope for the backend team

Handled on the infrastructure side, listed so nothing is done twice:
nginx upload limit and read timeout, log shipping off the host, monitoring and
alerting, the database firewall (Trusted Sources), and the journal size cap.
