#!/bin/bash
set -euo pipefail

# Build the reviewed remote graph. Sibling main clones must not override exact
# Package.swift revisions (including the declared capture and assistant products).
repo_name="${GITHUB_REPOSITORY##*/}"
run_root="${RUNNER_TEMP}/carnyx-package-ci/${repo_name}-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
repo_root="${run_root}/${repo_name}"
rm -rf "${run_root}"
mkdir -p "${repo_root}"
# Publish the cleanup root before archive/fetch preparation can fail.
echo "CI_RUN_ROOT=${run_root}" >> "${GITHUB_ENV}"
# Avoid carrying local SwiftPM mirrors, build products or untracked overrides.
git -C "${GITHUB_WORKSPACE}" archive HEAD | tar -x -C "${repo_root}"

{
  echo "CI_RUN_ROOT=${run_root}"
  echo "CI_REPO_ROOT=${repo_root}"
  echo "CI_SCRATCH_PATH=${run_root}/.build-ci"
  echo "CI_CACHE_PATH=${run_root}/.swiftpm-cache"
  echo "CI_CONFIG_PATH=${run_root}/.swiftpm-config"
  echo "CI_SECURITY_PATH=${run_root}/.swiftpm-security"
  # Reuse the runner's established SSH access without Keychain UI or global
  # Git configuration changes. Package manifests retain their HTTPS URLs.
  echo "GIT_CONFIG_COUNT=2"
  echo "GIT_CONFIG_KEY_0=url.git@github.com:.insteadOf"
  echo "GIT_CONFIG_VALUE_0=https://github.com/"
  echo "GIT_CONFIG_KEY_1=credential.helper"
  echo "GIT_CONFIG_VALUE_1="
  echo "GIT_TERMINAL_PROMPT=0"
  echo "GIT_SSH_COMMAND=ssh -o BatchMode=yes -o ConnectTimeout=15 -o ConnectionAttempts=1 -o ServerAliveInterval=30 -o ServerAliveCountMax=3"
} >> "${GITHUB_ENV}"
