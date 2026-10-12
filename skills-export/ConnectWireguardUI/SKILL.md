---
name: ConnectWireguardUI
description: "Opens an SSH tunnel to the wg-easy WireGuard admin UI on the team VPN box and hands back a http://localhost:51821 URL. ALWAYS tunnel to localhost — never send the user to http://10.8.0.1:51821 or the public IP directly. Use when the user asks to connect to / open / access the WireGuard UI, wg-easy, the VPN admin panel, or to add a WireGuard client or peer."
---

# ConnectWireguardUI

Gets the user into the wg-easy admin UI on the team VPN box (`i-0ad5d9743f6c95721`, `44.225.91.181`) **always via an SSH port-forward to `localhost`**, never by pointing a browser at the box's address directly.

## The rule, and why it is not optional

**Always hand back `http://localhost:51821`.** Never `http://10.8.0.1:51821`, never `http://44.225.91.181:51821`.

Browsing directly to the box appears to work — the page renders and login succeeds — but **creating a client silently fails**. wg-easy v15 generates the WireGuard keypair *in the browser* using the Web Crypto API (`crypto.subtle`), which browsers only expose in a **secure context**: HTTPS, or `localhost`. Over plain HTTP to an IP address, `crypto.subtle` is undefined. The container also runs with `INSECURE=false`.

A tunnel to `localhost` satisfies the secure-context rule without needing TLS. Until nginx terminates TLS in front of port 51821, this is the only working path.

## Steps

1. **Work out whether the user is on the VPN**, because it decides which host alias works:
   ```bash
   curl -s --max-time 10 https://checkip.amazonaws.com
   ```
   - Returns **`44.225.91.181`** → they are **on** the VPN (their exit IP is the box itself). Use `wg-ui-vpn`.
   - Returns anything else → they are **off** the VPN. Use `wg-ui`.

   This matters: the public-IP aliases **cannot work while connected**, because the box cannot hairpin a connection to its own public address. The failure is `Connection timed out`, which looks identical to a firewall block and sends people off editing security groups for no reason.

2. **Check port 51821 is not already bound locally** (a stale tunnel from an earlier session is common):
   ```bash
   netstat -ano | grep -E ":51821\s+.*LISTENING"
   ```
   If something is listening, test it before opening another — `ExitOnForwardFailure yes` is set on both aliases, so a second tunnel will fail loudly rather than silently connect without a forward.

3. **Open the tunnel in the background.** Both aliases are already in `~/.ssh/config` with `SessionType none`, so no shell opens:
   ```bash
   ssh -N wg-ui-vpn      # on the VPN  (10.8.0.1)
   ssh -N wg-ui          # off the VPN (44.225.91.181)
   ```
   Run it with `run_in_background: true`.

4. **Verify the tunnel actually forwards** before telling the user it is ready:
   ```bash
   curl -s -o /dev/null -w "%{http_code}\n" --max-time 10 http://localhost:51821/
   ```
   Expect **302** (redirect to `/login`). A `000` means the tunnel is bound but not forwarding.

5. **Hand back the URL**: `http://localhost:51821`.

## Checks worth doing while the user is in there

- **The generated client config may carry a dead endpoint IP.** wg-easy v15 stores its host in its own database from the setup wizard, and that stored value is the box's **old, released** Elastic IP `44.242.4.12`. The container env has the right value (`WG_HOST=44.225.91.181`) but the stored setting wins. Every generated `.conf` therefore needs `Endpoint` corrected to **`44.225.91.181:51820`** until the stored host is fixed. `44.242.4.12` is no longer allocated to this AWS account at all.
- **`PersistentKeepalive` defaults to 0.** Tell the user to set **25**. With it off, a peer only handshakes while actively passing traffic, which makes handshake age useless as a health signal — that is precisely why a 3–5 day VPN outage went unnoticed in September 2026.
- **Name peers after the person**, not `client-N`.

## Do not

- **Do not generate the client / keypair on the user's behalf.** A WireGuard `PrivateKey` is a credential; creating it here puts it in the session transcript and tool output. The UI generates it in the browser and delivers it by QR straight to the device. Let the user click the button.
- **Do not set `INSECURE=true`** to make direct HTTP access work — it defeats the reason the flag exists.
- **Do not restart or rebind the `wg-easy` container** to "fix" access, especially while the user is connected to the VPN. It drops their tunnel, and if their real public IP is not in `team-vpn-sg`'s port 22 rule they are then locked out entirely.

## Known gotchas

- SSH writes to remote hosts have been blocked before by the auto-mode classifier ("Remote Shell Writes"). Opening a **port-forward** is not a write and has not been blocked. If anything here is refused, hand the exact `ssh -N` command to the user rather than rewording and retrying.
- Tunnels on this box have dropped with `Connection reset by peer`. Both aliases carry `ServerAliveInterval 20` / `ServerAliveCountMax 6` / `TCPKeepAlive yes` for that reason. If one drops mid-session, reopen it rather than assuming the box is down — verify with `ssh vpn-box 'uptime'` first.

## Report back

Give the user the `http://localhost:51821` URL and say which alias was used and why (on or off the VPN). Confirm the **verified** 302 from step 4 rather than reporting success because `ssh` returned without error — a bound-but-dead tunnel is the exact failure this check exists to catch.
