#!/bin/bash
# Lints the Dockerfile, shell scripts and workflows.
# Usage: tests/lint.sh
set -u
cd "$(dirname "$0")/.." || exit 1

status=0

echo "hadolint"
docker run --rm -i -v "$PWD/.hadolint.yaml:/.config/hadolint.yaml:ro" \
    hadolint/hadolint:v2.15.1@sha256:32dac94127fd60b7b7e3fbfc65e1383b9b5e25c9bfd7b8536de7a539fe68a12d \
    < drupal/Dockerfile || status=1

echo "shellcheck"
docker run --rm -v "$PWD:/mnt:ro" -w /mnt \
    koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d \
    -x --severity=warning drupal/docker-drupal-start tests/*.sh || status=1

echo "actionlint"
docker run --rm -v "$PWD:/repo:ro" -w /repo \
    rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667 \
    -no-color || status=1

[ "$status" = 0 ] && echo "Lint passed"
exit "$status"
