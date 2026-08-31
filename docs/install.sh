#!/bin/sh
# install.sh — the public installer for color-terminal.
#
#     curl -fsSL https://lariocpt.github.io/color-terminal/install.sh | sh
#
# It resolves a GitHub Release, downloads the single-file artifact and its checksum,
# verifies the checksum, and hands the verified file to its OWN --install. That is
# all it does. It never writes into your PATH itself: the real installer lives inside
# the artifact (lib/install.sh), which is why `scp color-terminal remote:` is a
# complete install with no bootstrap involved — and why --dry-run here is dry.
#
# POSIX sh on purpose: this is run by whatever /bin/sh the reader has — dash, ash,
# busybox, bash in posix mode. No arrays, no [[ ]], no `local`, no pipefail.
#
# EVERYTHING LIVES IN FUNCTIONS AND THE LAST LINE IS `main "$@"`. That is not style.
# The script is executed straight off a socket; if the connection dies halfway, a
# top-to-bottom script would run the half that arrived. sh cannot call main until it
# has read the closing brace, so a truncated download does nothing at all.
#
# Options (anything else is passed through to `color-terminal --install`):
#   vX.Y.Z, --tag=vX.Y.Z        install one release, not the latest [COLOR_TERMINAL_VERSION]
#   --prefix=DIR, --prefix DIR  install root; the binary goes in DIR/bin (default ~/.local)
#                               [COLOR_TERMINAL_PREFIX]
#   --source=github|apps        where to resolve from (default github) [COLOR_TERMINAL_SOURCE]
#   --download-only=PATH        fetch and verify to PATH, install nothing
#   --print-url                 resolve and print the download URL, fetch nothing
#   -h, --help                  this text (the tool's own help is `color-terminal --help`)
#
# Also honoured: COLOR_TERMINAL_REPO (owner/name), COLOR_TERMINAL_DOWNLOAD_BASE (a URL
# holding color-terminal and SHA256SUMS — a mirror, or a file:// dir for a rehearsal),
# APPS_URL (root of the LAN mirror, for --source=apps).
set -eu

CT_REPO_DEFAULT='lariocpt/color-terminal'
CT_ASSET='color-terminal'
CT_SUMS='SHA256SUMS'

ct_say()  { printf 'color-terminal: %s\n' "$*"; }
ct_warn() { printf 'color-terminal: %s\n' "$*" >&2; }
ct_die()  { ct_warn "$*"; exit 1; }
ct_have() { command -v "$1" >/dev/null 2>&1; }

# A heredoc, not `sed -n '2,27p' "$0"`: piped through sh there is no $0 to read, and
# a line range silently truncates the moment the header grows.
ct_usage() {
    cat <<'EOF'
install.sh — install color-terminal from its published release.

    curl -fsSL https://lariocpt.github.io/color-terminal/install.sh | sh
    curl -fsSL https://lariocpt.github.io/color-terminal/install.sh | sh -s -- --dry-run
    curl -fsSL https://lariocpt.github.io/color-terminal/install.sh | sh -s -- v2.0.0 --trigger=shell

Options (anything else is passed through to `color-terminal --install`):
  vX.Y.Z, --tag=vX.Y.Z        install one release, not the latest  [COLOR_TERMINAL_VERSION]
  --prefix=DIR, --prefix DIR  install root; binary goes in DIR/bin  [COLOR_TERMINAL_PREFIX]
  --source=github|apps        where to resolve from, default github [COLOR_TERMINAL_SOURCE]
  --download-only=PATH        fetch and verify to PATH; install nothing
  --print-url                 resolve and print the download URL; fetch nothing
  -n, --dry-run               passed through: say what --install would do, write nothing
  -h, --help                  this text

Also honoured: COLOR_TERMINAL_REPO, COLOR_TERMINAL_DOWNLOAD_BASE, APPS_URL.
The download is verified against the release's SHA256SUMS before anything runs.
EOF
}

ct_cleanup() { if [ -n "${CT_TMP:-}" ]; then rm -rf "$CT_TMP"; fi; }

# The scheme allowlist is https for the published path and is widened only when the
# caller has already asked for something else — a LAN mirror, a file:// rehearsal.
# What makes the transport safe to relax is the sha256 check, which is never skipped.
ct_fetch() {                                  # <url> <dest>
    case "$1" in
        https://*) proto='=https' ;;
        *)         proto='=https,http,file' ;;
    esac
    if ct_have curl; then
        curl -fsSL --proto "$proto" --retry 3 --retry-delay 1 -o "$2" "$1"
    elif ct_have wget; then
        # --https-only is GNU wget's; busybox has no such flag, hence the probe in
        # main. CT_WGET_HTTPS is deliberately empty or exactly one flag.
        # shellcheck disable=SC2086
        case "$1" in
            file://*)  ct_die 'wget cannot fetch file:// URLs — install curl to use a local mirror' ;;
            https://*) wget -q $CT_WGET_HTTPS -O "$2" "$1" ;;
            *)         wget -q -O "$2" "$1" ;;
        esac
    else
        ct_die 'need curl or wget'
    fi
}

# Fail closed. A checksum you cannot compute is not a checksum, and the job of this
# script is to put an executable on somebody's PATH. There is no branch that skips it.
ct_sha256() {                                 # <file> -> hex on stdout
    if   ct_have sha256sum; then sha256sum "$1" | cut -d' ' -f1
    elif ct_have shasum;    then shasum -a 256 "$1" | cut -d' ' -f1
    elif ct_have openssl;   then openssl dgst -sha256 "$1" | sed 's/.*= *//'
    else return 1
    fi
}

# Pin the tag ONCE, then fetch both files from that tag's own directory. Two separate
# trips through /releases/latest/download/ can straddle a release and pair the old
# checksum with the new file — and then tell the user their download was tampered
# with. One HEAD request, no token, no API budget.
ct_latest_tag() {                             # <owner/repo> -> tag on stdout
    url="https://github.com/$1/releases/latest"
    if ct_have curl; then
        loc=$(curl -fsSIL --proto '=https' -o /dev/null -w '%{url_effective}' "$url") || return 1
    else
        loc=$(wget --spider -S "$url" 2>&1 | sed -n 's/^ *[Ll]ocation: *//p' | tail -1)
    fi
    loc=${loc%%\?*}; loc=${loc%/}
    tag=${loc##*/}
    case "$tag" in v[0-9]*) printf '%s' "$tag" ;; *) return 1 ;; esac
}

ct_resolve_github() {                         # -> CT_URL, CT_SUMS_URL
    repo=${COLOR_TERMINAL_REPO:-$CT_REPO_DEFAULT}
    if [ -n "${COLOR_TERMINAL_DOWNLOAD_BASE:-}" ]; then
        base=${COLOR_TERMINAL_DOWNLOAD_BASE%/}
    else
        if [ "$CT_VERSION" = latest ]; then
            tag=$(ct_latest_tag "$repo") \
                || ct_die "could not resolve the latest release of $repo — is one published?"
        else
            tag="v$CT_VERSION"                # GitHub tags carry the v; the index does not
        fi
        base="https://github.com/$repo/releases/download/$tag"
    fi
    CT_URL="$base/$CT_ASSET"
    CT_SUMS_URL="$base/$CT_SUMS"
}

# The LAN mirror is resolved through its index rather than a guessed path: the row
# whose path goes via latest/ is the only one a client is meant to read, and it
# carries the sha256 inline, so this plane needs no separate checksum file.
ct_resolve_apps() {                           # -> CT_URL, CT_WANT
    apps="${APPS_URL:-https://apps.in.drlario.org}"
    ct_fetch "$apps/index.tsv" "$CT_TMP/index.tsv" || ct_die "cannot reach the LAN mirror at $apps"
    row=$(awk -F'\t' -v v="$CT_VERSION" '
        $1=="tool" && $2=="color-terminal" && index($7,"/latest/")>0 &&
        (v=="latest" || $3==v) { print $5 "|" $7; exit }' "$CT_TMP/index.tsv")
    [ -n "$row" ] || ct_die "no color-terminal $CT_VERSION on the LAN mirror at $apps"
    CT_WANT=${row%%|*}
    CT_URL="$apps/${row#*|}"
    CT_SUMS_URL=
}

ct_want_from_sums() {
    ct_fetch "$CT_SUMS_URL" "$CT_TMP/$CT_SUMS" \
        || ct_die "cannot fetch $CT_SUMS_URL — is that release published?"
    # Matched by asset name, not position, so a release that later grows a second
    # asset does not break installers already in the wild. The '*' is what sha256sum
    # writes in binary mode.
    CT_WANT=$(awk -v a="$CT_ASSET" '$2 == a || $2 == "*" a { print $1; exit }' "$CT_TMP/$CT_SUMS")
    [ -n "$CT_WANT" ] || ct_die "$CT_SUMS has no entry for $CT_ASSET"
}

main() {
    CT_VERSION=${COLOR_TERMINAL_VERSION:-latest}
    ct_prefix=${COLOR_TERMINAL_PREFIX:-}
    ct_source=${COLOR_TERMINAL_SOURCE:-github}
    ct_dlonly=''; ct_printurl=''; ct_quiet=''

    # Split our own options out of the ones that belong to `color-terminal --install`.
    # Rotating the positional list is the POSIX way to filter "$@" without arrays:
    # each kept argument is pushed to the back, each consumed one is dropped.
    n=$#
    while [ "$n" -gt 0 ]; do
        arg=$1; shift; n=$((n - 1))
        case "$arg" in
            v[0-9]*|[0-9]*.[0-9]*) CT_VERSION=$arg ;;
            --tag=*)           CT_VERSION=${arg#--tag=} ;;
            --prefix=*)        ct_prefix=${arg#--prefix=} ;;
            --prefix)          [ "$n" -gt 0 ] || ct_die '--prefix needs a value'
                               ct_prefix=$1; shift; n=$((n - 1)) ;;
            --source=*)        ct_source=${arg#--source=} ;;
            --download-only=*) ct_dlonly=${arg#--download-only=} ;;
            --print-url)       ct_printurl=1 ;;
            -h|--help)         ct_usage; exit 0 ;;
            # Passed through, but they make the PATH advice below noise: nothing
            # was installed.
            -n|--dry-run|-V|--version) ct_quiet=1; set -- "$@" "$arg" ;;
            *)                 set -- "$@" "$arg" ;;
        esac
    done
    # Both spellings are accepted; the resolvers add the v where a source wants it.
    case "$CT_VERSION" in v*) CT_VERSION=${CT_VERSION#v} ;; esac

    [ -n "$ct_prefix" ] || ct_prefix="$HOME/.local"
    # Absolute, and no trailing slash. The tool computes its own install target as
    # "$CT_PREFIX/bin/color-terminal" and compares it as a STRING against the path it
    # was invoked by; two spellings of one file would make it install the file over
    # itself. Not `pwd -P`: resolving symlinks would change the spelling too.
    case "$ct_prefix" in /*) ;; *) ct_prefix="$PWD/$ct_prefix" ;; esac
    while :; do case "$ct_prefix" in */) ct_prefix=${ct_prefix%/} ;; *) break ;; esac; done

    ct_have bash || ct_die 'color-terminal is a bash script and bash is not installed'
    CT_WGET_HTTPS=
    if ! ct_have curl && ct_have wget && wget --help 2>&1 | grep -q -- --https-only; then
        CT_WGET_HTTPS=--https-only
    fi

    CT_TMP=$(mktemp -d "${TMPDIR:-/tmp}/color-terminal.XXXXXX") || ct_die 'mktemp failed'
    # Clean up, then RE-RAISE. A trap that only cleans up swallows the signal: Ctrl-C
    # after the download would fall through to a completed install with exit 0.
    trap 'ct_cleanup' EXIT
    trap 'ct_cleanup; trap - INT EXIT;  kill -INT  $$' INT
    trap 'ct_cleanup; trap - TERM EXIT; kill -TERM $$' TERM
    trap 'ct_cleanup; trap - HUP EXIT;  kill -HUP  $$' HUP

    case "$ct_source" in
        github) ct_resolve_github ;;
        apps)   ct_resolve_apps ;;
        *)      ct_die "unknown --source '$ct_source' (want: github, apps)" ;;
    esac
    if [ -n "$ct_printurl" ]; then printf '%s\n' "$CT_URL"; exit 0; fi
    [ -n "${CT_SUMS_URL:-}" ] && ct_want_from_sums

    ct_say "downloading $CT_URL"
    ct_fetch "$CT_URL" "$CT_TMP/$CT_ASSET" || ct_die "download failed: $CT_URL"

    got=$(ct_sha256 "$CT_TMP/$CT_ASSET") \
        || ct_die 'no sha256sum, shasum or openssl here — refusing to install an unverified binary'
    # An empty hash is a hasher that failed, not a file that mismatched; say which.
    [ -n "$got" ] || ct_die 'could not hash the download (hasher failed) — refusing to continue'
    [ "$CT_WANT" = "$got" ] || ct_die "CHECKSUM MISMATCH — do not run the downloaded file
  expected $CT_WANT
  got      $got"
    chmod 0755 "$CT_TMP/$CT_ASSET"
    ct_say "verified $("$CT_TMP/$CT_ASSET" --version 2>/dev/null || echo 'unknown version')"

    # Verified first, executable second, in place third: nothing unverified is ever
    # executable at a stable path, and a half-written file never replaces a good one.
    if [ -n "$ct_dlonly" ]; then
        dir=$(dirname "$ct_dlonly")
        mkdir -p "$dir" || ct_die "cannot create $dir"
        cp "$CT_TMP/$CT_ASSET" "$ct_dlonly.tmp.$$" && chmod 0755 "$ct_dlonly.tmp.$$" \
            && mv -f "$ct_dlonly.tmp.$$" "$ct_dlonly" || ct_die "cannot write $ct_dlonly"
        ct_say "wrote $ct_dlonly"
        exit 0
    fi

    # Hand over to the installer inside the artifact. It does the copy into
    # $prefix/bin itself (with install(1): a new inode, so a running hook never reads
    # a half-written script), and it owns --dry-run, so a dry run here writes nothing.
    #
    # </dev/null because this script is being read from a pipe: a child that reads
    # stdin would swallow whatever of it is left. Colours are unaffected — the tool
    # opens /dev/tty on its own fd.
    rc=0
    "$CT_TMP/$CT_ASSET" --install --prefix="$ct_prefix" "$@" </dev/null || rc=$?
    [ "$rc" = 0 ] || exit "$rc"

    # A warning, not an error: the shell hook calls the tool by absolute path, so
    # colours work either way. Only typing the command yourself needs this.
    if [ -z "$ct_quiet" ]; then
        case ":${PATH:-}:" in
            *":$ct_prefix/bin:"*) ;;
            *) ct_warn "$ct_prefix/bin is not on your PATH. Colours will still work — the
  shell hook calls the tool by absolute path — but to run it by hand, add:
      export PATH=\"$ct_prefix/bin:\$PATH\"" ;;
        esac
    fi
    exit 0
}

main "$@"
