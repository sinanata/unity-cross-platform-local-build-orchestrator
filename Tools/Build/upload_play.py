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
import socket
import ssl
import sys
import time
import warnings
from pathlib import Path

warnings.filterwarnings("ignore", category=FutureWarning)

try:
    import httplib2
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

# Per-chunk transport timeout (seconds). httplib2's default is 60s, which is
# tight for an 8 MB chunk on a slow uplink — a single stalled flush can trip
# the read timer mid-stream. 300s covers worst-case home-ISP upload speeds
# without making real failures linger.
HTTP_TIMEOUT_SEC = 300

# Resumable upload chunk size. Smaller = more round-trips but each one fits
# inside the timeout; bigger = fewer round-trips but more bytes at risk on
# any single retry. 8 MB is the sweet spot for ~100-200 MB AABs over typical
# residential uplinks.
CHUNK_SIZE = 8 * 1024 * 1024

# Retryable errors during resumable upload chunks. Socket / SSL timeouts and
# connection resets are normal for multi-minute uploads — Google's resumable
# protocol explicitly supports resuming after them, the script just has to
# call next_chunk() again on the same MediaFileUpload object.
_TRANSIENT_NETWORK_ERRORS = (
    socket.timeout,
    TimeoutError,
    ConnectionError,
    ConnectionResetError,
    ConnectionAbortedError,
    BrokenPipeError,
    ssl.SSLError,
    httplib2.HttpLib2Error,
    OSError,  # IncompleteRead, "EOF on stream", etc.
)


def _is_retryable_http_error(e: HttpError) -> bool:
    """5xx and 429 are retryable per Google's resumable-upload guidance."""
    status = getattr(getattr(e, "resp", None), "status", None)
    return status is not None and (status >= 500 or status == 429)


def _is_draft_app_error(e: HttpError) -> bool:
    # Play returns 400 with message "Only releases with status draft may be
    # created on draft app." until the app has been approved through its
    # first store review. Detect and silently fall back.
    msg = str(e).lower()
    return "draft app" in msg


def _is_changes_not_sent_error(e: HttpError) -> bool:
    # Play returns 400 "Changes cannot be sent for review automatically.
    # Please set the query parameter changesNotSentForReview to true."
    # when the edit contains metadata changes that must be reviewed
    # manually in the Play Console first — commonly triggered by pending
    # content-rating / data-safety / target-audience / Families updates.
    msg = str(e).lower()
    return "changesnotsentforreview" in msg


def _set_track_release(edits, package: str, edit_id: str, track: str,
                       release: dict) -> None:
    edits.tracks().update(
        packageName=package,
        editId=edit_id,
        track=track,
        body={"track": track, "releases": [release]},
    ).execute()


def _next_chunk_with_retry(req, max_attempts: int = 6):
    """Wrap MediaUploadRequest.next_chunk() with exponential backoff for
    transient network failures. Resumable uploads keep server-side state, so
    a retry just resumes from where the previous chunk left off — no need to
    restart the whole upload (the Python client tracks the resume URI on
    `req` itself).

    Returns (status, response) — same shape as next_chunk().
    """
    delay = 2.0
    for attempt in range(1, max_attempts + 1):
        try:
            return req.next_chunk()
        except HttpError as e:
            if not _is_retryable_http_error(e) or attempt == max_attempts:
                raise
            print(f"  ! Chunk failed with HTTP {e.resp.status} "
                  f"(attempt {attempt}/{max_attempts}); retrying in "
                  f"{delay:.0f}s...", flush=True)
        except _TRANSIENT_NETWORK_ERRORS as e:
            if attempt == max_attempts:
                raise
            print(f"  ! Chunk failed with {type(e).__name__}: {e} "
                  f"(attempt {attempt}/{max_attempts}); retrying in "
                  f"{delay:.0f}s...", flush=True)
        time.sleep(delay)
        delay = min(delay * 2, 60.0)
    raise RuntimeError("upload retry loop exited without success or exception")


def upload(service_account_path: Path, aab_path: Path, package: str,
           track: str, release_notes: str | None = None) -> int:
    creds = service_account.Credentials.from_service_account_file(
        str(service_account_path), scopes=SCOPES
    )
    # Override httplib2's default 60s socket timeout. googleapiclient builds
    # an internal Http() with the default unless we hand it one. Setting the
    # process-wide default socket timeout affects all sockets the auth
    # transport opens, which is exactly what we want for an upload-only run.
    socket.setdefaulttimeout(HTTP_TIMEOUT_SEC)

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
            chunksize=CHUNK_SIZE,
        )
        req = edits.bundles().upload(
            packageName=package,
            editId=edit_id,
            media_body=media,
        )
        response = None
        last_pct = -10
        while response is None:
            status, response = _next_chunk_with_retry(req)
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
            if _is_draft_app_error(commit_err):
                # Retry: same edit, same uploaded bundle, draft status.
                print("  ! App is still in draft state on Play Console — "
                      "Play rejects 'completed' releases until first review.",
                      flush=True)
                print("  Retrying commit with release.status='draft' "
                      "(no re-upload).", flush=True)
                release["status"] = "draft"
                _set_track_release(edits, package, edit_id, track, release)
                try:
                    edits.commit(packageName=package, editId=edit_id).execute()
                except HttpError as retry_err:
                    if not _is_changes_not_sent_error(retry_err):
                        raise
                    edits.commit(packageName=package, editId=edit_id,
                                 changesNotSentForReview=True).execute()
                print(f"  Committed DRAFT release: versionCode {version_code} "
                      f"on '{track}' track.", flush=True)
                print("  MANUAL STEP: Play Console > Testing > Internal testing "
                      "> Releases > promote the draft to roll out to testers.",
                      flush=True)
            elif _is_changes_not_sent_error(commit_err):
                # Pending store-listing changes (content rating, data safety,
                # target audience, Families declaration, etc.) prevent Play
                # from auto-submitting. Commit the binary anyway; user sends
                # for review manually once.
                print("  ! Play has pending metadata changes that require "
                      "manual review (content rating / data safety / target "
                      "audience / Families declaration).", flush=True)
                print("  Retrying commit with changesNotSentForReview=true "
                      "(binary uploads, release queued for manual send).",
                      flush=True)
                edits.commit(packageName=package, editId=edit_id,
                             changesNotSentForReview=True).execute()
                print(f"  Committed versionCode {version_code} on '{track}' "
                      "(pending manual send-for-review).", flush=True)
                print("  MANUAL STEP: Play Console > Publishing overview > "
                      "'Send N changes for review'. Subsequent uploads will "
                      "auto-submit again once those changes are approved.",
                      flush=True)
            else:
                raise
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
