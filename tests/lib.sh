# shellcheck shell=bash
# Shared helpers for the test scripts. Source it, don't run it.
set -u

failures=0
containers=()
tmpdirs=()
networks=()
images=()

pass() { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }

# check DESCRIPTION COMMAND...: passes if the command succeeds, otherwise shows
# the end of its output
check() {
    local desc=$1 output
    shift
    if output=$("$@" 2>&1); then
        pass "$desc"
    else
        fail "$desc"
        tail -n 15 <<< "$output" | sed 's/^/        /'
    fi
}

# expect_eq DESCRIPTION EXPECTED ACTUAL
expect_eq() {
    if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

# expect_match DESCRIPTION REGEX TEXT
expect_match() {
    if grep -qE -- "$2" <<< "$3"; then pass "$1"; else fail "$1 (no match for '$2')"; fi
}

# expect_no_match DESCRIPTION REGEX TEXT: on failure shows the first matches
expect_no_match() {
    if grep -qE -- "$2" <<< "$3"; then
        fail "$1 (unexpected '$2')"
        grep -E -- "$2" <<< "$3" | head -n 3 | cut -c1-300 | sed 's/^/        /'
    else
        pass "$1"
    fi
}

# start_container NAME DOCKER_RUN_ARGS...: removed again when the script exits
start_container() {
    local name=$1
    shift
    containers+=("$name")
    docker run -d --name "$name" "$@" > /dev/null
}

# commit_container CONTAINER IMAGE: snapshots a container, removed again when
# the script exits
commit_container() {
    images+=("$2")
    docker commit "$1" "$2" > /dev/null
}

# make_network NAME: creates a network, removed again when the script exits
make_network() {
    networks+=("$1")
    docker network create "$1" > /dev/null
}

# make_tmpdir: creates a directory, removed again when the script exits, and
# sets $tmpdir to it. Not via $(...), which would lose track of it in a subshell.
make_tmpdir() {
    tmpdir=$(mktemp -d)
    tmpdirs+=("$tmpdir")
}

cleanup() {
    if [ "${#containers[@]}" -gt 0 ]; then
        docker rm -f "${containers[@]}" > /dev/null 2>&1
    fi
    if [ "${#images[@]}" -gt 0 ]; then
        docker rmi "${images[@]}" > /dev/null 2>&1
    fi
    if [ "${#networks[@]}" -gt 0 ]; then
        docker network rm "${networks[@]}" > /dev/null 2>&1
    fi
    if [ "${#tmpdirs[@]}" -gt 0 ]; then
        rm -rf "${tmpdirs[@]}"
    fi
}
trap cleanup EXIT

finish() {
    if [ "$failures" -gt 0 ]; then
        echo "$failures check(s) failed"
        exit 1
    fi
    echo "All checks passed"
}
