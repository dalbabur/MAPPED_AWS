#!/usr/bin/env bash
set -euo pipefail

function usage() {
  cat <<EOF
Usage: $0 METADATA_FILE [--column N] [--bucket NAME] [--jobs N]

Pre-flight check: confirm every Run accession in METADATA_FILE actually exists in
s3://<bucket>/sra/<RUN>/<RUN> before running the full download pipeline (mirrors the
exact object SRA_FASTQ_AWSODP fetches -- see 2_download_fastq/modules/sra_fastq_awsodp).

Arguments:
  METADATA_FILE   Tab-separated metadata file with a header row (default: all_kt2440_samples_metadata.txt)

Options:
  --column N      1-based tab column holding the Run accession (default: 4)
  --bucket NAME   S3 bucket name, no s3:// prefix (default: sra-pub-run-odp)
  --jobs N        Parallel S3 checks (default: 20)
  -h, --help      Show this help message and exit

Output:
  found_in_s3.txt     -- accessions confirmed present
  missing_from_s3.txt -- accessions NOT found (fall back to ENA for these)

Requires: AWS CLI (anonymous/no-sign-request access, no credentials needed)
EOF
}

METADATA_FILE=""
COLUMN=4
BUCKET="sra-pub-run-odp"
JOBS=20

while [[ $# -gt 0 ]]; do
  case "$1" in
    --column) COLUMN="$2"; shift 2 ;;
    --bucket) BUCKET="$2"; shift 2 ;;
    --jobs)   JOBS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      if [[ -z "$METADATA_FILE" ]]; then METADATA_FILE="$1"; shift
      else echo "Unknown argument: $1"; usage; exit 1; fi
      ;;
  esac
done
METADATA_FILE="${METADATA_FILE:-all_kt2440_samples_metadata.txt}"

if [[ ! -f "$METADATA_FILE" ]]; then
  echo "Error: metadata file not found: $METADATA_FILE"
  exit 1
fi

> found_in_s3.txt
> missing_from_s3.txt

_RUN_LIST="$(mktemp)"
trap 'rm -f "$_RUN_LIST"' EXIT

tail -n +2 "$METADATA_FILE" | cut -f"${COLUMN}" | grep -v '^$' | sort -u > "$_RUN_LIST"

TOTAL=$(wc -l < "$_RUN_LIST")
echo "Checking $TOTAL unique accessions against s3://${BUCKET}/sra/<RUN>/<RUN> ..."

check_one() {
  local run="$1"
  if aws s3api head-object --bucket "$BUCKET" --key "sra/${run}/${run}" --no-sign-request >/dev/null 2>&1; then
    echo "$run" >> found_in_s3.txt
  else
    echo "$run" >> missing_from_s3.txt
  fi
}
export -f check_one
export BUCKET

xargs -P "$JOBS" -I{} bash -c 'check_one "$@"' _ {} < "$_RUN_LIST"

FOUND=$(wc -l < found_in_s3.txt)
MISSING=$(wc -l < missing_from_s3.txt)
echo ""
echo "Done: $FOUND found, $MISSING missing."
if [[ "$MISSING" -gt 0 ]]; then
  echo "See missing_from_s3.txt -- try these via ENA instead:"
  echo "  https://www.ebi.ac.uk/ena/portal/api/filereport?accession=<RUN>&result=read_run&fields=fastq_ftp"
fi
