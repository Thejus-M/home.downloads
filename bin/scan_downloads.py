#!/usr/bin/env python3
# Lists files Telegram Desktop currently has open for writing, i.e. active
# downloads. Telegram exposes no download API and writes straight into the
# final target path with no temp extension, so this is inferred from /proc:
# an O_WRONLY fd pointing at a real file, outside Telegram's own data dir
# (which also holds an O_WRONLY log.txt fd that isn't a download).
# Prints {"telegramRunning": bool, "downloads": [{path, name, size}, ...]}.
import glob
import json
import os

EXCLUDE_PREFIX = os.path.expanduser("~/.local/share/TelegramDesktop")
O_ACCMODE = 0o3
O_WRONLY = 0o1


def telegram_pids():
    pids = []
    for comm_path in glob.glob("/proc/[0-9]*/comm"):
        try:
            with open(comm_path) as f:
                comm = f.read().strip()
        except OSError:
            continue
        if comm == "Telegram":
            pids.append(comm_path.split("/")[2])
    return pids


def active_writes(pid):
    fd_dir = f"/proc/{pid}/fd"
    try:
        fds = os.listdir(fd_dir)
    except OSError:
        return []

    results = []
    for fd in fds:
        try:
            target = os.readlink(f"{fd_dir}/{fd}")
        except OSError:
            continue
        if not target.startswith("/") or target.startswith(EXCLUDE_PREFIX):
            continue

        try:
            with open(f"/proc/{pid}/fdinfo/{fd}") as f:
                info = f.read()
        except OSError:
            continue
        flags = None
        for line in info.splitlines():
            if line.startswith("flags:"):
                flags = int(line.split(":", 1)[1].strip(), 8)
                break
        if flags is None or (flags & O_ACCMODE) != O_WRONLY:
            continue

        try:
            size = os.path.getsize(target)
        except OSError:
            continue

        results.append({"path": target, "name": os.path.basename(target), "size": size})
    return results


def main():
    pids = telegram_pids()
    rows = {}
    for pid in pids:
        for row in active_writes(pid):
            rows[row["path"]] = row
    print(json.dumps({"telegramRunning": bool(pids), "downloads": list(rows.values())}))


if __name__ == "__main__":
    main()
