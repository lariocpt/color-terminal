// color-terminal — publish the single self-installing artifact to the LAN apps plane.
//
//     curl -fsSL https://apps.in.drlario.org/install.sh | bash -s -- color-terminal
//     color-terminal --install
//
// NO COMPILER, AND NO GLIBC FLOOR TO WORRY ABOUT. Unlike opn/crust this is bash, so
// there is no build image, no cargo cache and no portability gate — the artifact is
// `make dist`, which concatenates lib/*.sh into one file and appends the themes and
// shell-hook templates as a base64 payload after the final `exit`.
//
// WHY A SINGLE FILE AND NOT A BUNDLE. The apps plane installs tools with
// download -> sha256sum -c -> install -m0755 and nothing else, so anything the tool
// needs at runtime has to be inside the file. Publishing this as a `bundle` tarball
// would work but would make color-terminal the only tool on the plane needing a second
// step to become usable, and would lose the `scp color-terminal remote:` property that
// is the whole reason the amalgamation exists.
//
// THE GATE IS THE REAL TEST SUITE. For a compiled tool the gate is "does it start and
// report its version". Here the artifact IS the source, so there is no reason to settle
// for that: test/run.sh allocates a pty, plays the terminal, and asserts the exact
// escape bytes, the marker-block surgery, the concurrency behaviour and the latency
// budget — all without a terminal emulator installed, which is exactly what a CI
// container has. A red suite must not reach /srv/apps.
pipeline {
    agent any
    options {
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }
    environment {
        TOOL = 'color-terminal'
    }
    stages {
        stage('Preflight') {
            steps {
                sh '''
                    set -eu
                    test -w /srv/apps || { echo "/srv/apps not writable"; exit 1; }
                    test -x /opt/publish/bin/apps-publish || { echo "apps-publish not mounted"; exit 1; }
                    command -v python3 >/dev/null || { echo "python3 missing — test/faketerm.py needs it"; exit 1; }
                    command -v base64  >/dev/null || { echo "base64 missing — needed to build the payload"; exit 1; }
                '''
            }
        }
        stage('Version') {
            steps {
                sh '''
                    set -eu
                    BASE=$(sed -n 's/^CT_VERSION=\\(.*\\)$/\\1/p' lib/common.sh | head -1)
                    [ -n "$BASE" ] || { echo "could not parse CT_VERSION from lib/common.sh"; exit 1; }
                    SHA=$(git rev-parse --short HEAD)
                    echo "APPS_VERSION=${BASE}+${SHA}" > version.env
                    echo "BASE_VERSION=${BASE}"        >> version.env
                    cat version.env
                '''
            }
        }
        stage('Build') {
            steps {
                sh '''
                    set -eu
                    make dist
                    ls -lh dist/color-terminal
                '''
            }
        }
        stage('Gate') {
            steps {
                sh '''
                    set -eu
                    . ./version.env

                    # Themes are data the tool cannot run without, and a theme that fails the
                    # contrast gate is a theme that makes somebody's terminal unreadable.
                    python3 tools/validate-themes.py

                    # The full suite: escape bytes, multiplexer wrapping, detection matrix,
                    # marker-block idempotence, concurrency, latency, and the self-install of
                    # the artifact this stage just built. Needs no terminal emulator.
                    ./test/run.sh

                    got=$(./dist/color-terminal --version | tr -d "\\r")
                    echo "reported: $got"
                    case "$got" in
                        *"$BASE_VERSION"*) : ;;
                        *) echo "FAIL: artifact reports '$got', expected it to contain '$BASE_VERSION'"; exit 1 ;;
                    esac

                    # The payload must survive the round trip, or the artifact installs a tool
                    # with no themes — which fails at first use, not at install time.
                    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
                    HOME="$tmp" XDG_RUNTIME_DIR="$tmp/run" CT_QUIET=1 \
                        ./dist/color-terminal --install --no-wire >/dev/null
                    n=$(ls "$tmp/.local/share/color-terminal/themes"/*.theme 2>/dev/null | wc -l)
                    [ "$n" -eq 24 ] || { echo "FAIL: artifact installed $n themes, expected 24"; exit 1; }
                    echo "payload round-trip: $n themes"
                '''
            }
        }
        stage('Publish') {
            steps {
                sh '''
                    set -eu
                    . ./version.env
                    /opt/publish/bin/apps-publish bin "$TOOL" "$APPS_VERSION" "$WORKSPACE/dist/color-terminal"
                '''
            }
        }
        stage('Verify') {
            steps {
                sh '''
                    set -eu
                    . ./version.env

                    # Assert the /latest/ row specifically. apps-reindex emits the concrete
                    # version row whether or not `latest` was minted, but install.sh only reads
                    # rows whose path goes through latest/ — so checking the concrete row can
                    # pass while no client can see the artifact.
                    awk -F'\\t' -v v="$APPS_VERSION" \
                        '$1=="tool" && $2=="color-terminal" && $3==v && index($7,"/latest/")>0 {x++} END{exit !x}' \
                        /srv/apps/index.tsv \
                        || { echo "FAIL: no /latest/ row for color-terminal $APPS_VERSION"; exit 1; }

                    # And end to end, the way a machine actually gets it.
                    curl -fsSL https://apps.in.drlario.org/install.sh | bash -s -- --list \
                        | grep -q color-terminal \
                        || { echo "FAIL: install.sh does not list color-terminal"; exit 1; }
                    echo "published color-terminal $APPS_VERSION"
                '''
            }
        }
    }
}
