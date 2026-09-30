#!/usr/bin/env python3
# Looks up total file sizes for given filenames, via Telegram's global search
# (the same "search everywhere" feature the Telegram app itself has) to find
# the source message and read its document.size - this is the only way to
# get a real total, since Telegram Desktop never writes it to disk (see
# scan_downloads.py). Results are cached locally so a filename is only
# searched for once.
#
# Requires a session already created via telegram_login.py (interactive,
# run separately/manually). If that hasn't happened yet, prints
# {"error": "not logged in"} and does nothing else - never prompts.
#
# Usage: lookup_sizes.py <filename> [<filename> ...]
import asyncio
import json
import os
import sys
import time

from telethon import TelegramClient

CONFIG_PATH = os.path.expanduser("~/.config/omarchy-downloads/telegram.json")
SESSION_PATH = os.path.expanduser("~/.local/share/omarchy-downloads/telegram")
CACHE_PATH = os.path.expanduser("~/.local/share/omarchy-downloads/sizes-cache.json")
NEGATIVE_TTL = 600  # seconds - retry a not-found lookup after this long


def load_cache():
    try:
        with open(CACHE_PATH) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_cache(cache):
    os.makedirs(os.path.dirname(CACHE_PATH), exist_ok=True)
    tmp = CACHE_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cache, f)
    os.replace(tmp, CACHE_PATH)


async def find_size(client, filename):
    async for message in client.iter_messages(None, search=filename, limit=5):
        doc = message.document
        if not doc:
            continue
        name = next((a.file_name for a in doc.attributes if getattr(a, "file_name", None)), None)
        if name == filename:
            return doc.size
    return None


async def main(names):
    cache = load_cache()
    now = time.time()
    missing = [
        n for n in names
        if n not in cache
        or (cache[n].get("size") is None and now - cache[n].get("cachedAt", 0) > NEGATIVE_TTL)
    ]

    if missing:
        if not os.path.exists(CONFIG_PATH):
            print(json.dumps({"error": "not configured"}))
            return
        with open(CONFIG_PATH) as f:
            cfg = json.load(f)
        if not cfg.get("api_id") or not cfg.get("api_hash"):
            print(json.dumps({"error": "not configured"}))
            return

        client = TelegramClient(SESSION_PATH, int(cfg["api_id"]), cfg["api_hash"])
        await client.connect()
        if not await client.is_user_authorized():
            print(json.dumps({"error": "not logged in"}))
            await client.disconnect()
            return

        for name in missing:
            size = await find_size(client, name)
            cache[name] = {"size": size, "cachedAt": now}
        await client.disconnect()
        save_cache(cache)

    print(json.dumps({n: cache[n]["size"] for n in names if n in cache and cache[n].get("size") is not None}))


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1:]))
