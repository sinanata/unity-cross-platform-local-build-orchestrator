#!/usr/bin/env python3
"""
Non-destructive Play Publishing API auth check.

Opens an edit against a package (no upload), prints the edit ID, then
deletes it. Confirms the full chain: key parses, Google accepts it, and
the service account has app-level permission to modify releases.

Usage:
    python check_play_auth.py --service-account key.json \
        --package com.example.yourgame

Part of https://github.com/sinanata/unity-cross-platform-local-build-orchestrator
"""

from __future__ import annotations

import argparse
import sys
import warnings
from pathlib import Path

# Silence "Python 3.9 past end-of-life" FutureWarnings from google-* packages.
warnings.filterwarnings("ignore", category=FutureWarning)

try:
    from google.oauth2 import service_account
    from googleapiclient.discovery import build
    from googleapiclient.errors import HttpError
except ImportError:
    sys.stderr.write(
        "ERROR: missing deps.\n"
        "       pip install google-auth google-api-python-client\n"
    )
    sys.exit(1)

SCOPES = ["https://www.googleapis.com/auth/androidpublisher"]


def diagnose(e: HttpError) -> None:
    status = getattr(e, "status_code", None) or getattr(e.resp, "status", None)
    body = (e.content.decode("utf-8", "replace") if isinstance(e.content, bytes) else str(e.content or "")).lower()
    sys.stderr.write(f"HTTP {status}: {e}\n")

    if "service_disabled" in body or "has not been used in project" in body:
        sys.stderr.write(
            "\nLikely cause: the Google Play Android Developer API is not enabled\n"
            "on the Cloud project that owns this service account.\n"
            "  Fix: https://console.developers.google.com/apis/library/androidpublisher.googleapis.com\n"
            "       -> select YOUR project -> Enable. Wait ~1 minute.\n"
            "  See docs/CREDENTIALS.md section 5d for the step-by-step.\n"
        )
        return

    if status == 401:
        sys.stderr.write(
            "\nLikely cause: JSON key rejected.\n"
            "  - Check the file was saved as JSON (not the key ID alone).\n"
            "  - Confirm the key is still active in Google Cloud Console.\n"
        )
    elif status == 403:
        sys.stderr.write(
            "\nLikely cause: auth works, but the service account lacks app access.\n"
            "  Fix checklist:\n"
            "  1. Play Console > Setup > API access -> link to your Cloud project.\n"
            "  2. Play Console > Users and permissions -> invite the service-account email.\n"
            "  3. Grant it app-level access to your app (not just org-wide).\n"
            "     Minimum: 'Release to testing tracks' + 'View app information'.\n"
            "  See docs/CREDENTIALS.md section 5c for the step-by-step.\n"
        )
    elif status == 404:
        sys.stderr.write(
            "\nLikely cause: package name unknown in this Play Console.\n"
            "  - Confirm the app exists in Play Console and the package name matches.\n"
            "  - Confirm Play Console is linked to the same Google Cloud project.\n"
        )


def main() -> int:
    ap = argparse.ArgumentParser(description="Play API auth smoke test.")
    ap.add_argument("--service-account", required=True, type=Path)
    ap.add_argument("--package",         required=True)
    args = ap.parse_args()

    if not args.service_account.is_file():
        sys.stderr.write(f"ERROR: JSON key not found: {args.service_account}\n")
        return 1

    try:
        creds = service_account.Credentials.from_service_account_file(
            str(args.service_account), scopes=SCOPES
        )
    except Exception as e:
        sys.stderr.write(f"ERROR: could not load key file: {e}\n")
        return 1

    print(f"service account: {creds.service_account_email}")
    print(f"package:         {args.package}")

    service = build("androidpublisher", "v3", credentials=creds, cache_discovery=False)
    edits = service.edits()

    try:
        edit = edits.insert(packageName=args.package, body={}).execute()
    except HttpError as e:
        diagnose(e)
        return 2

    edit_id = edit["id"]
    print(f"opened edit:     {edit_id}")

    try:
        edits.delete(packageName=args.package, editId=edit_id).execute()
        print("deleted edit:    ok")
    except HttpError as e:
        sys.stderr.write(f"WARN: could not delete edit {edit_id}: {e}\n")
        sys.stderr.write("     The edit will auto-expire; no data was published.\n")

    print("")
    print("RESULT: Play Publishing API auth + app-level permissions OK.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
