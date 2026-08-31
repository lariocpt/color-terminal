// color-terminal — MIRROR the public GitHub release onto the LAN apps plane.
//
//     curl -fsSL https://lariocpt.github.io/color-terminal/install.sh | sh   (everyone)
//     curl -fsSL https://apps.in.drlario.org/install.sh | bash -s -- color-terminal   (here)
//
// THIS PIPELINE NO LONGER BUILDS ANYTHING. It used to run `make dist` and publish its
// own artifact, which meant two independent builds of one commit could land in two
// places. The GitHub Release is now the single source of truth and /srv/apps holds a
// byte-identical copy of it — asserted below, not assumed.
//
// `make dist` appears exactly once, in a throwaway worktree, purely to PROVE the
// released file was built from this tag. It never produces what is published.
//
// THE GATE IS STILL THE REAL TEST SUITE, and it is now stronger than it was: the
// self-install, payload and latency layers run against the RELEASED file rather than a
// local rebuild of it, so what is verified is exactly what ships.
pipeline {
    agent any
    options {
        disableConcurrentBuilds()
        // Every cron poll is a build record even when it mirrors nothing, so 20 would
        // evict the last real mirror's log within about five hours. 200 is two days.
        buildDiscarder(logRotator(numToKeepStr: '200'))
        timeout(time: 25, unit: 'MINUTES')
    }
    // GitHub cannot reach this Jenkins, so it asks rather than being told. Polling the
    // /releases/latest redirect needs no token and spends no API rate limit.
    triggers { cron('H/15 * * * *') }
    parameters {
        string(name: 'TAG', defaultValue: '',
               description: 'Release tag to mirror, e.g. v2.0.0. Empty = whatever GitHub calls latest.')
        booleanParam(name: 'FORCE', defaultValue: false,
               description: 'Republish even if this version is already on the plane.')
        booleanParam(name: 'PROVENANCE', defaultValue: true,
               description: 'Rebuild the tag inside the gate container and prove the released artifact is byte-identical.')
    }
    environment {
        TOOL    = 'color-terminal'
        GH_REPO = 'lariocpt/color-terminal'
    }
    stages {

        stage('Resolve') {
            steps {
                script {
                    // Egress is checked HERE, before anything depends on it: this stage
                    // runs every 15 minutes, and a quiet NOT_BUILT beats a red build.
                    def online = sh(returnStatus: true, script: '''
                        curl -fsS -o /dev/null -m 20 https://github.com
                    ''') == 0
                    if (!online) {
                        currentBuild.result = 'NOT_BUILT'
                        currentBuild.description = 'no route to github.com'
                        env.NEEDED = '0'
                        return
                    }

                    // The /releases/latest redirect lands on /releases/tag/vX.Y.Z and
                    // excludes drafts and prereleases — exactly the set to mirror. With no
                    // release yet it lands on /releases and the tag comes back as
                    // "releases": a quiet NOT_BUILT, not an error, for the same reason.
                    env.TAG = params.TAG?.trim() ?: sh(returnStdout: true, script: '''
                        set -eu
                        url=$(curl -fsS -o /dev/null -w '%{url_effective}' -L -I \
                              "https://github.com/${GH_REPO}/releases/latest")
                        printf '%s' "${url##*/}"
                    ''').trim()

                    if (!(env.TAG ==~ /^v[0-9][0-9A-Za-z.+-]*$/)) {
                        currentBuild.result = 'NOT_BUILT'
                        currentBuild.description = "no release to mirror (got '${env.TAG}')"
                        env.NEEDED = '0'
                        return
                    }
                    env.VERSION = env.TAG.substring(1)

                    // Already mirrored? Then this poll is a no-op. The version reaches the
                    // shell through the environment, never by interpolation: a Groovy
                    // string with a tag name inside shell quotes is an injection waiting
                    // for a tag with a quote in it.
                    def onPlane = sh(returnStatus: true, script: '''
                        awk -F'\t' -v v="$VERSION" \
                            '$1=="tool" && $2=="color-terminal" && $3==v && index($7,"/latest/")>0 {x++} END{exit !x}' \
                            /srv/apps/index.tsv
                    ''') == 0
                    env.NEEDED = (onPlane && !params.FORCE) ? '0' : '1'

                    echo "tag=${env.TAG} version=${env.VERSION} onPlane=${onPlane} needed=${env.NEEDED}"
                    if (env.NEEDED == '0') {
                        currentBuild.result = 'NOT_BUILT'
                        currentBuild.description = "${env.TAG} already mirrored"
                    } else {
                        currentBuild.description = "mirroring ${env.TAG}"
                    }
                }
            }
        }

        stage('Preflight') {
            when { environment name: 'NEEDED', value: '1' }
            steps {
                sh '''
                    set -eu
                    test -w /srv/apps || { echo "/srv/apps not writable"; exit 1; }
                    test -x /opt/publish/bin/apps-publish || { echo "apps-publish not mounted"; exit 1; }
                    command -v curl      >/dev/null || { echo "curl missing — needed to fetch the release"; exit 1; }
                    command -v sha256sum >/dev/null || { echo "sha256sum missing — nothing may publish unverified"; exit 1; }
                    # The gate needs python3 and make; the Jenkins image has neither, and
                    # adding them to it would make this pipeline depend on a controller
                    # rebuild. It runs in a container instead — see the Gate stage.
                    command -v docker    >/dev/null || { echo "docker missing — the gate runs in a container"; exit 1; }
                '''
            }
        }

        // The suite's L1-L3 layers run bin/color-terminal out of the checkout, so the
        // checkout has to BE the tag. Otherwise a green run would prove main works
        // while publishing bytes built from something else.
        stage('Source') {
            when { environment name: 'NEEDED', value: '1' }
            steps {
                sh '''
                    set -eu
                    # The gate belongs to the pipeline, not the release: take it from the
                    # branch this Jenkinsfile was read from, before the tag replaces the
                    # tree. Untracked, so the checkout leaves it alone.
                    cp test/ci-gate.sh .ci-gate.sh
                    git fetch --tags --force origin
                    git -c advice.detachedHead=false checkout --detach "refs/tags/${TAG}"
                    v=$(sed -n 's/^CT_VERSION=\\(.*\\)$/\\1/p' lib/common.sh | head -1)
                    [ "$v" = "$VERSION" ] \
                      || { echo "FAIL: $TAG is checked out but lib/common.sh says CT_VERSION=$v"; exit 1; }
                    echo "source: $TAG (CT_VERSION=$v)"
                '''
            }
        }

        stage('Fetch') {
            when { environment name: 'NEEDED', value: '1' }
            steps {
                sh '''
                    set -eu
                    rm -rf dist; mkdir -p dist
                    base="https://github.com/${GH_REPO}/releases/download/${TAG}"
                    for f in color-terminal SHA256SUMS; do
                        curl -fsSL --proto '=https' --retry 5 --retry-all-errors -o "dist/$f" "$base/$f"
                    done

                    # SHA256SUMS names the artifact with no directory component, so it only
                    # verifies from inside the directory holding it. --ignore-missing because
                    # a release may list assets this job does not download (a .sig, a bundle).
                    ( cd dist && sha256sum -c --ignore-missing SHA256SUMS )

                    # Release assets arrive WITHOUT the executable bit. That matters more than
                    # it looks: test/run.sh rebuilds dist/color-terminal when it is missing or
                    # not executable, so forgetting this would make the gate silently test a
                    # local rebuild and publish bytes that never came from the release.
                    chmod +x dist/color-terminal

                    # Matched by asset name, not by line: the first second asset would
                    # otherwise turn this into two lines and fail every identity check.
                    awk -v a=color-terminal '$2 == a || $2 == "*" a { print $1; exit }' dist/SHA256SUMS > .released-sha
                    [ -s .released-sha ] || { echo "FAIL: SHA256SUMS has no entry for color-terminal"; exit 1; }
                    echo "fetched ${TAG}: $(cat .released-sha)"
                '''
            }
        }

        // One container, one apt, both checks. The Jenkins image has no python3 and no
        // make, and the workspace is a named volume so it cannot be bind-mounted — the
        // same constraint crust and opn work around with docker create + docker cp.
        // The script itself is test/ci-gate.sh (staged by Source), where `make lint`
        // can see it.
        stage('Gate') {
            when { environment name: 'NEEDED', value: '1' }
            steps {
                sh '''
                    set -eu
                    [ -f .ci-gate.sh ] || { echo "FAIL: .ci-gate.sh missing — Source should have staged it"; exit 1; }
                    CID=$(docker create --rm -w /w \
                            -e VERSION="$VERSION" -e TAG="$TAG" -e PROVENANCE="$PROVENANCE" \
                            debian:stable-slim sh /w/.ci-gate.sh)
                    # EXIT alone is not enough: an abort or the pipeline timeout TERMs this
                    # shell, and POSIX sh runs no EXIT trap on an untrapped signal — the
                    # container would outlive the build. --rm above is the second belt.
                    trap 'docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT INT TERM HUP
                    # docker cp both ways — never -v "$PWD:/w". The workspace lives in a
                    # named volume that the daemon cannot see at that path.
                    docker cp "$PWD/." "$CID:/w" >/dev/null
                    docker start -a "$CID"

                    # The container only ever had a copy, so assert on the host side too
                    # that what goes to apps-publish is what was downloaded and verified.
                    [ "$(sha256sum dist/color-terminal | awk '{print $1}')" = "$(cat .released-sha)" ] \
                      || { echo "FAIL: the workspace artifact changed"; exit 1; }
                '''
            }
        }

        stage('Publish') {
            when { environment name: 'NEEDED', value: '1' }
            steps {
                sh '''
                    set -eu
                    # The bare tag version, with no +sha. There is exactly one artifact per
                    # version now and the tag names it uniquely, so the plane's row, the
                    # release page and `color-terminal --version` all print one string.
                    /opt/publish/bin/apps-publish bin "$TOOL" "$VERSION" "$WORKSPACE/dist/color-terminal"
                '''
            }
        }

        stage('Verify') {
            when { environment name: 'NEEDED', value: '1' }
            steps {
                sh '''
                    set -eu

                    # Assert the /latest/ row specifically. apps-reindex emits the concrete
                    # version row whether or not `latest` was minted, but install.sh only reads
                    # rows whose path goes through latest/ — so checking the concrete row can
                    # pass while no client can see the artifact.
                    read -r sha relpath <<EOF
$(awk -F'\\t' -v v="$VERSION" \
    '$1=="tool" && $2=="color-terminal" && $3==v && index($7,"/latest/")>0 {print $5, $7; exit}' \
    /srv/apps/index.tsv)
EOF
                    [ -n "${relpath:-}" ] || { echo "FAIL: no /latest/ row for color-terminal $VERSION"; exit 1; }

                    # Byte identity with the public release is the entire premise of mirror
                    # mode, so assert it rather than trust it. The index carries the sha the
                    # plane will serve, which is the value clients actually verify against.
                    [ "$sha" = "$(cat .released-sha)" ] \
                      || { echo "FAIL: /srv/apps serves $sha, release $TAG is $(cat .released-sha)"; exit 1; }
                    echo "byte identity: /srv/apps == release $TAG"

                    # And end to end, the way a machine actually gets it.
                    curl -fsSL https://apps.in.drlario.org/install.sh | bash -s -- --list \
                        | grep -q color-terminal \
                        || { echo "FAIL: install.sh does not list color-terminal"; exit 1; }
                    echo "mirrored color-terminal $VERSION from $TAG"
                '''
            }
        }
    }
}
