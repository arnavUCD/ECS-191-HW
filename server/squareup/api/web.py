"""Public web surface: invitation landing pages and the Apple App Site Association file.

``/r/<token>`` is the App Clip / universal-link invocation URL. Once the App Clip or the full app
is associated with this domain, iOS opens it instead of this page. Until then (and for anyone
without an iPhone) this page is the fallback: it offers the full app's own link and explains how to
join with the room's short code. It offers the App Clip (Smart App Banner and card) only once the
App Clip is live (``SQUAREUP_APP_CLIP_LIVE=1``, set after Apple approves its experience) and the
Apple identifiers are configured, and it reveals nothing about the room: it never looks up the token's
room, names, or amounts. The only thing echoed is the token itself (already in the address bar),
inside the "Open in Square Up" link for the full app's URL scheme.
"""

from __future__ import annotations

import re
from html import escape

from flask import Blueprint, Response, jsonify

from .common import services

blueprint = Blueprint("web", __name__)

_PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
{smart_banner}
<title>Join a shared receipt · Square Up</title>
<style>
 body{{font:17px -apple-system,system-ui,sans-serif;margin:0;padding:40px 24px;background:#050505;color:#F7F7F5}}
 main{{max-width:420px;margin:0 auto}} h1{{font-size:28px;margin:0 0 12px}} p{{color:#A5A8AD;line-height:1.45}}
 a.button{{display:inline-block;padding:14px 20px;border-radius:14px;background:#F7F7F5;color:#111214;font-weight:600;text-decoration:none}}
 @media (prefers-color-scheme: light){{body{{background:#F6F7F8;color:#111214}} p{{color:#62666D}}\
  a.button{{background:#111214;color:#F7F7F5}}}}
</style></head>
<body><main>
<h1>Join a shared receipt</h1>
<p>Someone invited you to claim what you had on a receipt in Square Up, an app for splitting costs with friends.</p>
{how_to_join}
{app_link}
<p>Don't have Square Up yet? Install it, then open this link again. Or ask the host for the room's
short code (like <b>ABCD-EFGH-JKMN</b>) and enter it in Square Up under Join a receipt.</p>
<p>Nothing about the receipt is shown here. You'll see a preview before you join.</p>
</main></body></html>"""

_TOKEN = re.compile(r"^[A-Za-z0-9_-]{32,128}$")


@blueprint.get("/r/<token>")
def invitation_page(token: str) -> Response:
    config = services().ctx.config
    banner = ""
    clip_available = config.app_clip_live and bool(
        config.apple_team_id and config.app_bundle_id and config.clip_bundle_id and config.app_store_id
    )
    if clip_available:
        banner = (
            f'<meta name="apple-itunes-app" content="app-id={escape(config.app_store_id or "")}, '
            f'app-clip-bundle-id={escape(config.clip_bundle_id or "")}, app-clip-display=card">'
        )
        how_to_join = "<p>On an iPhone, you can join right away with the Square Up App Clip — no download or account needed.</p>"
    else:
        how_to_join = "<p>To join, open this link on an iPhone with Square Up installed.</p>"
    app_link = ""
    if _TOKEN.match(token):
        link = f"squp://join/{escape(token)}"
        app_link = f'<p><a class="button" href="{link}">Open in Square Up</a></p>'
    page = _PAGE.format(smart_banner=banner, how_to_join=how_to_join, app_link=app_link)
    response = Response(page, mimetype="text/html")
    response.headers["Content-Security-Policy"] = "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'"
    response.headers["Cache-Control"] = "no-store"
    return response


@blueprint.get("/.well-known/apple-app-site-association")
def apple_app_site_association() -> tuple[Response, int]:
    """Associates the domain with the App Clip and the full app (requires a paid Apple team ID)."""
    config = services().ctx.config
    if not (config.apple_team_id and config.app_bundle_id):
        return jsonify({"error": {"code": "room_not_found", "message": "Not configured"}}), 404
    app_id = f"{config.apple_team_id}.{config.app_bundle_id}"
    body: dict[str, object] = {
        "applinks": {"details": [{"appIDs": [app_id], "components": [{"/": "/r/*", "comment": "Receipt room invitations"}]}]},
    }
    if config.clip_bundle_id:
        body["appclips"] = {"apps": [f"{config.apple_team_id}.{config.clip_bundle_id}"]}
    response = jsonify(body)
    response.headers["Cache-Control"] = "public, max-age=3600"
    return response, 200


_GROUP_PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Join a shared group · Square Up</title>
<style>
 body{{font:17px -apple-system,system-ui,sans-serif;margin:0;padding:40px 24px;background:#050505;color:#F7F7F5}}
 main{{max-width:420px;margin:0 auto}} h1{{font-size:28px;margin:0 0 12px}} p{{color:#A5A8AD;line-height:1.45}}
 code{{font:600 20px ui-monospace,Menlo,monospace;letter-spacing:1px;color:#F7F7F5;user-select:all;-webkit-user-select:all}}
 a.button{{display:inline-block;padding:14px 20px;border-radius:14px;background:#B7FF3C;color:#111214;font-weight:600;text-decoration:none}}
 @media (prefers-color-scheme: light){{body{{background:#F6F7F8;color:#111214}} p{{color:#62666D}} code{{color:#111214}}}}
</style></head>
<body><main>
<h1>Join a shared group</h1>
<p>Someone invited you to a shared group in Square Up, an app for splitting costs with friends.</p>
{content}
<p>Nothing about the group is shown here. You'll see a preview in the app before you join.</p>
</main></body></html>"""


@blueprint.get("/g/<code>")
def group_invitation_page(code: str) -> Response:
    """The HTTPS form of a group invitation. Without Associated Domains it's an ordinary page (not a
    universal link): it offers the app's own URL and the code to paste. It never looks the code up."""
    from ..services.groups import display_code, normalize_code

    normalized = normalize_code(code)
    if normalized is None:
        content = "<p>This invitation link isn't complete. Ask for a new one.</p>"
    else:
        content = (
            f'<p><a class="button" href="squp://join-group/{escape(normalized)}">Open Square Up</a></p>'
            f"<p>Or open Square Up, go to Groups, choose Join with a code, and paste:</p>"
            f"<p><code>{escape(display_code(normalized))}</code></p>"
        )
    response = Response(_GROUP_PAGE.format(content=content), mimetype="text/html")
    response.headers["Content-Security-Policy"] = "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'"
    response.headers["Cache-Control"] = "no-store"
    return response
