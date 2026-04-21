#!/usr/bin/env python3
"""
Upload an AAB to the Google Play Publishing API on a given track.

Usage:
    python upload_play.py --service-account key.json --aab app.aab \
        --package com.example.yourgame --track internal \
        [--release-notes "Short text"]

Prerequisites:
    pip install google-auth google-api-python-client

The service account must have been granted app-level access in
Play Console > Users and permissions (not just org-level). See
docs/CREDENTIALS.md section 5 for the full setup walkthrough.

Part of https://github.com/sinanata/unity-cross-platform-local-build-orchestrator
Originally built for https://leapoflegends.com
"""

from __future__ import annotations

import argparse
import os
import sys
import warnings
from pathlib import Path

warnings.filterwarnings("ignore", category=FutureWarning)

try:
    from google.oauth2 import service_account
    from googleapiclient.discovery import build
    from googleapiclient.http import MediaFileUpload
    from googleapiclient.errors import HttpError
except ImportError:
    sys.stderr.write(
        "ERROR: Missing dependencies.\n"
        "       Run: pip install google-auth google-api-python-client\n"
    )
    sys.exit(1)


SCOPES = ["https://www.googleapis.com/auth/androidpublisher"]


def _is_draft_app_error(e: HttpError) -> bool:
    # Play returns 400 with message "Only releases with status draft may be
    # created on draft app." until the app has been approved through its
    # first store review. Detect and silently fall back.
    msg = str(e).lower()
    return "draft app" in msg


def _set_track_release(edits, package: str, edit_id: str, track: str,
                       release: dict) -> None:
    edits.tracks().update(
        packageName=package,
        editId=edit_id,
        track=track,
        body={"track": track, "releases": [release]},
    ).execute()


def upload(service_account_path: Path, aab_path: Path, package: str,
           track: str, release_notes: str | None = None) -> int:
    creds = service_account.Credentials.from_service_account_file(
        str(service_account_path), scopes=SCOPES
    )
    service = build("androidpublisher", "v3", credentials=creds, cache_discovery=False)
    edits = service.edits()

    edit = edits.insert(packageName=package, body={}).execute()
    edit_id = edit["id"]
    print(f"  Edit id: {edit_id}", flush=True)

    try:
        media = MediaFileUpload(
            str(aab_path),
            mimetype="application/octet-stream",
            resumable=True,
            chunksize=20 * 1024 * 1024,
        )
        req = edits.bundles().upload(
            packageName=package,
            editId=edit_id,
            media_body=media,
        )
        response = None
        last_pct = -10
        while response is None:
            status, response = req.next_chunk()
            if status:
                pct = int(status.progress() * 100)
                if pct >= last_pct + 10:
                    print(f"  Upload progress: {pct}%", flush=True)
                    last_pct = pct
        version_code = int(response["versionCode"])
        print(f"  Uploaded versionCode={version_code}", flush=True)

        release = {
            "versionCodes": [str(version_code)],
            "status": "completed",
        }
        if release_notes:
            release["releaseNotes"] = [
                {"language": "en-US", "text": release_notes[:500]},
            ]
        _set_track_release(edits, package, edit_id, track, release)

        try:
            edits.commit(packageName=package, editId=edit_id).execute()
            print(f"  Assigned versionCode {version_code} to '{track}' "
                  "and committed (live).", flush=True)
        except HttpError as commit_err:
            if not _is_draft_app_error(commit_err):
                raise
            # Retry: same edit, same uploaded bundle, draft status.
            print("  ! App is still in draft state on Play Console — "
                  "Play rejects 'completed' releases until first review.",
                  flush=True)
            print("  Retrying commit with release.status='draft' "
                  "(no re-upload).", flush=True)
            release["status"] = "draft"
            _set_track_release(edits, package, edit_id, track, release)
            edits.commit(packageName=package, editId=edit_id).execute()
            print(f"  Committed DRAFT release: versionCode {version_code} "
                  f"on '{track}' track.", flush=True)
            print("  MANUAL STEP: Play Console > Testing > Internal testing "
                  "> Releases > promote the draft to roll out to testers.",
                  flush=True)
        return version_code

    except HttpError as e:
        sys.stderr.write(f"ERROR: Play API HTTP error: {e}\n")
        try:
            edits.delete(packageName=package, editId=edit_id).execute()
        except Exception:
            pass
        raise


def main() -> int:
    ap = argparse.ArgumentParser(description="Upload an AAB to Google Play.")
    ap.add_argument("--service-account", required=True, type=Path,
                    help="Path to the service-account JSON key file.")
    ap.add_argument("--aab", required=True, type=Path,
                    help="Path to the .aab file to upload.")
    ap.add_argument("--package", required=True,
                    help="Android package name, e.g. com.example.yourgame")
    ap.add_argument("--track", default="internal",
                    help="Release track: internal | alpha | beta | production (default: internal)")
    ap.add_argument("--release-notes", default=None,
                    help="Optional release notes (first 500 chars sent as en-US).")
    args = ap.parse_args()

    for label, p in (("service account", args.service_account), ("AAB", args.aab)):
        if not p.is_file():
            sys.stderr.write(f"ERROR: {label} file not found: {p}\n")
            return 1

    size_mb = args.aab.stat().st_size / (1024 * 1024)
    print(f"Uploading {args.aab.name} ({size_mb:.1f} MB) -> {args.package} [{args.track}]",
          flush=True)
    try:
        upload(args.service_account, args.aab, args.package, args.track, args.release_notes)
    except HttpError:
        return 2
    except Exception as e:
        sys.stderr.write(f"ERROR: {e}\n")
        return 3
    print("Done.", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
