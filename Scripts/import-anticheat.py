#!/usr/bin/env python3
"""Imports highball-db's Mac-aware anti-cheat map into Data/anticheat/.
The map derives from Are We Anti-Cheat Yet? (MIT); its licence notice is copied along, as MIT requires.
Usage: python3 -I Scripts/import-anticheat.py [anticheat.json anticheat.LICENSE]
Without arguments it downloads both from the pinned highball-db commit below. Then run Scripts/embed-data.py."""
import json, os, sys, urllib.request

COMMIT = "32919c04751d2e9d18a5631d7fd5a2fdb6f8798b"
BASE = f"https://raw.githubusercontent.com/gauthierpiarrette/highball-db/{COMMIT}/db/"
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out = os.path.join(root, "Data", "anticheat")

def read(arg, name):
    if arg:
        with open(arg, "rb") as f:
            return f.read()
    with urllib.request.urlopen(BASE + name, timeout=60) as r:
        return r.read()

args = sys.argv[1:] + [None, None]
data = json.loads(read(args[0], "anticheat.json"))
notice = read(args[1], "anticheat.LICENSE").decode("utf-8")

games = []
for gid, g in sorted(data["games"].items()):
    if g.get("macVerdict") not in ("blocked", "warning"):
        sys.exit(f"{gid}: unknown macVerdict {g.get('macVerdict')!r}")
    games.append({"id": gid, "title": g["title"], "antiCheats": g.get("anticheats") or [],
                  "linuxStatus": g.get("linuxStatus") or "Unknown", "steamAppID": g.get("steam_appid"),
                  "macVerdict": g["macVerdict"]})

os.makedirs(out, exist_ok=True)
with open(os.path.join(out, "anticheat.json"), "w", encoding="utf-8") as f:
    meta = {"source": "https://github.com/gauthierpiarrette/highball-db/blob/" + COMMIT + "/db/anticheat.json",
            "upstream": data.get("source"), "license": "MIT", "note": data.get("macNote")}
    f.write('{"meta": ' + json.dumps(meta, ensure_ascii=False) + ',\n "games": [\n')
    f.write(",\n".join("  " + json.dumps(g, ensure_ascii=False) for g in games))
    f.write("\n]}\n")
with open(os.path.join(out, "LICENSE"), "w", encoding="utf-8") as f:
    f.write(notice)
print(f"{len(games)} games ({sum(g['macVerdict'] == 'blocked' for g in games)} blocked) -> {out}")
