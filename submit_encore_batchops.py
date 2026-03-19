#!/usr/bin/env python3.11
import boto3
import time

ACCOUNT_ID    = "920373001042"
SOURCE_BUCKET = "occ-prd-00-a1g-data-app-s3-data-encore"
DEST_BUCKET   = "dp-prd-00-aog-data-dcc-s3-dcopyraw"
DEST_KMS_KEY  = "arn:aws:kms:us-east-2:920373001042:key/20fbeb64-caf1-472b-a79a-3427bf700ea1"
ROLE_ARN      = "arn:aws:iam::920373001042:role/S3BatchOperations-COPY-encore"
REPORT_BUCKET = "dp-prd-00-aog-data-dcc-s3-dcopyintegration"
REPORT_PREFIX = "batch-ops/reports"
REGION        = "us-east-2"
PROFILE       = "1042"

session      = boto3.Session(profile_name=PROFILE)
s3_client    = session.client("s3", region_name=REGION)
batch_client = session.client("s3control", region_name=REGION)

print("Fetching date folders from source bucket...")
date_folders = []
paginator = s3_client.get_paginator("list_objects_v2")
pages = paginator.paginate(Bucket=SOURCE_BUCKET, Delimiter="/")
for page in pages:
    for prefix in page.get("CommonPrefixes", []):
        date_folders.append(prefix["Prefix"])
print(f"Found {len(date_folders)} date folders")

# Discover folders dynamically, excluding mct and tce
EXCLUDE = {"mct", "tce"}
folders_set = set()
for date_folder in date_folders:
    resp = s3_client.list_objects_v2(Bucket=SOURCE_BUCKET, Prefix=f"{date_folder}input/", Delimiter="/")
    for p in resp.get("CommonPrefixes", []):
        parts = p["Prefix"].rstrip("/").split("/")
        folder = parts[2]  # e.g. "20230103/input/mct/" -> parts[2] = "mct"
        if folder not in EXCLUDE:
            folders_set.add(folder)
FOLDERS = list(folders_set)
print(f"Found {len(FOLDERS)} folders to process: {FOLDERS}")

submitted = 0
failed    = 0
skipped   = 0

for date_folder in date_folders:
    for folder in FOLDERS:
        prefix = f"{date_folder}input/{folder}/"

        # Check if prefix exists in source
        check = s3_client.list_objects_v2(
            Bucket=SOURCE_BUCKET,
            Prefix=prefix,
            MaxKeys=1
        )
        if check.get("KeyCount", 0) == 0:
            print(f"  SKIP (empty): {prefix}")
            skipped += 1
            continue

        label = f"{date_folder.strip('/')}_{folder}"
        print(f"Submitting: {prefix}")

        try:
            response = batch_client.create_job(
                AccountId=ACCOUNT_ID,
                ConfirmationRequired=False,
                Operation={
                    "S3PutObjectCopy": {
                        "TargetResource": f"arn:aws:s3:::{DEST_BUCKET}",
                        "StorageClass": "STANDARD",
                        "MetadataDirective": "COPY"
                    }
                },
                Report={
                    "Bucket": f"arn:aws:s3:::{REPORT_BUCKET}",
                    "Prefix": f"{REPORT_PREFIX}/{label}",
                    "Format": "Report_CSV_20180820",
                    "Enabled": True,
                    "ReportScope": "AllTasks",
                    "ExpectedBucketOwner": ACCOUNT_ID
                },
                ManifestGenerator={
                    "S3JobManifestGenerator": {
                        "SourceBucket": f"arn:aws:s3:::{SOURCE_BUCKET}",
                        "EnableManifestOutput": False,
                        "Filter": {
                            "KeyNameConstraint": {
                                "MatchAnyPrefix": [prefix]
                            },
                            "ObjectSizeLessThanBytes": 5368709120
                        }
                    }
                },
                Description=f"Copy {prefix}",
                Priority=10,
                RoleArn=ROLE_ARN
            )
            job_id = response["JobId"]
            print(f"  OK - Job ID: {job_id}")
            with open("encore_submitted_jobs.csv", "a") as f:
                f.write(f"{prefix},{job_id}\n")
            submitted += 1

        except Exception as e:
            print(f"  FAILED - {str(e)}")
            failed += 1

        time.sleep(0.5)

print(f"\n==============================")
print(f"Submitted: {submitted}")
print(f"Skipped (empty): {skipped}")
print(f"Failed: {failed}")
print(f"==============================")