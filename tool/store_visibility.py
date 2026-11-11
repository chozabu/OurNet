"""Sets the Microsoft Store discoverability of OurNet.

    python tool/store_visibility.py public|private [--dry]

Creates a submission (a copy of the last published one, same package and
listing), changes only its visibility, then commits it for certification.
public: shown in Store search. private: available by direct link only.
--dry stops before committing and deletes the draft. Credentials and the
one-submission-at-a-time rule are as for tool/store_listing.py.
"""

import sys
import time

import requests

import store_listing as sl

VALUES = {"public": "Public", "private": "Private"}


def main(value, dry):
    s = requests.Session()
    s.headers["Authorization"] = f"Bearer {sl.token()}"
    app = s.get(sl.API, timeout=30)
    app.raise_for_status()
    if "pendingApplicationSubmission" in app.json():
        sys.exit("A submission is already pending; publish or delete it first.")

    r = s.post(f"{sl.API}/submissions", timeout=60)
    r.raise_for_status()
    sub = r.json()
    sid = sub["id"]
    print("Draft submission", sid, "visibility was", sub.get("visibility"))
    sub["visibility"] = value
    r = s.put(f"{sl.API}/submissions/{sid}", json=sub, timeout=60)
    if not r.ok:
        print(r.text)
        r.raise_for_status()
    print("Draft visibility now", r.json().get("visibility"))

    if dry:
        s.delete(f"{sl.API}/submissions/{sid}", timeout=60).raise_for_status()
        print("Dry run: draft deleted.")
        return
    s.post(f"{sl.API}/submissions/{sid}/commit", timeout=60).raise_for_status()
    for _ in range(60):
        status = s.get(f"{sl.API}/submissions/{sid}/status", timeout=60).json()
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
    args = sys.argv[1:]
    if not args or args[0] not in VALUES:
        sys.exit(__doc__)
    main(VALUES[args[0]], "--dry" in args[1:])
