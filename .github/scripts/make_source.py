#!/usr/bin/env python3
"""Write the SideStore source (s.json) and its landing page (index.html)."""
import datetime as dt
import json
import os

repo = os.environ["GITHUB_REPOSITORY"]
owner, name = repo.split("/")
version, tag = os.environ["VERSION"], os.environ["TAG"]
pages = f"https://{owner.lower()}.github.io/{name}"
date = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
description = ("Sends the iPad's screen to a PC over Bluetooth LE while you use any app. "
               "Start the broadcast once; the PC asks for screenshots with pc/blueshot.py.")

source = {
    "name": "BlueShot",
    "identifier": f"io.github.{owner.lower()}.blueshot",
    "iconURL": f"{pages}/icon.png",
    "website": f"https://github.com/{repo}",
    "tintColor": "145AE6",
    "apps": [{
        "name": "BlueShot",
        "bundleIdentifier": "de.toemeler.BlueShot",
        "developerName": owner,
        "localizedDescription": description,
        "iconURL": f"{pages}/icon.png",
        "tintColor": "145AE6",
        "versions": [{
            "version": version,
            "date": date,
            "downloadURL": f"https://github.com/{repo}/releases/download/{tag}/BlueShot.ipa",
            "size": int(os.environ["SIZE"]),
            "minOSVersion": "16.0",
        }],
    }],
    "news": [],
}
with open("s.json", "w") as fh:
    json.dump(source, fh, indent=2)

with open("index.html", "w") as fh:
    fh.write(f"""<!doctype html>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>BlueShot</title>
<style>body{{font:16px/1.6 system-ui,sans-serif;max-width:32rem;margin:3rem auto;padding:0 1rem}}
a.b{{display:inline-block;background:#145AE6;color:#fff;padding:.7em 1.2em;border-radius:.6em;text-decoration:none;font-weight:700}}
code{{word-break:break-all}}</style>
<h1>BlueShot {version}</h1>
<p>{description}</p>
<p><a class="b" href="sidestore://source?url={pages}/s.json">Add to SideStore</a></p>
<p>Source URL: <code>{pages}/s.json</code></p>
<p><a href="https://github.com/{repo}">Code and releases</a></p>
""")
