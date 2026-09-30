#!/usr/bin/env python3
# One-time interactive Telegram login. Run this yourself, e.g.:
#   python3 telegram_login.py
# It will ask for your phone number and the login code Telegram sends you -
# that can't happen non-interactively, which is why this is a separate
# script from lookup_sizes.py (which requires the session this creates).
# Needs ~/.config/omarchy-downloads/telegram.json filled in with an
# api_id/api_hash from https://my.telegram.org/apps first.
import json
import os
import sys

from telethon.sync import TelegramClient

CONFIG_PATH = os.path.expanduser("~/.config/omarchy-downloads/telegram.json")
SESSION_PATH = os.path.expanduser("~/.local/share/omarchy-downloads/telegram")


def main():
    if not os.path.exists(CONFIG_PATH):
        print(f"Missing {CONFIG_PATH}", file=sys.stderr)
        sys.exit(1)
    with open(CONFIG_PATH) as f:
        cfg = json.load(f)
    api_id = cfg.get("api_id")
    api_hash = cfg.get("api_hash")
    if not api_id or not api_hash:
        print(f"{CONFIG_PATH} is missing api_id/api_hash - get them from "
              "https://my.telegram.org/apps and fill in that file first.", file=sys.stderr)
        sys.exit(1)

    os.makedirs(os.path.dirname(SESSION_PATH), exist_ok=True)
    with TelegramClient(SESSION_PATH, int(api_id), api_hash) as client:
        me = client.get_me()
        print(f"Logged in as {me.first_name} (@{me.username}).")
        print(f"Session saved to {SESSION_PATH}.session - lookup_sizes.py will use it from now on.")


if __name__ == "__main__":
    main()
