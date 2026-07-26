# family-hub-ghanayem

Stores and hosts the Ghanayem Family Hub calendar app.

## Live app

The app is published by GitHub Actions straight from [family-hub-app](family-hub-app):

**https://markingmyname.github.io/family-hub-ghanayem/**

That's the one link every family member opens. On iPhone/iPad, open it in Safari and tap **Share → Add to Home Screen**. On Android, Windows, or macOS, open it in Chrome or Edge and choose **Install app**. Either way it launches full screen, with no browser chrome.

## What's in this repo

| Path | What it is |
| --- | --- |
| [family-hub-app](family-hub-app) | The installable app — this is what gets published. Full setup guide in its [README](family-hub-app/README.md). |
| [gfh-v1](gfh-v1) | The original single-file version and an earlier zip, kept for reference. |
| [.github/workflows/pages.yml](.github/workflows/pages.yml) | Publishes the app to GitHub Pages on every push to `main`. |

The app is plain HTML, CSS, and JavaScript in one file — no build step, no dependencies, no server.

## Publishing changes

Edit the files in `family-hub-app/`, then commit and push to `main`. The workflow redeploys automatically within a minute or two. There's no second copy to keep in sync.

To republish without changing anything, go to the repo's **Actions** tab → **Deploy Family Hub to GitHub Pages** → **Run workflow**.

## Enabling GitHub Pages (one time)

In this repo: **Settings → Pages → Build and deployment** → Source → **GitHub Actions**.

Pick **GitHub Actions**, not "Deploy from a branch" — the branch option only serves the repo root or `/docs`, and this app lives in neither.

## Calendar sync

The app does two-way Google Calendar sync and two-way Outlook sync, both entirely in the browser with no backend. Each needs a one-time OAuth Client ID. Full walkthrough: [family-hub-app/README.md](family-hub-app/README.md).

Whichever URL you publish at must be added as an **Authorized JavaScript origin** on the Google OAuth client — for this repo that's `https://markingmyname.github.io` (origin only, no path).
