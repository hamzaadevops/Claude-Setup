# For Mudassar — two silent production failures

Found 2026-09-22 during a routine sweep. Both verified against the running
system and against `main` at `899c747c`. Neither shows up in any dashboard,
which is why they have run this long.

---

## 1. All staff SMS notifications have been failing since at least 8 September

`settings.TWILIO_FROM_NUMBER` is `+17473374107`. **That number is not on the
Twilio account.** I listed all 13 numbers the account owns and it is not among
them. Every send that falls back to it returns:

```
HTTP 400 - Unable to create record:
'From' +17473374107 is not a Twilio phone number or Short Code country mismatch
```

3,484 failures in the last three days, one single error, still failing at
16:58 UTC today.

### What is and is not affected

**Customer messages are fine.** `sms/appointment_confirmation` and
`sms/bdc_hourly_report` pass an explicit per-dealership `from_number` and go out
normally.

**Staff notifications are not.** Everything that relies on the fallback in
`server/apps/calls/tasks/send_sms_task.py:39`:

```python
sender = from_number or settings.TWILIO_FROM_NUMBER
```

Reading the stored payloads, those are:

- `New Appointment Booking: for: <customer> / Service: <service> / Booking DateTime: <when>`
- `<staff name> has missed a call from a customer — Dealership: Puente Hills Nissan`

**32 distinct staff recipients.** So for roughly two weeks nobody at the
dealerships has been told about a new booking or a missed call. A missed-call
alert that never arrives means nobody calls that customer back.

### Numbers, from `OutboundMessage` (channel=sms), not from logs

| Date | sent | failed |
|---|---|---|
| 8–12 Sep | **0** | ~1,000/day |
| 14–19 Sep | 4–36 | 700–2,300/day |
| 21 Sep | 42 | 2,328 |
| 22 Sep (to 17:00) | 17 | 348 |

The task retries three times at 10s (`max_retries=3, default_retry_delay=10`),
so the ~2,700 rows over the last two days are about 677 real notifications.

### The decision I need from you

Two ways to fix it and I do not want to guess:

1. Point `TWILIO_FROM_NUMBER` at a number the account actually owns, or
2. Send through the Messaging Service `MGb1ff1ae67e06c17775739a7387b53543` using
   `messaging_service_sid` instead of `from_`

I lean towards asking because **that Messaging Service was created on 14
September** — the same day sends went from five consecutive days of zero to
partially succeeding. That looks like a migration that was started and not
finished, but the correlation is all I have.

### Worth fixing at the same time

The task creates an `OutboundMessage` row per attempt, so a single failed
notification writes four rows. That is what makes the failure counts look four
times worse than they are, and it will distort any reporting built on that table.

---

## 2. `transfer_call_status_check` has been dead code since at least 19 September

`server/apps/calls/utils/transfer_call_status_check.py:56`

```python
if disconnection_reason != "call_transfer":
```

`disconnection_reason` is never assigned anywhere in that scope — it is a
`NameError` on **every** invocation. The bare `except Exception` at line 68
catches it and logs at WARNING:

```
[WARNING] apps.calls.utils.transfer_call_status_check:
Error processing transfer call status: name 'disconnection_reason' is not defined
```

Roughly 50 occurrences in 12 hours, continuous since at least 19 September.

Because it throws at line 56, everything after it never runs — so
`SystemFailureService.log_failure` is **never called** and transfer failures are
not being recorded at all.

Every other service reads it off the webhook payload, e.g.
`recovery_service.py:411` and `reminder_service.py:141`, so presumably:

```python
disconnection_reason = (call_data.get("disconnection_reason") or "").lower()
```

Worth also reconsidering the bare `except Exception` — it turned a hard
programming error into a warning nobody reads, which is exactly why this
survived.

---

## Two smaller things, same sweep

**`/api/calls/{id}/get-recording/` returns 502 when a recording is not ready.**
`RecordingDownloadFailed` is declared as HTTP 502 in
`server/apps/calls/exceptions.py:11`, and it fires whenever Twilio has not
finished encoding — often, because agents hit play as soon as a call ends. The
frontend's TanStack Query then retries three times by default, so one click
writes four 502s. About 12% of playback attempts fail this way; nothing is
permanently lost, the recording works once encoding completes. A 202 or 409 with
a "still processing" status would let the UI poll instead of showing an error.

In the same function, `get_latest_call_recording` calls Twilio's list API twice
per request (once unlimited, once `limit=1`), and there is a stray
`print(len(recordings_list))` in production.

**Two endpoints returning Forbidden repeatedly** — `/api/companies/users/` (73 in
12h) and `/api/appointments/service/booking-dashboard-stats/` (66 in 12h). Could
be legitimate permission denials or a broken role in the UI. Can you confirm
which?
