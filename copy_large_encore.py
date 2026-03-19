#!/usr/bin/env python3.11
"""
copy_large_encore.py
Copies files >= 5 GiB from occ-prd-00-a1g-data-app-s3-data-encore
to dp-prd-00-aog-data-dcc-s3-dcopyraw (all input/ prefixes except mct and tce).

Uses boto3 TransferManager which handles multipart copy automatically,
working around the S3 Batch Ops 5 GiB single-CopyObject limit.

Credentials are refreshed every 45 minutes to avoid session expiry.
"""
import boto3
import concurrent.futures
import csv
import os
import threading
import time
from boto3.s3.transfer import TransferConfig
from datetime import datetime

SOURCE_BUCKET        = "occ-prd-00-a1g-data-app-s3-data-encore"
DEST_BUCKET          = "dp-prd-00-aog-data-dcc-s3-dcopyraw"
ROLE_ARN             = "arn:aws:iam::920373001042:role/S3BatchOperations-COPY-encore"
REGION               = "us-east-2"
PROFILE              = "1042"
SIZE_THRESHOLD       = 5368709120    # 5 GiB — copy files >= this size
MAX_WORKERS          = 16            # parallel file copies
LOG_FILE             = "copy_large_encore.csv"
CRED_REFRESH_INTERVAL = 45 * 60     # refresh assumed-role creds every 45 min

TRANSFER_CONFIG = TransferConfig(
    multipart_threshold=512 * 1024 * 1024,
    multipart_chunksize=512 * 1024 * 1024,
    max_concurrency=10,
    use_threads=True,
)

# --- Credential refresh ---

_cred_lock   = threading.Lock()
_s3_client   = None
_cred_time   = 0

def _refresh_client():
    global _s3_client, _cred_time
    base  = boto3.Session(profile_name=PROFILE)
    sts   = base.client("sts", region_name=REGION)
    creds = sts.assume_role(RoleArn=ROLE_ARN, RoleSessionName="large-copy")["Credentials"]
    _s3_client = boto3.client(
        "s3", region_name=REGION,
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
    )
    _cred_time = time.time()
    print(f"[{_ts()}] Credentials refreshed")

def get_s3():
    global _s3_client, _cred_time
    with _cred_lock:
        if _s3_client is None or (time.time() - _cred_time) > CRED_REFRESH_INTERVAL:
            _refresh_client()
        return _s3_client

def _ts():
    return datetime.now().strftime("%H:%M:%S")

# --- Copy logic ---

def list_large_objects(prefix):
    s3        = get_s3()
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=SOURCE_BUCKET, Prefix=prefix):
        for obj in page.get("Contents", []):
            if obj["Size"] >= SIZE_THRESHOLD:
                yield obj["Key"], obj["Size"]

def copy_file(key, size):
    s3 = get_s3()
    s3.copy(
        {"Bucket": SOURCE_BUCKET, "Key": key},
        DEST_BUCKET,
        key,
        Config=TRANSFER_CONFIG,
        ExtraArgs={"StorageClass": "STANDARD", "MetadataDirective": "COPY"},
    )

def main():
    get_s3()
    s3 = get_s3()

    print(f"[{_ts()}] Listing date folders...")
    date_folders = []
    pager = s3.get_paginator("list_objects_v2")
    for page in pager.paginate(Bucket=SOURCE_BUCKET, Delimiter="/"):
        for p in page.get("CommonPrefixes", []):
            date_folders.append(p["Prefix"])
    print(f"[{_ts()}] Found {len(date_folders)} date folders")

    # Discover folders dynamically, excluding mct and tce
    EXCLUDE = {"mct", "tce"}
    folders_set = set()
    for date_folder in date_folders:
        resp = s3.list_objects_v2(Bucket=SOURCE_BUCKET, Prefix=f"{date_folder}input/", Delimiter="/")
        for p in resp.get("CommonPrefixes", []):
            folder = p["Prefix"].rstrip("/").split("/")[-1]
            if folder not in EXCLUDE:
                folders_set.add(folder)
    FOLDERS = list(folders_set)
    print(f"[{_ts()}] Found {len(FOLDERS)} folders to process: {FOLDERS}")

    print(f"[{_ts()}] Scanning for objects >= {SIZE_THRESHOLD/1024**3:.0f} GiB...")
    work_items = []
    for date_folder in date_folders:
        for folder in FOLDERS:
            prefix = f"{date_folder}input/{folder}/"
            for key, sz in list_large_objects(prefix):
                work_items.append((key, sz))

    # Skip files already successfully copied (resume support)
    already_done = set()
    if os.path.exists(LOG_FILE):
        with open(LOG_FILE, newline="") as f:
            for row in csv.reader(f):
                if len(row) >= 3 and row[2] == "ok":
                    already_done.add(row[0])
    if already_done:
        before     = len(work_items)
        work_items = [(k, s) for k, s in work_items if k not in already_done]
        print(f"[{_ts()}] Skipping {before - len(work_items)} already-completed files")

    total_files   = len(work_items)
    total_bytes   = sum(sz for _, sz in work_items)
    already_count = len(already_done)
    grand_total   = total_files + already_count
    print(f"[{_ts()}] Found {total_files} large files to copy ({total_bytes/1024**4:.2f} TiB)")

    # write meta file so dashboard can show totals
    with open(LOG_FILE + ".meta", "w") as mf:
        mf.write(f"{grand_total},{already_count},{total_bytes}\n")

    if total_files == 0:
        print("Nothing to copy.")
        return

    done       = 0
    failed     = 0
    bytes_done = 0
    start      = time.time()

    with open(LOG_FILE, "a", newline="") as logf:
        writer = csv.writer(logf)

        def do_copy(item):
            key, sz = item
            t0 = time.time()
            try:
                copy_file(key, sz)
                return key, sz, None, time.time() - t0
            except Exception as e:
                return key, sz, str(e), time.time() - t0

        with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
            futures = {pool.submit(do_copy, item): item for item in work_items}
            for future in concurrent.futures.as_completed(futures):
                key, sz, err, dur = future.result()
                if err:
                    failed += 1
                    print(f"[{_ts()}] FAIL [{done+failed}/{total_files}] {key}: {err[:120]}")
                    writer.writerow([key, sz, "failed", err])
                else:
                    done       += 1
                    bytes_done += sz
                    elapsed     = time.time() - start
                    rate        = bytes_done / elapsed / 1024**2 if elapsed > 0 else 0
                    eta_h       = (total_bytes - bytes_done) / (bytes_done / elapsed) / 3600 if bytes_done > 0 else 0
                    print(f"[{_ts()}] OK [{done}/{total_files}] {key} ({sz/1024**3:.1f} GiB in {dur:.0f}s) | avg {rate:.0f} MB/s | ETA {eta_h:.1f}h")
                    writer.writerow([key, sz, "ok", ""])
                logf.flush()

    elapsed = time.time() - start
    print(f"\n[{_ts()}] === Done === Succeeded:{done}  Failed:{failed}  Time:{elapsed/3600:.1f}h")

if __name__ == "__main__":
    main()