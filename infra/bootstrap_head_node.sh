#!/bin/bash
# Sets up a MAPPED head node: Java, git, AWS CLI, Nextflow, this repo, and
# catalog/register_run.py's Python dependencies (AWS_SETUP.md section 9).
#
# Intended as EC2 user-data: pass via `--user-data file://infra/bootstrap_head_node.sh`
# on `aws ec2 run-instances` so a freshly launched instance is ready to run
# run_MAPPED.sh with no manual setup. Runs as root under cloud-init, hence the explicit
# `sudo -u ec2-user` below -- everything needs to end up owned by and runnable as
# ec2-user, matching how the instance is actually used afterwards (SSH/SSM sessions log
# in as ec2-user, not root).
#
# Every step here is idempotent, so this also doubles as a "resync this instance" script
# if it ever drifts from what a fresh launch would produce -- re-run it later (e.g. via
# `aws ssm send-command --document-name AWS-RunShellScript`) and it picks up repo changes
# via `git pull` rather than failing on an already-cloned directory.
#
# Assumes the repo is public, per AWS_SETUP.md section 9's note on plain `git clone`
# needing no credentials -- if it's private, replace REPO_URL below with a
# `https://<token>@github.com/...` fine-grained-PAT URL instead.

set -euo pipefail

REPO_URL="https://github.com/dalbabur/MAPPED_AWS.git"
REPO_DIR="/home/ec2-user/MAPPED_AWS"

echo "[bootstrap] Installing Java 17, git, aws-cli, python3-pip..."
yum install -y java-17-amazon-corretto-headless git aws-cli python3-pip

echo "[bootstrap] Installing Nextflow..."
if [ ! -x /usr/local/bin/nextflow ]; then
    (cd /tmp && curl -s https://get.nextflow.io | bash && mv nextflow /usr/local/bin/)
    chmod +x /usr/local/bin/nextflow
else
    echo "[bootstrap] Nextflow already installed, skipping."
fi

# SSM's AWS-RunShellScript document runs as root, but this repo is cloned as (and owned
# by) ec2-user below -- without this, every `git` command issued via SSM fails with
# "fatal: detected dubious ownership in repository", discovered live while automating
# deploys to an existing head node this way (see git history). --system, not --global:
# SSM's root session has no $HOME set, so `git config --global` has nowhere to write.
echo "[bootstrap] Configuring git safe.directory for root (SSM) access to ec2-user's clone..."
git config --system --add safe.directory "$REPO_DIR"

echo "[bootstrap] Cloning/updating $REPO_DIR..."
if [ -d "$REPO_DIR/.git" ]; then
    sudo -u ec2-user git -C "$REPO_DIR" pull
else
    sudo -u ec2-user git clone "$REPO_URL" "$REPO_DIR"
fi

echo "[bootstrap] Installing catalog/register_run.py's Python dependencies..."
sudo -u ec2-user pip3 install --user -r "$REPO_DIR/catalog/requirements.txt"

echo "[bootstrap] Done. nextflow -v: $(nextflow -v 2>&1 || echo 'not on PATH yet -- re-login or source /etc/profile')"
