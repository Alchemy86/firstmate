#!/usr/bin/env python3
"""Build one Discord message payload, and own the kind table.

Pure payload builder: it prints JSON and makes no network call. Transport is
bin/fm-dc-lib.sh's fm_dc_api, so there is exactly one place a Discord request
is constructed and exactly one place the mandatory User-Agent is spelled.

This exists as Python rather than inline shell for a concrete reason: an embed
is nested JSON carrying captain-facing text nobody sanitises - PR titles with
apostrophes, commit subjects with quotes, multi-line failure output. Building
that by string-concatenation in bash breaks on the first apostrophe and is an
injection surface besides. json.dumps is not a preference here, it is the
correctness requirement.

    fm-dc-embed.py --kind <kind> [options]      print the message payload
    fm-dc-embed.py --print-channel <kind>       print that kind's home channel
    fm-dc-embed.py --print-kinds                list the kinds

THE DELIBERATE OMISSION: there is no `progress` kind, and adding one is a
behavior change, not a convenience. The captain's standing rule is that a
channel full of noise is one he stops reading, so routine progress, empty
polls and no-change updates have nowhere to go here by construction. They
belong in a task's status file, which is what firstmate already reads.
"""

import argparse
import json
import sys
from datetime import datetime, timezone

# The single owner of colour, emoji, and default routing.
#
# Colour is the whole point: which channel it landed in answers "must I act?"
# and the colour answers "is this good or bad?" before a word is read. The
# blurple is Discord's own accent, deliberately reserved for the kind that
# actually wants the captain.
KINDS = {
    "ready":          {"color": 0x5865F2, "emoji": "\U0001F6A2", "channel": "ready",   "label": "Ready for review"},
    "blocked":        {"color": 0xE67E22, "emoji": "⛔",     "channel": "ready",   "label": "Blocked"},
    "needs-decision": {"color": 0xE67E22, "emoji": "❓",     "channel": "ready",   "label": "Needs a decision"},
    "broken":         {"color": 0xED4245, "emoji": "\U0001F534", "channel": "broken",  "label": "Broken"},
    "landed":         {"color": 0x2ECC71, "emoji": "✅",     "channel": "landed",  "label": "Landed"},
    "milestone":      {"color": 0xF1C40F, "emoji": "\U0001F3C6", "channel": "landed",  "label": "Milestone"},
    "note":           {"color": 0x95A5A6, "emoji": "\U0001F4CE", "channel": "landed",  "label": "Note"},
    "gallery":        {"color": 0x9B59B6, "emoji": "\U0001F3AC", "channel": "gallery", "label": "Artefact"},
}

# Discord's own hard limits. Truncating locally with a visible ellipsis beats
# letting the API reject the whole message for one long field.
LIM_TITLE = 256
LIM_DESC = 4096
LIM_FIELD_NAME = 256
LIM_FIELD_VALUE = 1024
LIM_FOOTER = 2048
MAX_FIELDS = 25


def clip(text, limit):
    text = str(text)
    return text if len(text) <= limit else text[: limit - 1] + "…"


def build(args):
    spec = KINDS[args.kind]
    embed = {"color": spec["color"], "timestamp": datetime.now(timezone.utc).isoformat()}

    title = args.title or spec["label"]
    embed["title"] = clip("%s  %s" % (spec["emoji"], title), LIM_TITLE)
    if args.url:
        # Makes the title itself the click target, so a PR is one tap from the
        # notification rather than a URL pasted into the body.
        embed["url"] = args.url
    if args.text:
        embed["description"] = clip(args.text, LIM_DESC)

    fields = []
    for raw in args.field or []:
        if "=" not in raw:
            sys.stderr.write("fm-dc-embed: --field needs name=value, got %r\n" % raw)
            return None
        name, value = raw.split("=", 1)
        if not name.strip() or not value.strip():
            sys.stderr.write("fm-dc-embed: --field name and value must both be non-empty: %r\n" % raw)
            return None
        fields.append(
            {
                "name": clip(name.strip(), LIM_FIELD_NAME),
                "value": clip(value.strip(), LIM_FIELD_VALUE),
                "inline": len(value.strip()) <= 40,
            }
        )
    if len(fields) > MAX_FIELDS:
        sys.stderr.write(
            "fm-dc-embed: %d fields, over Discord's limit of %d\n" % (len(fields), MAX_FIELDS)
        )
        return None
    if fields:
        embed["fields"] = fields

    footer = args.project or args.footer
    if footer:
        embed["footer"] = {"text": clip(footer, LIM_FOOTER)}

    payload = {"embeds": [embed]}
    if args.plain:
        # A plain-text message carries no embed at all; the kind still chose
        # the channel for it.
        payload = {"content": clip(args.text or title, 2000)}
    if args.attach_name:
        # An upload MUST be declared here as well as sent as a form part.
        # Discord rejects the whole message with "Invalid Form Body" (50035) if
        # an embed references attachment://<name> with no matching entry in
        # this array - the file part alone is not enough, and the error names
        # neither the field nor the file.
        payload["attachments"] = [{"id": 0, "filename": args.attach_name}]
        # Only a still image renders INSIDE an embed. Discord gives a video its
        # own player as an attachment, so pointing an embed at one leaves a
        # broken image frame sitting above a working video.
        ext = args.attach_name.rsplit(".", 1)[-1].lower() if "." in args.attach_name else ""
        if ext in ("png", "jpg", "jpeg", "gif", "webp") and not args.plain:
            embed["image"] = {"url": "attachment://%s" % args.attach_name}
    return payload


def main():
    p = argparse.ArgumentParser(add_help=True)
    p.add_argument("--kind")
    p.add_argument("--title")
    p.add_argument("--text")
    p.add_argument("--url")
    p.add_argument("--field", action="append")
    p.add_argument("--project")
    p.add_argument("--footer")
    p.add_argument("--attach-name")
    p.add_argument("--plain", action="store_true")
    p.add_argument("--print-channel")
    p.add_argument("--print-kinds", action="store_true")
    args = p.parse_args()

    if args.print_kinds:
        for name in KINDS:
            print(name)
        return 0
    if args.print_channel:
        spec = KINDS.get(args.print_channel)
        if not spec:
            sys.stderr.write("fm-dc-embed: unknown kind %r\n" % args.print_channel)
            return 2
        print(spec["channel"])
        return 0
    if not args.kind:
        sys.stderr.write("fm-dc-embed: --kind is required\n")
        return 2
    if args.kind not in KINDS:
        sys.stderr.write(
            "fm-dc-embed: unknown kind %r; known: %s\n" % (args.kind, ", ".join(KINDS))
        )
        return 2

    payload = build(args)
    if payload is None:
        return 2
    json.dump(payload, sys.stdout, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
