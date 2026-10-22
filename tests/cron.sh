#!/bin/bash
# Checks drush cron scheduling and graceful shutdown, using a fake drush.
# Usage: tests/cron.sh IMAGE
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

image=$1
every_second='* * * * * * *'

# Fake drush: FAKE_MAINT is what state:get prints, FAKE_STATE_FAIL makes it
# fail, FAKE_SLEEP is how long cron takes and FAKE_FAIL makes cron fail.
fake_drush='#!/bin/bash
log=/var/www/html/log/drush.log
if [ "$1" = state:get ]; then
    if [ "${FAKE_STATE_FAIL:-0}" = 1 ]; then echo "fake state error" >&2; exit 1; fi
    echo "${FAKE_MAINT:-0}"
    exit 0
fi
echo "start user=$(id -un) home=$HOME foo=${FOO:-}" >> $log
trap "echo signal >> $log" TERM INT WINCH
sleep "${FAKE_SLEEP:-0}"
echo end >> $log
if [ "${FAKE_FAIL:-0}" = 1 ]; then echo "fake cron failure"; exit 1; fi
exit 0'

# site NAME DOCKER_RUN_ARGS...: starts a container with the fake drush and
# sets $site_name and $site_dir
site() {
    site_name=cron-$1-$$
    shift
    make_tmpdir
    site_dir=$tmpdir
    mkdir -p "$site_dir/vendor/bin" "$site_dir/web" "$site_dir/log"
    printf '%s\n' "$fake_drush" > "$site_dir/vendor/bin/drush"
    chmod 755 "$site_dir" "$site_dir/vendor/bin/drush"
    chmod 777 "$site_dir/log"
    start_container "$site_name" -v "$site_dir:/var/www/html" "$@" "$image"
}
drush_log() { cat "$1/log/drush.log" 2>/dev/null; }

echo "Startup validation"
out=$(docker run --rm -e DRUSH_CRON_SCHEDULE='*/0 * * * *' "$image" 2>&1); status=$?
expect_eq "invalid schedule exits with 1" 1 "$status"
expect_match "invalid schedule is reported" "Invalid DRUSH_CRON_SCHEDULE" "$out"
out=$(docker run --rm -e DRUSH_CRON_TIMEOUT=1h "$image" 2>&1); status=$?
expect_eq "invalid timeout exits with 1" 1 "$status"
expect_match "invalid timeout is reported" "Invalid DRUSH_CRON_TIMEOUT" "$out"
make_tmpdir
echo "not a crontab line" > "$tmpdir/bad.crontab"
out=$(docker run --rm -v "$tmpdir/bad.crontab:/etc/supercronic.d/bad.crontab:ro" "$image" 2>&1); status=$?
expect_eq "invalid extra crontab exits with 1" 1 "$status"
expect_match "invalid extra crontab is reported" "Invalid crontab /etc/supercronic.d/bad.crontab" "$out"

site basic -e DRUSH_CRON_SCHEDULE="$every_second" -e FOO=bar
basic=$site_name basic_dir=$site_dir
site maint -e DRUSH_CRON_SCHEDULE="$every_second" -e FAKE_MAINT=1
maint_dir=$site_dir
site maint-true -e DRUSH_CRON_SCHEDULE="$every_second" -e FAKE_MAINT=true
maint_true_dir=$site_dir
site state-fail -e DRUSH_CRON_SCHEDULE="$every_second" -e FAKE_STATE_FAIL=1
state_fail=$site_name state_fail_dir=$site_dir
site failing -e DRUSH_CRON_SCHEDULE="$every_second" -e FAKE_FAIL=1
failing=$site_name
site timeout -e DRUSH_CRON_SCHEDULE="$every_second" -e DRUSH_CRON_TIMEOUT=1 -e FAKE_SLEEP=5
timeout=$site_name timeout_dir=$site_dir
site overlap -e DRUSH_CRON_SCHEDULE="$every_second" -e FAKE_SLEEP=3
overlap=$site_name overlap_dir=$site_dir
site graceful -e DRUSH_CRON_SCHEDULE="$every_second" -e FAKE_SLEEP=5
graceful=$site_name graceful_dir=$site_dir
make_tmpdir
extra_crontab=$tmpdir/extra.crontab
echo "$every_second"' echo "extra user=$(id -un)" >> /var/www/html/log/extra.log' > "$extra_crontab"
site extra -e DRUSH_CRON_SCHEDULE='0 0 1 1 *' -v "$extra_crontab:/etc/supercronic.d/extra.crontab:ro"
extra_dir=$site_dir
site idle -e DRUSH_CRON_SCHEDULE='0 0 1 1 *'
idle=$site_name
site crash -e DRUSH_CRON_SCHEDULE='0 0 1 1 *'
crash=$site_name

# Stop "graceful" while its first cron run is in progress
for _ in $(seq 1 30); do
    grep -q start "$graceful_dir/log/drush.log" 2>/dev/null && break
    sleep 0.2
done
start=$(date +%s)
docker stop -t 30 "$graceful" > /dev/null
stop_seconds=$(($(date +%s) - start))

sleep 8

echo "Cron runs"
log=$(drush_log "$basic_dir")
expect_match "cron runs" "^start " "$log"
expect_match "as www-data with HOME=/tmp" "user=www-data home=/tmp" "$log"
expect_match "with the container's environment" "foo=bar" "$log"
expect_no_match "successful runs log nothing" "error|drush" "$(docker logs "$basic" 2>&1 | grep -v AH00)"

echo "Extra jobs"
expect_match "jobs from /etc/supercronic.d run as www-data" "^extra user=www-data$" "$(cat "$extra_dir/log/extra.log" 2>/dev/null)"

echo "Maintenance mode"
expect_eq "skipped when state:get prints 1" "" "$(drush_log "$maint_dir")"
expect_eq "skipped when state:get prints true" "" "$(drush_log "$maint_true_dir")"
expect_eq "skipped when the check fails" "" "$(drush_log "$state_fail_dir")"
expect_match "a failed check is logged" "fake state error" "$(docker logs "$state_fail" 2>&1)"

echo "Failures"
logs=$(docker logs "$failing" 2>&1)
expect_match "drush output of a failed run is logged" "fake cron failure" "$logs"
expect_match "the failure is logged" "exit status 1" "$logs"
expect_match "timeout stops the run" "exit status 124" "$(docker logs "$timeout" 2>&1)"
expect_match "drush gets SIGTERM on timeout" "^signal$" "$(drush_log "$timeout_dir")"

echo "No overlap"
log=$(drush_log "$overlap_dir")
expect_eq "runs never overlap" "" "$(awk '/^start/ { if (open) print "overlap"; open = 1 } /^end/ { open = 0 }' <<< "$log")"
expect_match "skipped runs are logged" "job is still running" "$(docker logs "$overlap" 2>&1)"

echo "Shutdown"
log=$(drush_log "$graceful_dir")
expect_match "stop waits for the running cron" "^end$" "$log"
expect_no_match "drush gets no signal on stop" "^signal$" "$log"
if [ "$stop_seconds" -ge 2 ]; then pass "stop took ${stop_seconds}s"; else fail "stop took ${stop_seconds}s, didn't wait"; fi
expect_eq "exit code after stop is 0" 0 "$(docker inspect -f '{{.State.ExitCode}}' "$graceful")"
start=$(date +%s)
docker stop -t 30 "$idle" > /dev/null
stop_seconds=$(($(date +%s) - start))
if [ "$stop_seconds" -le 5 ]; then pass "idle stop is quick (${stop_seconds}s)"; else fail "idle stop took ${stop_seconds}s"; fi
docker exec "$crash" bash -c 'kill -9 "$(cat /var/run/apache2/apache2.pid)"'
sleep 3
expect_eq "container exits when Apache dies" false "$(docker inspect -f '{{.State.Running}}' "$crash")"

finish
