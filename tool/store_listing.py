"""Updates the Microsoft Store listing: text and screenshots.

    python tool/store_listing.py [--dry]

Creates a submission (a copy of the last published one, same package),
replaces the en-gb description, features, release notes and screenshots
with those in store/microsoft-listing.json and store/screenshots-windows,
then commits it for certification. --dry stops before committing and deletes
the draft. Credentials come from %USERPROFILE%/.ournet-signing/msstore.json,
as for tool/publish-store.ps1. The Store takes one submission at a time.
"""

import io
import json
import os
import sys
import time
import zipfile
from pathlib import Path

import requests

ROOT = Path(__file__).resolve().parent.parent
APP = "9N6P4X13QG9M"
API = f"https://manage.devcenter.microsoft.com/v1.0/my/applications/{APP}"
LANGUAGE = "en-gb"


def token():
    cred = json.loads((Path.home() / ".ournet-signing" / "msstore.json").read_text())
    r = requests.post(
        f"https://login.microsoftonline.com/{cred['tenantId']}/oauth2/token",
        data={
            "grant_type": "client_credentials",
            "client_id": cred["clientId"],
            "client_secret": cred["clientSecret"],
            "resource": "https://manage.devcenter.microsoft.com",
        },
        timeout=30,
    )
    r.raise_for_status()
    return r.json()["access_token"]


def main(dry):
    listing = json.loads((ROOT / "store" / "microsoft-listing.json").read_text(encoding="utf8"))
    shots = sorted((ROOT / "store" / "screenshots-windows").glob("*.png"))
    s = requests.Session()
    s.headers["Authorization"] = f"Bearer {token()}"

    app = s.get(API, timeout=30)
    app.raise_for_status()
    if "pendingApplicationSubmission" in app.json():
        sys.exit("A submission is already pending; publish or delete it first.")

    r = s.post(f"{API}/submissions", timeout=60)
    r.raise_for_status()
    sub = r.json()
    sid = sub["id"]
    print("Draft submission", sid)

    base = sub["listings"][LANGUAGE]["baseListing"]
    base["description"] = listing["description"]
    base["features"] = listing["features"]
    base["releaseNotes"] = listing["releaseNotes"]
    if "shortDescription" in listing:
        base["shortDescription"] = listing["shortDescription"]
    images = [i for i in base.get("images", []) if i["imageType"] != "Screenshot"]
    for old in base.get("images", []):
        if old["imageType"] == "Screenshot":
            images.append({**old, "fileStatus": "PendingDelete"})
    for shot in shots:
        images.append(
            {
                "fileName": shot.name,
                "fileStatus": "PendingUpload",
                "imageType": "Screenshot",
                "description": shot.stem.split("-", 1)[1].replace("-", " "),
            }
        )
    base["images"] = images

    r = s.put(f"{API}/submissions/{sid}", json=sub, timeout=60)
    if not r.ok:
        print(r.text)
        r.raise_for_status()

    archive = io.BytesIO()
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
        for shot in shots:
            z.write(shot, shot.name)
    up = requests.put(
        sub["fileUploadUrl"].replace("+", "%2B"),
        data=archive.getvalue(),
        headers={"x-ms-blob-type": "BlockBlob"},
        timeout=300,
    )
    up.raise_for_status()
    print(f"Uploaded {len(shots)} screenshots")

    if dry:
        s.delete(f"{API}/submissions/{sid}", timeout=60).raise_for_status()
        print("Dry run: draft deleted.")
        return
    s.post(f"{API}/submissions/{sid}/commit", timeout=60).raise_for_status()
    for _ in range(60):
        status = s.get(f"{API}/submissions/{sid}/status", timeout=60).json()
        state = status["status"]
        if state != "CommitStarted":
            break
        time.sleep(10)
    print("Status:", state)
    for problem in status.get("statusDetails", {}).get("errors", []):
        print("  error:", problem)
    if state == "CommitFailed":
        sys.exit(1)


if __name__ == "__main__":
    main("--dry" in sys.argv[1:])
