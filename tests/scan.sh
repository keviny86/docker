#!/bin/bash
# Fails on critical vulnerabilities that already have a fix. Unfixed ones
# can't be acted on, so they don't fail the build.
# Usage: tests/scan.sh IMAGE
set -u

docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
    aquasec/trivy:0.75.0@sha256:af6acf9a6b85dfe389a1941505c0ce9efef52a4719635e1a962f022a3d855daa \
    image --quiet --scanners vuln --severity CRITICAL --ignore-unfixed --exit-code 1 "$1"
