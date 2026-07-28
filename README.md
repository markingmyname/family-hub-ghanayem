# Family Hub

A shared family calendar, chore chart, to-do list, habit tracker, rewards board, budget, and meal planner — one installable web app for the whole household.

**Live: https://markingmyname.github.io/family-hub-ghanayem/**

That's the one link everyone opens. It's plain HTML, CSS, and JavaScript in a single file — no build step, no dependencies, no server to run.

---

## Install it on a phone, tablet, or desktop

It isn't in any app store, but it installs and runs full-screen like a native app, using the same web standards Apple and Google use for installable apps.

| Device | How |
| --- | --- |
| iPhone / iPad | Open the link in **Safari** (must be Safari), tap **Share** → **Add to Home Screen** → **Add** |
| Android, Windows, macOS, ChromeOS | Open in Chrome or Edge, then use the **Install** icon in the address bar, or **⋮ → Install app** |

Either way you get a home-screen icon that opens with no address bar and no browser chrome.

---

## What's in this repo

| Path | What it is |
| --- | --- |
| [family-hub-app](family-hub-app) | The app itself — `index.html`, `manifest.json`, `sw.js`, icons. This is what gets published. |
| [.github/workflows/pages.yml](.github/workflows/pages.yml) | Publishes `family-hub-app/` to GitHub Pages on every push to `main`. |

## Publishing changes

Edit files in `family-hub-app/`, commit, and push to `main`. The workflow redeploys within a minute or two. There is no second copy to keep in sync.

To republish without changing anything: **Actions** tab → **Deploy Family Hub to GitHub Pages** → **Run workflow**.

### Enabling GitHub Pages (one time)

**Settings → Pages → Build and deployment** → Source → **GitHub Actions**.

Pick **GitHub Actions**, not "Deploy from a branch" — the branch option only serves the repo root or `/docs`, and the app lives in neither.

> **Seeing an old version after a deploy?** The browser caches the app. Hard-refresh (<kbd>Ctrl</kbd>/<kbd>Cmd</kbd>+<kbd>Shift</kbd>+<kbd>R</kbd>), or close and reopen the installed app.

---

## What the app does

**Calendar** — month, week, and day views. Month shows readable event chips rather than dots; day opens with an hour-by-hour "whole day" column followed by per-person columns. Events can be **all-day or given a start and end time**, assigned to **one person, several people, or the whole family**, and set to **repeat** (daily, weekdays, weekly, fortnightly, monthly, yearly) ending after N times or on a date.

**Chores** — one column per person, points awarded on completion.

**To-Dos** — modelled on Apple Reminders: lists in a sidebar, sections within a list, sub-tasks, notes as bullets, due dates, priority, flags, attachments, and Today / Scheduled / Flagged smart views.

**Habits** — a month grid of daily and weekly habits with a productivity chart and streaks.

**Rewards** — every chore, to-do, and habit appears automatically under the person it belongs to, with its point value, alongside the rewards those points buy.

**Budget** and **Meals** — per-person balances, and a weekly meal plan with recipes, pantry, and grocery list.

Finished chores, to-dos, and habits move into a collapsible **Completed** drawer at the foot of each page.

### Settings worth knowing

- **Family sync** — put the same board on every device in the house (see [Where your data lives](#where-your-data-lives))
- **Time format** — 12-hour (default) or 24-hour
- **Second time zone** — show every event in a second zone as well, with a live clock strip
- **Sleep mode** — how long before the screensaver takes over, from 5 minutes to an hour, or only on demand
- **Parental PIN** — required to delete things
- **Family calendar name** — the label for the catch-all calendar

---

## Calendar sync

### Google Calendar — two-way, no backend

**🔄 Sync** on the Calendar tab refreshes immediately. To set it up the first time: **Settings → Open calendar sync → Connect Google**. Google's in-browser sign-in handles security; you approve access.

- **Pull** — reads your Google events into Family Hub
- **Write-back** — adding, editing, or deleting an event here does the same in your real Google calendar
- **Repeating events** are written as one real recurring event, not a pile of copies. Editing or deleting one asks whether you mean *this event* or *the whole series*.

It uses the `calendar.events` scope — the least-privilege option that still allows editing. It cannot touch calendar sharing or account settings.

**One-time setup (~5 minutes):**

1. **Google Cloud Console** → create or select a project
2. **APIs & Services → Library** → enable the **Google Calendar API**
3. **OAuth consent screen** → set it up (External is fine); add yourself as a **Test user** while it's in testing
4. **Credentials → Create credentials → OAuth client ID** → **Web application**
5. Under **Authorized JavaScript origins**, add the origin you host at — for this repo, `https://markingmyname.github.io` (origin only, no path, no trailing slash)
6. Copy the **Client ID** (ends in `.apps.googleusercontent.com`) into the Sync panel → **Connect Google**

> **You never need a client secret.** This is a browser-only app, so every file it serves is public — a secret pasted here would be published, not protected. The sign-in flow used here needs only the Client ID. If the console offers a secret, skip it.

**Choosing which calendar:** the Sync panel's calendar box takes either `primary` (the signed-in person's own calendar) or a shared calendar ID ending in `@group.calendar.google.com`. Find it in Google Calendar → hover the calendar → **⋮ → Settings and sharing → Integrate calendar → Calendar ID**. The app ships pointed at the shared family calendar so everyone lands on the same events. For write-back, each person needs **"Make changes to events"** on that calendar.

**Session note:** browsers don't get long-lived Google refresh tokens, so after about an hour the app needs to sign in again. It does this silently where it can.

### Outlook — two-way, no backend

Microsoft's MSAL.js signs you in from the browser, so the app talks to Microsoft Graph directly.

1. Azure portal → **Microsoft Entra ID → App registrations → New registration**
2. Name it, and under **Supported account types** pick "Accounts in any organizational directory and personal Microsoft accounts" so Outlook.com works
3. **Redirect URI** → platform **Single-page application (SPA)** → the exact page URL (e.g. `https://markingmyname.github.io/family-hub-ghanayem/index.html`). It must match exactly.
4. Register, and copy the **Application (client) ID**
5. **API permissions → Microsoft Graph → Delegated** → add `Calendars.ReadWrite` and `User.Read`
6. In the app: **Sync → Outlook live sync** → paste the Client ID → **Connect Outlook**

Because this uses a popup and a registered redirect URI, it only works on the hosted https URL — not from a local file.

### Import and export (any calendar app)

Google, Outlook, Yahoo, and Cozi all read and write `.ics`, which is the bridge for anything without live sync:

- **Import** — load an `.ics` in the Sync panel; re-importing skips duplicates
- **Export** — download an `.ics` of the whole family or one person

**Yahoo** has no modern API (CalDAV only), so live sync would need a proxy. **Cozi** has no developer API at all — no app can edit a Cozi calendar. Import/export is the ceiling for both.

---

## Where your data lives

Family Hub saves to **each browser's local storage** first. That's what makes it instant and what lets it work with no connection at all.

On its own, though, local storage only covers *that* device. To put the same board on every phone, tablet, and computer, connect a small cloud database — **Settings → Family sync**. It's free, takes about five minutes, and you do it once for the whole house.

### Setting up family sync

1. **Make a free project** at [supabase.com](https://supabase.com/dashboard/projects) — sign in with GitHub, pick any region near you. It asks for a database password you'll never need again.
2. **Paste the project URL and key** into Settings → Family sync. Both sit behind the project's **Connect** button. Paste them together, in either order — the box sorts them out.
3. **Run the setup SQL** — the panel's **Copy SQL** and **Open SQL editor** buttons put you in the right place. Paste, press Run.

Then press **Connect**. To add the next device, press **Copy setup link**, open that link on the phone or tablet, and tap **Join** — no retyping keys.

> Paste the **publishable** (or **anon**) key — the one meant to be public. A **secret** or **service role** key is the admin key and is refused, because every file this app serves is public.

### What syncing does and doesn't do

- **Everything shared syncs** — calendar, chores, to-dos, habits, points, rewards, budget, meals, people, settings.
- **What each screen is looking at stays put.** The day you're on, the list you've opened, the person whose habits you're viewing — those are yours. Otherwise every screen in the house would jump to wherever someone else just tapped.
- **Last change wins.** The whole board is saved as one document, so if two people edit in the same few seconds, the later save is the one kept. Rare in a household, and the alternative is a lot of machinery for a fridge-door app.
- **Offline still works.** Edits save locally and go up when the connection returns; the ☁️ in the header shows what's happening.
- **Free projects pause after a week of inactivity.** Normal use resets that clock. If it does pause, unpause it in the Supabase dashboard and everything is still there.

Prefer to run it on Azure? Azure Database for PostgreSQL can't be reached from a browser directly — Postgres speaks its own protocol over TCP, not HTTP — so it needs an API tier in front of it, such as an Azure Function using a managed identity. That's a good setup, just not a five-minute one.

**Storage limits matter for attachments.** Browser storage is a few megabytes in total. To-do image attachments are downscaled to 1000px and re-encoded as JPEG; other files are capped at 600 KB. That's fine for reference photos, not for a photo library.

---

## Security and reliability

**Security**

- A Content Security Policy restricts where code can load from and where data can be sent
- The parental PIN is stored **hashed (SHA-256)**, not in plain text
- All user-entered text is HTML-escaped before display
- Access tokens live only in the browser session and vanish when the tab closes; the Client IDs are not secrets
- Family sync credentials are stored on each device, never in this repo — and admin-level database keys are rejected outright
- Uploaded images are validated and re-encoded before saving

**Error handling**

- Every file read, image load, save, and sync call surfaces a plain-English message rather than failing silently
- If saved data ever becomes unreadable, the app **backs it up instead of overwriting it**, then starts fresh
- Sync errors are translated into specific guidance (popup blocked, redirect URI mismatch, missing permission, expired session)
