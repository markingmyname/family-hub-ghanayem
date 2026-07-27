# Family Hub — getting it running full-screen on your own devices

This folder is a small, self-contained web app: `index.html`, `manifest.json`, `sw.js`, and two icons. No Xcode, no App Store — but it installs and opens full-screen like a real app on iPhone, iPad, Android, and desktop, because it uses the same web standards Apple and Google use for "installable" web apps (Apple calls its part of this "Web App" mode; Google calls the overall standard a Progressive Web App / PWA).

## Step 1 — Put it somewhere with a real web address

Right now these files just sit on your computer. Phones need an actual `https://` address to install from. Easiest free options, no coding required:

**Netlify (fastest — drag and drop):**
1. Go to app.netlify.com and create a free account.
2. On the dashboard, drag this whole folder onto the page where it says "drag and drop your site."
3. Netlify gives you a URL like `https://your-site-name.netlify.app`. That's your app's permanent home.

**GitHub Pages (also free, a bit more setup):**
1. Create a new GitHub repository.
2. Upload these files into it.
3. In the repo's Settings → Pages, set the source to your main branch.
4. GitHub gives you a URL like `https://yourname.github.io/repo-name`.

Either way, you'll end up with one link. That's the link every family member uses.

## Step 2 — Install it on iPhone/iPad

1. Open your new link in **Safari** (has to be Safari, not Chrome, for this part on iOS).
2. Tap the **Share** icon (square with an arrow).
3. Tap **Add to Home Screen**.
4. Tap **Add**.

You'll get a real icon on the home screen. Tapping it opens the app with no Safari address bar, no browser chrome — full screen, just like a native app. This is already wired up in `index.html` via Apple's web-app meta tags.

## Step 3 — Install it on Android, Windows, macOS, ChromeOS

Open the link in Chrome or Edge. You'll see either an **Install** icon in the address bar, or an option in the browser's `⋮` menu called **Install app** / **Add to Home screen**. Same result: a standalone, full-screen icon.

## About syncing Family Hub itself across everyone's devices

The version I first built ran inside Claude's environment with shared storage that synced automatically. Once you host the files yourself, I've built in a fallback so the app still works — it saves to each browser's local storage. The catch: that's per-device. For everyone to see the same live data, the app needs a small backend: **Firebase** or **Supabase** (both free-tier, no server to manage) drop into the `storageAdapter` at the top of the script. Say the word and I'll wire it up.

## Connecting to Google, Outlook, Yahoo, and Cozi

Tap **🔄 Sync** on the Calendar tab. The short version: all four of those apps read and write the same standard calendar format, `.ics` (iCalendar), so that's the bridge Family Hub uses. Two things work today, no setup:

- **Import** — export an `.ics` file from Google/Outlook/Yahoo/Cozi and load it in the Sync panel. Its events show up in Family Hub, assigned to whichever family member you choose. Re-importing skips duplicates.
- **Export** — download an `.ics` of the whole family (or one person) and import it into any of the four.

The Sync panel has step-by-step "where to find the file" notes for each service.

### Google Calendar live sync — built in, two-way, no backend

Tap **🔄 Sync** (or **Settings → Open calendar sync**) → **Connect Google**. Google's own in-browser sign-in (Google Identity Services) handles the security; you just approve access. Once connected it's **two-way**:

- **Pull** — reads your Google events and fills Family Hub immediately.
- **Write-back** — when you add, edit, or delete an event in Family Hub with "Sync with Google Calendar" checked, the same change happens in your real Google calendar.
- **Repeating events** — set **Repeats** when adding an event (daily, weekdays, weekly, every 2 weeks, monthly, yearly) and choose an end (after N times, or on a date). The series is written to Google as one real recurring event, not a pile of copies. Editing or deleting one gives you the choice of *this event only* or *all events in the series*.

It uses the `calendar.events` permission — the least-privilege scope that still allows editing. It can read and change events, but can't touch your calendar sharing or account settings.

One-time setup (about 5 minutes):

1. Go to the **Google Cloud Console** → create/select a project.
2. **APIs & Services → Library** → enable the **Google Calendar API**.
3. **APIs & Services → OAuth consent screen** → set it up (External is fine); add yourself as a **Test user** while it's in testing.
4. **APIs & Services → Credentials → Create credentials → OAuth client ID** → application type **Web application**.
5. Under **Authorized JavaScript origins**, add the origin where you host the app (e.g. `https://your-site.netlify.app`).
6. Copy the **Client ID** (ends in `.apps.googleusercontent.com`), paste it into the Google box in the Sync panel, then **Connect Google**.

**You never need a client secret.** This is a browser-only app, so every file it serves is public — a secret pasted here would be published, not protected. Google's sign-in flow used here (Identity Services token flow with PKCE) is built for exactly this case and needs only the Client ID. If the console offers you a secret, skip it.

#### Choosing which calendar to sync

The Sync panel has a **calendar** box under the Google status line. It accepts either:

- `primary` — the signed-in person's own Google calendar.
- A **shared calendar ID**, which looks like a long string ending in `@group.calendar.google.com`. Find it in Google Calendar → hover the calendar → **⋮** → **Settings and sharing** → **Integrate calendar** → **Calendar ID**.

The app ships pointed at the shared family calendar, so everyone who connects lands on the same events. For write-back to work, each person needs **"Make changes to events"** permission on that calendar — share it with them from the same **Settings and sharing** screen.

Note on Google sessions: browsers don't get long-lived Google refresh tokens, so after about an hour you may need to hit **Connect**/**Refresh** again. Outlook (via MSAL) can refresh more quietly within a session.

### Outlook live sync — built in, two-way, no backend needed

Family Hub now has **automatic, two-way Outlook sync built in**, and it needs *no server*. Microsoft's own MSAL.js library signs you in securely from the browser (OAuth authorization-code flow with PKCE), so the app talks to Microsoft Graph directly. It's loaded from jsDelivr because Microsoft retired its own MSAL CDN.

What it does once connected:
- **Pull from Outlook** — brings your Outlook events (30 days back to ~6 months ahead) into Family Hub, assigned to whichever family member you pick. Re-pulling updates existing ones instead of duplicating.
- **Write-back** — when you add or edit an event in Family Hub with "Also add to Outlook" checked, it's created/updated in your real Outlook calendar. Deleting it here deletes it there too.

One-time setup (about 5 minutes, and squarely your Azure wheelhouse):

1. Go to the Azure portal → **Microsoft Entra ID** → **App registrations** → **New registration**.
2. Name it (e.g. "Family Hub"), and under **Supported account types** pick "Accounts in any organizational directory and personal Microsoft accounts" (so Outlook.com works too).
3. Under **Redirect URI**, choose platform **Single-page application (SPA)** and enter the exact URL where you host the app (e.g. `https://your-site.netlify.app/index.html`). The redirect URI must match the page URL exactly.
4. Register. Copy the **Application (client) ID**.
5. Go to **API permissions** → **Add a permission** → **Microsoft Graph** → **Delegated** → add `Calendars.ReadWrite` and `User.Read`. (Personal accounts consent at sign-in; for a work tenant you may click "Grant admin consent.")
6. Open the app → Calendar tab → **🔄 Sync** → scroll to **Outlook live sync** → paste the Client ID → **Connect Outlook**.

Because this uses a browser popup and a registered redirect URI, it only works when the app is **hosted at that https URL** — not when opened as a local file. Test it in your own tenant/account after deploying.

### The other three

- **Google** can do the same style of live sync via Google Identity Services + the Calendar API (also browser-only with PKCE). I can add a "Connect Google" button alongside Outlook the same way — just say the word.
- **Yahoo** has no modern API (CalDAV only), so live sync needs a small proxy. File import/export is the realistic option.
- **Cozi** offers no developer API at all — read-only feed subscription in, feed export out. No app, including this one, can edit a Cozi calendar. File import/export is the ceiling.

## Security, error-handling & reliability

This build is hardened around three things you asked to prioritize:

**Security**
- A Content Security Policy locks down where the app can load code from and send data to — only Microsoft's sign-in/Graph endpoints, the MSAL library CDN, and Google Fonts. It can't be pointed at an attacker's server.
- The parental PIN is stored **hashed (SHA-256)**, not as plain text, wherever the browser supports it.
- All text people type (names, event titles, notes, recipes) is HTML-escaped before display, so a mischievous entry can't inject anything.
- Outlook access tokens live only in the browser session (MSAL's sessionStorage) and vanish when the tab closes. Your Azure Client ID isn't a secret, so storing it is fine.
- Uploaded profile photos are validated as real images and re-encoded before saving.

**Error-handling**
- Every file read, image load, save, and Outlook call is wrapped so failures show a plain-English message instead of failing silently.
- If saved data ever becomes unreadable, the app **backs it up instead of overwriting it**, then starts fresh — so nothing is quietly lost.
- Outlook errors are translated into specific guidance (popup blocked, redirect URI mismatch, permission missing, etc.).

**Catch-all**
- A global handler catches any unexpected error or rejected promise anywhere in the app, shows a brief message, and keeps the app running rather than freezing on a blank screen.
- Any unknown or broken screen falls back to the calendar with a "back to calendar" recovery button.

## What's still not possible without a native app

A couple of things from your original list genuinely need a native iOS app built in Xcode with Apple's own frameworks, not a web app:

- **True Screen Time / parental controls** — Apple's Family Controls framework, only available to a compiled app installed through Xcode or the App Store.
- **Live two-way Google Calendar sync** through Apple's EventKit or Google's own Calendar API needs a signed backend service.
- **Home Screen widgets** (Apple's WidgetKit) — a widget showing today's chores or events on the actual iOS home screen, separate from the app icon.

If any of those matter enough to be worth it, that's a real "let's build a native Swift app" project — different scope, different tools (Xcode, an Apple Developer account, Swift/SwiftUI), and I'm happy to help you scope that out whenever you're ready. But for a family calendar/chore/budget hub, the installed web app above covers everything else on your list.
