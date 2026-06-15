#!/usr/bin/env python3
"""linkedin — minimal CLI for posting to LinkedIn via Open Permissions API.

Requires a LinkedIn Developer app with these products enabled:
  - "Sign In with LinkedIn using OpenID Connect"  (gives openid profile email)
  - "Share on LinkedIn"                           (gives w_member_social)

Get the token via the in-portal Token Generator:
  https://www.linkedin.com/developers/tools/oauth/token-generator

Token lifetime: 60 days. Re-mint via the portal when it expires (or before).

Storage: ~/.config/linkedin/token.json (mode 600)

Subcommands:
  linkedin login [--token TOKEN | --token-file PATH | --stdin]
  linkedin whoami
  linkedin token-status
  linkedin post "TEXT" [--visibility public|connections]
                       [--url URL [--title T] [--description D]]
                       [--image PATH [--alt-text T]]
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
from pathlib import Path
from typing import Any

import requests

CONFIG_DIR = Path(os.environ.get("LINKEDIN_CONFIG_DIR") or Path.home() / ".config" / "linkedin")
TOKEN_FILE = CONFIG_DIR / "token.json"

API_BASE = "https://api.linkedin.com"
USERINFO_URL = f"{API_BASE}/v2/userinfo"        # OpenID Connect
UGC_URL = f"{API_BASE}/v2/ugcPosts"
ASSETS_REGISTER_URL = f"{API_BASE}/v2/assets?action=registerUpload"

UA = "linkedin-cli/1.0 (+https://github.com/brandonwise)"


# ---------- helpers ----------

def _now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def _iso(d: dt.datetime) -> str:
    return d.strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_iso(s: str) -> dt.datetime:
    # "2026-08-14T10:00:00Z" → tz-aware UTC
    return dt.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)


def _fail(msg: str, code: int = 1) -> None:
    sys.stderr.write(f"linkedin: {msg}\n")
    sys.exit(code)


def _ensure_config_dir() -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(CONFIG_DIR, 0o700)


def load_token() -> dict[str, Any]:
    if not TOKEN_FILE.exists():
        _fail("not logged in. Run `linkedin login` first.")
    try:
        return json.loads(TOKEN_FILE.read_text())
    except json.JSONDecodeError as e:
        _fail(f"token file is corrupt: {e}")


def save_token(payload: dict[str, Any]) -> None:
    _ensure_config_dir()
    TOKEN_FILE.write_text(json.dumps(payload, indent=2, sort_keys=True))
    os.chmod(TOKEN_FILE, 0o600)


def auth_headers(token: str, restli: bool = False) -> dict[str, str]:
    h = {
        "Authorization": f"Bearer {token}",
        "User-Agent": UA,
    }
    if restli:
        h["X-Restli-Protocol-Version"] = "2.0.0"
    return h


# ---------- userinfo / login ----------

def fetch_userinfo(token: str) -> dict[str, Any]:
    r = requests.get(USERINFO_URL, headers=auth_headers(token), timeout=15)
    if r.status_code == 401:
        _fail("token rejected (401). Mint a fresh one via the LinkedIn Developer Portal Token Generator.")
    if r.status_code == 403:
        _fail("token lacks required scopes. Need: openid profile email w_member_social.")
    r.raise_for_status()
    return r.json()


def cmd_login(args: argparse.Namespace) -> None:
    token = (
        args.token
        or (args.token_file and Path(args.token_file).read_text().strip())
        or (args.stdin and sys.stdin.read().strip())
        or os.environ.get("LINKEDIN_ACCESS_TOKEN")
    )
    if not token:
        _fail(
            "no token supplied. Pass --token TOKEN, --token-file PATH, --stdin, "
            "or set LINKEDIN_ACCESS_TOKEN."
        )

    info = fetch_userinfo(token)
    sub = info.get("sub")
    if not sub:
        _fail(f"userinfo missing 'sub' field: {info!r}")

    person_urn = f"urn:li:person:{sub}"
    expires_in = int(args.expires_in or 60 * 24 * 3600)  # default 60 days
    obtained = _now()
    expires_at = obtained + dt.timedelta(seconds=expires_in)

    payload = {
        "access_token": token,
        "scope": args.scope or "openid profile email w_member_social",
        "obtained_at": _iso(obtained),
        "expires_at": _iso(expires_at),
        "person_urn": person_urn,
        "sub": sub,
        "name": info.get("name"),
        "email": info.get("email"),
        "given_name": info.get("given_name"),
        "family_name": info.get("family_name"),
        "picture": info.get("picture"),
    }
    save_token(payload)
    print(f"✓ Logged in as {info.get('name')} <{info.get('email')}>")
    print(f"  Person URN: {person_urn}")
    print(f"  Token saved: {TOKEN_FILE} (mode 600)")
    print(f"  Expires: {payload['expires_at']}  (~{expires_in // 86400} days)")


def cmd_whoami(_: argparse.Namespace) -> None:
    tok = load_token()
    info = fetch_userinfo(tok["access_token"])
    print(f"Name:       {info.get('name')}")
    print(f"Email:      {info.get('email')}")
    print(f"Person URN: urn:li:person:{info.get('sub')}")
    print(f"Picture:    {info.get('picture')}")
    print(f"Token expires: {tok.get('expires_at')}")


def cmd_token_status(_: argparse.Namespace) -> None:
    tok = load_token()
    expires_at = _parse_iso(tok["expires_at"])
    remaining = expires_at - _now()
    days = remaining.total_seconds() / 86400
    if days < 0:
        print(f"✗ EXPIRED {abs(int(days))} day(s) ago — re-mint via the Developer Portal Token Generator.")
        sys.exit(2)
    elif days < 14:
        print(f"⚠ {days:.1f} days remaining — re-mint soon at:")
        print("  https://www.linkedin.com/developers/tools/oauth/token-generator")
        sys.exit(1)
    else:
        print(f"✓ {days:.1f} days remaining")
        print(f"  expires: {tok['expires_at']}")


# ---------- posting ----------

VISIBILITY_MAP = {
    "public": "PUBLIC",
    "connections": "CONNECTIONS",
}


def _post_ugc(token: str, body: dict[str, Any]) -> str:
    r = requests.post(
        UGC_URL,
        headers={
            **auth_headers(token, restli=True),
            "Content-Type": "application/json",
        },
        json=body,
        timeout=30,
    )
    if r.status_code == 401:
        _fail("token rejected (401). Re-mint via the Developer Portal Token Generator.")
    if r.status_code == 403:
        _fail(f"forbidden (403): {r.text[:300]}")
    if r.status_code == 429:
        _fail("rate-limited (429). Daily cap is 150 posts/member.")
    if r.status_code >= 400:
        _fail(f"HTTP {r.status_code}: {r.text[:500]}")
    post_id = r.headers.get("X-RestLi-Id") or r.headers.get("x-restli-id") or "(no id)"
    return post_id


def _share_text(text: str) -> dict[str, Any]:
    return {
        "shareCommentary": {"text": text},
        "shareMediaCategory": "NONE",
    }


def _share_url(text: str, url: str, title: str | None, description: str | None) -> dict[str, Any]:
    media: dict[str, Any] = {"status": "READY", "originalUrl": url}
    if title:
        media["title"] = {"text": title}
    if description:
        media["description"] = {"text": description}
    return {
        "shareCommentary": {"text": text},
        "shareMediaCategory": "ARTICLE",
        "media": [media],
    }


def _register_image(token: str, person_urn: str) -> dict[str, str]:
    body = {
        "registerUploadRequest": {
            "recipes": ["urn:li:digitalmediaRecipe:feedshare-image"],
            "owner": person_urn,
            "serviceRelationships": [
                {"relationshipType": "OWNER", "identifier": "urn:li:userGeneratedContent"}
            ],
        }
    }
    r = requests.post(
        ASSETS_REGISTER_URL,
        headers={**auth_headers(token, restli=True), "Content-Type": "application/json"},
        json=body,
        timeout=20,
    )
    r.raise_for_status()
    data = r.json()["value"]
    return {
        "upload_url": data["uploadMechanism"]["com.linkedin.digitalmedia.uploading.MediaUploadHttpRequest"]["uploadUrl"],
        "asset": data["asset"],
    }


def _upload_image(upload_url: str, token: str, image_path: Path) -> None:
    with image_path.open("rb") as f:
        r = requests.put(
            upload_url,
            headers={"Authorization": f"Bearer {token}", "User-Agent": UA},
            data=f,
            timeout=60,
        )
    if r.status_code >= 400:
        _fail(f"image upload failed HTTP {r.status_code}: {r.text[:300]}")


def _share_image(text: str, asset_urn: str, alt: str | None, title: str | None) -> dict[str, Any]:
    media: dict[str, Any] = {"status": "READY", "media": asset_urn}
    if alt:
        media["description"] = {"text": alt}
    if title:
        media["title"] = {"text": title}
    return {
        "shareCommentary": {"text": text},
        "shareMediaCategory": "IMAGE",
        "media": [media],
    }


def cmd_post(args: argparse.Namespace) -> None:
    tok = load_token()
    token = tok["access_token"]
    person_urn = tok["person_urn"]

    text = args.text
    visibility = VISIBILITY_MAP[args.visibility]

    if args.image:
        image_path = Path(args.image).expanduser()
        if not image_path.is_file():
            _fail(f"image not found: {image_path}")
        if args.url:
            _fail("--image and --url are mutually exclusive (LinkedIn picks one preview type).")
        print(f"→ registering image upload …", file=sys.stderr)
        reg = _register_image(token, person_urn)
        print(f"→ uploading {image_path.name} ({image_path.stat().st_size} bytes) …", file=sys.stderr)
        _upload_image(reg["upload_url"], token, image_path)
        share_content = _share_image(text, reg["asset"], args.alt_text, args.title)
    elif args.url:
        share_content = _share_url(text, args.url, args.title, args.description)
    else:
        share_content = _share_text(text)

    body = {
        "author": person_urn,
        "lifecycleState": "PUBLISHED",
        "specificContent": {"com.linkedin.ugc.ShareContent": share_content},
        "visibility": {"com.linkedin.ugc.MemberNetworkVisibility": visibility},
    }

    if args.dry_run:
        print(json.dumps(body, indent=2))
        return

    print(f"→ posting ({len(text)} chars, visibility={visibility}) …", file=sys.stderr)
    post_id = _post_ugc(token, body)
    # Convert urn:li:share:NNN to a share URL
    share_id = post_id.split(":")[-1] if ":" in post_id else post_id
    print(f"✓ posted: {post_id}")
    print(f"  URL: https://www.linkedin.com/feed/update/{post_id}/")


# ---------- main ----------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="linkedin", description="Post to LinkedIn via Open Permissions API.")
    sub = p.add_subparsers(dest="cmd", required=True)

    pl = sub.add_parser("login", help="Save and verify a LinkedIn access token.")
    pl.add_argument("--token", help="Access token (string).")
    pl.add_argument("--token-file", help="Read token from file.")
    pl.add_argument("--stdin", action="store_true", help="Read token from stdin.")
    pl.add_argument("--scope", help="Override stored scope string.")
    pl.add_argument("--expires-in", type=int, help="Seconds until expiry (default 60d).")
    pl.set_defaults(func=cmd_login)

    pw = sub.add_parser("whoami", help="Show profile info from /v2/userinfo.")
    pw.set_defaults(func=cmd_whoami)

    pt = sub.add_parser("token-status", help="Show token expiry / warn if expiring.")
    pt.set_defaults(func=cmd_token_status)

    pp = sub.add_parser("post", help="Publish a share to your LinkedIn feed.")
    pp.add_argument("text", help="Post body text.")
    pp.add_argument(
        "--visibility",
        choices=["public", "connections"],
        default="public",
        help="Audience (default: public).",
    )
    pp.add_argument("--url", help="Attach an article/URL preview.")
    pp.add_argument("--title", help="Title for the URL or image attachment.")
    pp.add_argument("--description", help="Description for the URL attachment.")
    pp.add_argument("--image", help="Path to an image file to attach.")
    pp.add_argument("--alt-text", help="Alt text / description for image.")
    pp.add_argument("--dry-run", action="store_true", help="Print the POST body without sending.")
    pp.set_defaults(func=cmd_post)

    return p


def main(argv: list[str] | None = None) -> None:
    args = build_parser().parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    try:
        main()
    except requests.RequestException as e:
        _fail(f"network error: {e}")
    except KeyboardInterrupt:
        sys.stderr.write("\nlinkedin: aborted\n")
        sys.exit(130)
