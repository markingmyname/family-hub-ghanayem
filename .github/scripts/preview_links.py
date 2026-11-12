"""Keeps a pull request's preview link where people can click it.

What this does
    Runs right after rossjrw/pr-preview-action has published (or removed) a
    pull request's preview on the gh-pages branch, and puts the preview link in
    three places:
      1. The PR description — a "Preview" link at the top, between two hidden
         markers so each run replaces it instead of adding another.
      2. A PR comment — a "Preview" link plus a QR code for phones. It replaces
         the action's own comment, whose address isn't a labeled link.
      3. A GitHub deployment in the "pr-preview" environment — the PR shows a
         "View deployment" button, and the repository's Deployments page lists
         the link.
    When the PR closes the preview is gone, so the description link is taken
    out, the comment says the preview was removed, and this PR's deployments
    are marked inactive.

Depends on
    - .github/workflows/preview.yml, which runs this file and passes it these
      environment variables: GH_TOKEN, GITHUB_REPOSITORY, GITHUB_SERVER_URL,
      GITHUB_RUN_ID, PR_NUMBER, HEAD_SHA, DEPLOYMENT_ACTION (deploy | remove),
      PREVIEW_URL, ACTION_VERSION.
    - The GitHub CLI (`gh`), preinstalled on GitHub-hosted runners, for every
      API call. GH_TOKEN needs pull-requests: write (description, comment) and
      deployments: write (deployment records).
    - qr.rossjrw.com, the QR-code image service the action itself uses. If it
      is down, the comment shows a broken image; the link still works.

Safety
    Text read from GitHub (the description, comments) is handled only as data
    in Python and sent back through `gh api --input`, never through a shell,
    so nothing typed into a PR can run as a command.

Each of the three parts runs even if another fails; any failure is printed and
makes the script exit 1, so the workflow run shows red rather than hiding it.
"""

import json
import os
import re
import subprocess
import sys
from urllib.parse import quote

# Markers. DESC_* wrap the link in the PR description; COMMENT_MARK identifies
# this script's comment. LEGACY_COMMENT_MARK is the action's own comment,
# deleted so a PR never shows two preview comments.
DESC_START = "<!-- pr-preview-link -->"
DESC_END = "<!-- /pr-preview-link -->"
COMMENT_MARK = "<!-- pr-preview-comment -->"
LEGACY_COMMENT_MARK = "<!-- Sticky Pull Request Commentpr-preview -->"
BOT_LOGIN = "github-actions[bot]"

ENVIRONMENT = "pr-preview"
QR_SERVICE = "https://qr.rossjrw.com/?color.dark=0d1117&url="
ACTION_LINK = "https://github.com/rossjrw/pr-preview-action"


class GhError(RuntimeError):
    """A GitHub API call failed. The message says which call and why."""


def log(level, message):
    """One line per event in the workflow log. Never prints the token."""
    print(f"{level:<5} {message}", flush=True)


# ------------------------------- GitHub API -------------------------------

def gh_api(method, path, body=None):
    """Calls the GitHub REST API through the gh CLI and returns parsed JSON.

    External dependency: api.github.com via `gh`. A non-zero exit raises
    GhError with gh's error text. The request body goes in on stdin as JSON,
    never as command-line text.
    """
    args = ["gh", "api", "-X", method, "-H", "Accept: application/vnd.github+json", path]
    if body is not None:
        args += ["--input", "-"]
    try:
        result = subprocess.run(
            args,
            input=json.dumps(body) if body is not None else None,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
    except FileNotFoundError as err:
        raise GhError("the gh CLI isn't installed on this runner") from err
    if result.returncode != 0:
        raise GhError(f"{method} {path} failed: {result.stderr.strip()[:300]}")
    return json.loads(result.stdout) if result.stdout.strip() else None


def gh_list(path):
    """Every item from a list endpoint, 100 per page."""
    items, page = [], 1
    joiner = "&" if "?" in path else "?"
    while True:
        batch = gh_api("GET", f"{path}{joiner}per_page=100&page={page}") or []
        items.extend(batch)
        if len(batch) < 100:
            return items
        page += 1


# ----------------------------- 1. Description ------------------------------

def update_description(ctx):
    """Puts the Preview link at the top of the PR description, or takes it out."""
    pr = gh_api("GET", f"repos/{ctx['repo']}/pulls/{ctx['pr']}")
    body = pr.get("body") or ""
    # Take out any earlier link (and the blank line after it) first, so the
    # link is replaced, never duplicated.
    new = re.sub(re.escape(DESC_START) + r".*?" + re.escape(DESC_END) + r"\s*", "", body, flags=re.S)
    if ctx["action"] == "deploy":
        new = f"{DESC_START}\n[Preview]({ctx['url']})\n{DESC_END}\n\n" + new
    if new == body:
        log("INFO", "description: already up to date")
        return
    gh_api("PATCH", f"repos/{ctx['repo']}/pulls/{ctx['pr']}", {"body": new})
    log("INFO", f"description: link {'added' if ctx['action'] == 'deploy' else 'removed'}")


# ------------------------------- 2. Comment --------------------------------

def comment_body(ctx):
    if ctx["action"] == "deploy":
        url = ctx["url"]
        qr = QR_SERVICE + quote(url, safe="")
        return (
            f"{COMMENT_MARK}\n"
            f"### [Preview]({url})\n\n"
            f'<a href="{url}"><img src="{qr}" height="120" alt="QR code that opens the preview"></a>\n\n'
            f"Built from commit `{ctx['sha'][:7]}`. Opens about a minute after this comment updates, "
            f"and is removed when this pull request closes.\n\n"
            f"<sub>Published by [PR Preview Action]({ACTION_LINK}) {ctx['action_version']}</sub>\n"
        )
    return (
        f"{COMMENT_MARK}\n"
        f"### Preview removed\n\n"
        f"This pull request is closed, so its preview was taken down.\n"
    )


def update_comment(ctx):
    """Keeps one comment with the clickable link; deletes the action's own comment."""
    comments = gh_list(f"repos/{ctx['repo']}/issues/{ctx['pr']}/comments")
    from_bot = [c for c in comments if (c.get("user") or {}).get("login") == BOT_LOGIN]

    for old in (c for c in from_bot if LEGACY_COMMENT_MARK in (c.get("body") or "")):
        gh_api("DELETE", f"repos/{ctx['repo']}/issues/comments/{old['id']}")
        log("INFO", f"comment: deleted the action's own comment {old['id']}")

    ours = [c for c in from_bot if COMMENT_MARK in (c.get("body") or "")]
    if not ours and ctx["action"] == "remove":
        log("INFO", "comment: none to update")
        return
    body = comment_body(ctx)
    if not ours:
        gh_api("POST", f"repos/{ctx['repo']}/issues/{ctx['pr']}/comments", {"body": body})
        log("INFO", "comment: posted")
        return
    keep, extras = ours[0], ours[1:]
    if keep.get("body") != body:
        gh_api("PATCH", f"repos/{ctx['repo']}/issues/comments/{keep['id']}", {"body": body})
        log("INFO", f"comment: updated {keep['id']}")
    else:
        log("INFO", "comment: already up to date")
    for extra in extras:
        gh_api("DELETE", f"repos/{ctx['repo']}/issues/comments/{extra['id']}")
        log("INFO", f"comment: deleted duplicate {extra['id']}")


# ------------------------------ 3. Deployment ------------------------------

def update_deployment(ctx):
    """Records the preview as a GitHub deployment; marks old ones inactive.

    One "pr-preview" environment holds every PR's previews. Each deployment
    carries its PR number in `payload`, so only this PR's older ones are made
    inactive, and auto_inactive is off so other open PRs keep their buttons.
    """
    repo = ctx["repo"]
    for dep in gh_list(f"repos/{repo}/deployments?environment={ENVIRONMENT}"):
        payload = dep.get("payload") if isinstance(dep.get("payload"), dict) else {}
        if payload.get("pr") != ctx["pr"]:
            continue
        latest = gh_api("GET", f"repos/{repo}/deployments/{dep['id']}/statuses?per_page=1") or []
        if latest and latest[0].get("state") == "inactive":
            continue
        gh_api("POST", f"repos/{repo}/deployments/{dep['id']}/statuses", {"state": "inactive"})
        log("INFO", f"deployment: marked {dep['id']} inactive")

    if ctx["action"] != "deploy":
        return
    dep = gh_api("POST", f"repos/{repo}/deployments", {
        "ref": ctx["sha"],               # a commit, not a branch: nothing is merged
        "environment": ENVIRONMENT,
        "auto_merge": False,             # never merge main into the PR branch
        "required_contexts": [],         # don't wait on other checks
        "transient_environment": True,
        "production_environment": False,
        "description": f"Preview for PR #{ctx['pr']}",
        "payload": {"pr": ctx["pr"]},
    })
    gh_api("POST", f"repos/{repo}/deployments/{dep['id']}/statuses", {
        "state": "success",
        "environment_url": ctx["url"],
        "log_url": ctx["run_url"],
        "description": "Preview published",
        "auto_inactive": False,
    })
    log("INFO", f"deployment: {dep['id']} -> {ctx['url']}")


# --------------------------------- Main ------------------------------------

def read_context(env):
    """Validates the inputs before any API call, and fails fast if one is wrong."""
    action = env.get("DEPLOYMENT_ACTION", "")
    if action not in ("deploy", "remove"):
        raise ValueError(f"DEPLOYMENT_ACTION must be deploy or remove, got {action!r}")
    pr_text = env.get("PR_NUMBER", "")
    if not pr_text.isdigit():
        raise ValueError(f"PR_NUMBER must be a number, got {pr_text!r}")
    sha = env.get("HEAD_SHA", "")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError(f"HEAD_SHA must be a full commit SHA, got {sha!r}")
    url = env.get("PREVIEW_URL", "")
    if action == "deploy" and not url.startswith("https://"):
        raise ValueError(f"refusing to link a preview URL that isn't https: {url!r}")
    repo = env["GITHUB_REPOSITORY"]
    server = env.get("GITHUB_SERVER_URL", "https://github.com")
    return {
        "action": action,
        "pr": int(pr_text),
        "sha": sha,
        "url": url,
        "repo": repo,
        "action_version": env.get("ACTION_VERSION", ""),
        "run_url": f"{server}/{repo}/actions/runs/{env.get('GITHUB_RUN_ID', '')}",
    }


def main(env=os.environ):
    try:
        ctx = read_context(env)
    except (KeyError, ValueError) as err:
        log("ERROR", f"bad input: {err}")
        return 1
    log("INFO", f"PR #{ctx['pr']}: {ctx['action']} {ctx['url'] or ''}".rstrip())

    failed = []
    for name, step in (("description", update_description),
                       ("comment", update_comment),
                       ("deployment", update_deployment)):
        try:
            step(ctx)
        except (GhError, KeyError, TypeError, ValueError) as err:
            log("ERROR", f"{name}: {err}")
            failed.append(name)
        except Exception as err:  # last resort: report it, keep going with the other parts
            log("ERROR", f"{name}: unexpected {type(err).__name__}: {err}")
            failed.append(name)
    if failed:
        log("ERROR", f"failed: {', '.join(failed)}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
