# Project Brief: Teams Video-Sharing Capacity

Read this whole file before doing anything. Do not change any file until I approve a plan.

---

## 1. Rules for this session (most important)

1. **Explain and plan first. Change nothing** until I approve each step.
2. **Work only on the TEST VPS** (`vps-k9rxt`). Never touch production.
3. **Never open, print, or copy secrets:** `.env`, `cookies/`, any credential or TOTP files, or `scripts/*credentials*`. If you need a config value, ask me.
4. Before any change: confirm a backup exists and the folder is under Git.
5. Make one change at a time, explain it, then tell me how to test and measure it.
6. Prefer read-only commands while investigating.

---

## 2. What the app does

- NestJS (Node.js) backend called **"TPlus Auto Prepare"**, located at `/home/desktop/Web-App`.
- It logs teachers into Microsoft / the **Madrasati** platform (supports SMS, authenticator TOTP, or no MFA) and keeps per-user SDK sessions.
- **Video-sharing feature** (`POST /api/teams`, `openMeet`):
  1. Takes a Teams meeting URL and a YouTube video URL.
  2. Launches a **separate, non-headless Chrome for Testing 147** per teacher via `puppeteer-extra` with the stealth plugin.
  3. Injects the teacher's cookies, opens Teams, clicks "Continue in browser", and uses **xdotool** to dismiss an external-app prompt (protected by a global lock file `/tmp/teams-x11-dialog-<uid>.lock`).
  4. Finds the lecture in the Teams Calendar, configures meeting options, and joins.
  5. Opens the video at **`www.yout-ube.com`** (a third-party YouTube mirror), with autoplay and loop, fullscreen.
  6. Auto-shares that tab using `--auto-select-tab-capture-source-by-title=YouTube`, then disables meeting audio.
  7. `playUntilLectureEnds(page, videoPage, body.endDate)` closes the browser at the lecture end time.
- Main file: `dist/src/mod/api/teams/teams.service.js`. Also see `teams-browser-diagnostics.js` (saves screenshots at each step into `resources/teams-runtime/`).

### Important facts about the codebase

- **Only compiled JavaScript (`dist/`) exists on the server.** There is no TypeScript `src/` folder, no Git history, and the `.map` files don't contain the original source. The original developer has left the company.
- There is also a `dist copy/` folder (an older build), plus `AGENTS.md`, `TODO.md`, and `opencode.json` left by the previous developer. Read `AGENTS.md` and `TODO.md` for context.
- The app runs manually as user `desktop`: `node /home/desktop/Web-App/dist/src/main.js` (no systemd service, no pm2).
- MongoDB and Redis run in Docker containers.

### Chrome launch flags (observed)

Puppeteer defaults (already include `--disable-backgrounding-occluded-windows`, `--disable-renderer-backgrounding`, `--disable-background-timer-throttling`, `--disable-dev-shm-usage`) plus:
`--enable-usermedia-screen-capturing --use-fake-device-for-media-stream --auto-select-tab-capture-source-by-title=YouTube --autoplay-policy=no-user-gesture-required --no-sandbox --disable-blink-features=AutomationControlled`

### Display setup (observed)

- All browsers share **one Xorg display `:10`** from an **xrdp** remote-desktop session, with the **xfwm4 (XFCE)** window manager.
- `XDG_SESSION_TYPE=x11`. **No GPU**, so everything is rendered and encoded in software.

---

## 3. The problem

- On **production**, about **10 teachers** sharing at the same time works. More than that, and the server **hangs or freezes**.
- **Hard constraints:**
  - The server **must** do the screen share through Microsoft Teams (students can't just get a link).
  - **No admin control over Teams**, so no Teams apps, Graph media bots, or Live Share SDK. The server joins only as a normal participant through the browser.
  - **Limited budget:** fix the software before buying hardware.

---

## 4. Servers

| | Test VPS (`vps-k9rxt`) | Production VPS |
|---|---|---|
| CPU | 4 vCPU (AMD Ryzen 9 7950X3D) | 24 vCPU |
| RAM | ~10 GB, **no swap** | 96 GB |
| GPU | None | Probably none |
| OS | Ubuntu 24.04.5 | ? |

### Measured on test VPS

- One session: about **0.75 CPU core** (can spike while joining or sharing) and about **1.2–1.6 GB RAM**. The operator confirms RAM per instance is steady at 1.2–1.6 GB, while CPU varies: the first instance costs more and later ones less.
- Expected test VPS capacity: about **3–5 concurrent teachers** (CPU runs out first).
- `/dev/shm` is fine (5.8 GB, empty). No OOM kills in the last 7 days. No leftover browsers.
- The app's open-file limit is 524,288 with only ~48 in use, so **the file limit is NOT the problem**.
- Note: 4 lines were appended to `/etc/security/limits.conf` (nofile 65535). Harmless; can be removed if wanted.

### Key insight

At ~1.5 GB RAM and ~1–2 cores per session, production (24 cores / 96 GB) should handle **~20–30 sessions** on paper, yet it freezes at ~10. So the bottleneck is **probably not raw CPU or RAM**. It needs to be measured on production during a busy period.

---

## 5. Suspected bottlenecks (to verify, in rough priority)

1. **One shared Xorg/xrdp display with no GPU**, where every browser draws a fullscreen video in software through a single Xorg process.
2. **A full Teams web client plus screen-share encoding per teacher**, all on the CPU.
3. **A fake camera stream** (`--use-fake-device-for-media-stream`) possibly being encoded if Teams turns the camera on. Check that the camera stays off.
4. **The global xdotool lock** serializing concurrent session starts.
5. **VPS CPU steal** (shared cores) on production.
6. **Outbound bandwidth** with many live video streams.
7. **A bottleneck in the single Node process** managing all browsers.
8. **The `yout-ube.com` mirror** being slow, unreliable, or changing.
9. **Browser cleanup:** if `endDate` is wrong or an error happens, browsers may never close.
10. **Diagnostics screenshots** at every step add CPU and disk load (folder already 24 MB on test).

Already ruled out: file-descriptor limits, `/dev/shm` size, occluded-window throttling (flags already disable it), snap Chromium (it uses Chrome for Testing).

---

## 6. Monitoring

A logger script `~/monitor.sh` (as root) records every 10 seconds into `~/monitor.log`: load, CPU line (including `st` steal), memory, `/dev/shm`, Chrome process count, network counters, and the top processes.

- View: `tail -300 ~/monitor.log`
- Stop: `pkill -f monitor.sh`
- **To do:** run the same logger on production during a busy period and analyze it.

---

## 7. Improvement ideas (evaluate; implement only after approval)

### Quick wins (free)

1. **Separate display per session** (e.g. one Xvfb per browser) instead of all sessions sharing the xrdp desktop. Or test whether headless mode plus tab capture works with Teams.
2. **Lower the cost per session:** no fullscreen, a smaller window, lower video resolution (480p/720p), and share around 15 fps if controllable.
3. **Keep the camera off** and mic processing / noise suppression off in Teams.
4. **Remove or narrow the global xdotool lock** once each session has its own display.
5. **Guaranteed cleanup:** always close the browser on error or timeout, plus a watchdog that kills browsers past their `endDate`.
6. **Reduce or disable diagnostics screenshots** in production, and rotate old ones.
7. **Concurrency limit** so the server never accepts more sessions than it can handle (queue the rest).

### Medium-term

8. **Uploaded videos instead of the mirror site:** teachers upload, ffmpeg converts once to 720p/480p H.264, and a minimal local HTML player plays it. Expected CPU gain is only moderate (~20–30%) because Teams and the encoding remain, but it's much more reliable and avoids the third-party mirror.

### Scaling: queue-based load balancing across VPSes

- A normal HTTP load balancer won't work well, because `openMeet` returns immediately while the browser runs for the whole lecture.
- Use **BullMQ on the existing Redis**:
  - The API **enqueues** `openMeet` jobs instead of launching Chrome directly.
  - Each VPS runs the app in **worker mode** with a **per-server concurrency limit** (e.g. 4 on test, 20 on prod), and pulls jobs only when it has capacity.
  - Job = launch Chrome, join Teams, share video, finish at `endDate`, guaranteed cleanup.
  - Add retries, worker heartbeats, and a status endpoint (active sessions per server).
  - Workers need access to the shared Redis/MongoDB and the same encryption key, over a private network or password + firewall.

---

## 8. Security issues to address

- **MongoDB (27017) and Redis (6379) are published on `0.0.0.0`** in Docker, so they may be reachable from the internet. Check `ufw status` and the provider firewall. Restrict them before adding remote workers.
- The app stores teachers' Microsoft logins and TOTP secrets and automates their accounts with a stealth plugin. Keep secrets encrypted and out of logs and Git.
- The `yout-ube.com` mirror is a third-party dependency and a risk.

---

## 9. Options ruled out (for reference)

- **Teams media bot (Graph Communications API):** needs Teams admin consent, Windows Server in Azure for production, C#/.NET, and library updates every 3 months; ~1–2 video sessions per core. Too costly and needs admin access we don't have.
- **Live Share / Teams app / BigBlueButton / Jitsi:** not allowed by the constraints.
- **Hardware:** don't buy until production is measured. If needed later, look for 32–64+ cores (e.g. dual Xeon Gold 6248/Platinum 8280, or Threadripper PRO 3995WX/5995WX) and 128–256 GB RAM. 8-core machines (e.g. ThinkStation P520 with W-2145) are a downgrade from the 24-core VPS.

---

## 10. What I want from you, in order

1. Read `AGENTS.md`, `TODO.md`, `package.json`, and the Teams module files in `dist/src/mod/api/teams/`. Explain the full flow in plain language, including how `continueMeetOnBrowser`, `joinLecture`, `shareVideoTab`, `disableMeetingAudio`, and `playUntilLectureEnds` work.
2. List every place that could make CPU/RAM grow with more sessions, and every way a browser could fail to close.
3. Check whether the Teams camera stays off with the fake device.
4. Propose how to recover maintainable source (e.g. turn `dist/` back into a clean, editable project under Git).
5. Give a **step-by-step plan**, ordered by biggest gain for least effort, with how to measure each step (sessions before freezing, CPU, steal, RAM, network).
6. Wait for my approval before making any change.