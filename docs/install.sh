#!/bin/sh
# install.sh — the public installer for color-terminal.
#
#     curl -fsSL https://lariocpt.github.io/color-terminal/install.sh | sh
#
# It does four things and nothing else: resolve a GitHub Release, download the
# single-file artifact and its checksum, verify it, and hand over to the tool's OWN
# --install. The real installer lives inside the artifact (lib/install.sh), which is
# why this file can be this short — and why `scp color-terminal remote:` is still a
# complete install with no bootstrap involved at all.
#
# POSIX sh on purpose: this is run by whatever /bin/sh the reader has — dash, ash,
# busybox, bash in posix mode. No arrays, no [[ ]], no `local`, no pipefail.
#
# EVERYTHING LIVES IN FUNCTIONS AND THE LAST LINE IS `main "$@"`. That is not style.
# The script is executed straight off a socket; if the connection dies halfway, a
# top-to-bottom script would run the half that arrived. sh cannot call main until it
# has read the closing brace, so a truncated download does nothing at all.
#
# Options (anything not listed is passed through to `color-terminal --install`):
#   vX.Y.Z, --version=vX.Y.Z   install a specific release        [COLOR_TERMINAL_VERSION]
#   --prefix=DIR               install root, default ~/.local    [COLOR_TERMINAL_PREFIX]
#   --source=github|apps       where to resolve from             [COLOR_TERMINAL_SOURCE]
#   --download-only=PATH       fetch and verify to PATH, install nothing
#   --help
#
# Also honoured: COLOR_TERMINAL_REPO, COLOR_TERMINAL_DOWNLOAD_BASE, APPS_URL.
set -eu

CT_REPO_DEFAULT='lariocpt/color-terminal'
CT_ASSET='color-terminal'
CT_SUMS='SHA256SUMS'

ct_say()  { printf 'color-terminal: %s\n' "$*"; }
ct_warn() { printf 'color-terminal: %s\n' "$*" >&2; }
ct_die()  { ct_warn "$*"; exit 1; }
ct_have() { command -v "$1" >/dev/null 2>&1; }

ct_usage() { sed -n '2,27p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; }

# The scheme allowlist is narrowed to https for the published path and widened only
# when the caller has already opted out of it by setting a non-https base themselves —
# a LAN mirror, a local file:// rehearsal. What makes the transport safe to relax is
# the sha256 check below, which is never skipped for any source.
ct_fetch() {                                  # <url> <dest>
    case "$1" in
        https://*) proto='=https' ;;
        *)         proto='=https,http,file' ;;
    esac
    if ct_have curl; then
        curl -fsSL --proto "$proto" --retry 3 --retry-delay 1 -o "$2" "$1"
    elif ct_have wget; then
        case "$1" in https://*) wget -q --https-only -O "$2" "$1" ;; *) wget -q -O "$2" "$1" ;; esac
    else
        ct_die 'need curl or wget'
    fi
}

# Fail closed. A checksum you cannot compute is not a checksum, and the job of this
# script is to put an executable on somebody's PATH. There is deliberately no branch
# that skips the check.
ct_sha256() {                                 # <file> -> hex on stdout
    if   ct_have sha256sum; then sha256sum "$1" | cut -d' ' -f1
    elif ct_have shasum;    then shasum -a 256 "$1" | cut -d' ' -f1
    elif ct_have openssl;   then openssl dgst -sha256 "$1" | sed 's/.*= *//'
    else return 1
    fi
}

# Resolve the LAN mirror through its index rather than guessing a path: the row whose
# path goes via latest/ is the only one a client is meant to read, and it carries the
# sha256 inline, so this plane needs no separate checksum file.
ct_resolve_apps() {                           # -> CT_URL, CT_WANT
    apps="${APPS_URL:-https://apps.in.drlario.org}"
    idx="$CT_TMP/index.tsv"
    ct_fetch "$apps/index.tsv" "$idx" || ct_die "cannot reach the LAN mirror at $apps"
    row=$(awk -F'\t' -v v="$CT_VERSION" '
        $1=="tool" && $2=="color-terminal" && index($7,"/latest/")>0 &&
        (v=="latest" || $3==v || $3 ~ "^" v "\\+") { print $5 "|" $7; exit }' "$idx")
    [ -n "$row" ] || ct_die "no color-terminal row for '$CT_VERSION' in $apps/index.tsv"
    CT_WANT=${row%%|*}
    CT_URL="$apps/${row#*|}"
}

# The /releases/latest/download/ redirect resolves without a token, so there is no
# credential to arrange and no 60-per-hour API budget for a shared NAT to exhaust.
ct_resolve_github() {                         # -> CT_URL, CT_WANT
    repo="${COLOR_TERMINAL_REPO:-$CT_REPO_DEFAULT}"
    if [ -n "${COLOR_TERMINAL_DOWNLOAD_BASE:-}" ]; then
        base="${COLOR_TERMINAL_DOWNLOAD_BASE%/}"
    elif [ "$CT_VERSION" = latest ]; then
        base="https://github.com/$repo/releases/latest/download"
    else
        base="https://github.com/$repo/releases/download/$CT_VERSION"
    fi
    ct_fetch "$base/$CT_SUMS" "$CT_TMP/$CT_SUMS" \
        || ct_die "cannot fetch $base/$CT_SUMS — is '$CT_VERSION' a published release of $repo?"
    # Match the asset by name rather than running `sha256sum -c`, so a release that
    # later grows a second asset does not make this script fail on the file it did
    # not download. The leading '*' is what sha256sum writes in binary mode.
    CT_WANT=$(awk -v a="$CT_ASSET" '$2 == a || $2 == "*" a { print $1; exit }' "$CT_TMP/$CT_SUMS")
    [ -n "$CT_WANT" ] || ct_die "$CT_SUMS has no entry for $CT_ASSET"
    CT_URL="$base/$CT_ASSET"
}

main() {
    CT_VERSION=${COLOR_TERMINAL_VERSION:-latest}
    ct_prefix=${COLOR_TERMINAL_PREFIX:-${PREFIX:-}}
    ct_source=${COLOR_TERMINAL_SOURCE:-github}
    ct_dlonly=

    # Split our own options out of the ones that belong to `color-terminal --install`.
    # Rotating the positional list is the POSIX way to filter "$@" without arrays:
    # each kept argument is pushed to the back, each consumed one is dropped.
    n=$#
    while [ "$n" -gt 0 ]; do
        arg=$1; shift; n=$((n - 1))
        case "$arg" in
            v[0-9]*)           CT_VERSION=$arg ;;
            --version=*)       CT_VERSION=${arg#--version=} ;;
            --prefix=*)        ct_prefix=${arg#--prefix=} ;;
            --source=*)        ct_source=${arg#--source=} ;;
            --download-only=*) ct_dlonly=${arg#--download-only=} ;;
            -h|--help)         ct_usage; exit 0 ;;
            *)                 set -- "$@" "$arg" ;;
        esac
    done

    [ -n "$ct_prefix" ] || ct_prefix="$HOME/.local"
    # Absolute, and no trailing slash. The tool computes its own install target as
    # "$CT_PREFIX/bin/color-terminal" and compares it as a STRING against the path it
    # was invoked by (lib/install.sh: `if [ "$self" != "$bin" ]`). Two spellings of
    # one file make it try to install the file over itself, which fails, and the whole
    # install aborts. Not `pwd -P`: resolving symlinks would change the spelling too.
    case "$ct_prefix" in /*) ;; *) ct_prefix="$PWD/$ct_prefix" ;; esac
    while :; do case "$ct_prefix" in */) ct_prefix=${ct_prefix%/} ;; *) break ;; esac; done

    # color-terminal is a bash script. Checking here turns "installed but broken" into
    # a clear refusal before anything lands on disk.
    ct_have bash || ct_die 'color-terminal is a bash script and bash is not installed'

    CT_TMP=$(mktemp -d "${TMPDIR:-/tmp}/color-terminal.XXXXXX") || ct_die 'mktemp failed'
    trap 'rm -rf "$CT_TMP"' EXIT HUP INT TERM

    case "$ct_source" in
        github) ct_resolve_github ;;
        apps)   ct_resolve_apps ;;
        *)      ct_die "unknown --source '$ct_source' (want: github, apps)" ;;
    esac

    ct_say "downloading $CT_URL"
    ct_fetch "$CT_URL" "$CT_TMP/$CT_ASSET" || ct_die "download failed: $CT_URL"

    got=$(ct_sha256 "$CT_TMP/$CT_ASSET") \
        || ct_die 'no sha256sum, shasum or openssl here — refusing to install an unverified binary'
    [ "$CT_WANT" = "$got" ] || ct_die "CHECKSUM MISMATCH — do not run the downloaded file
  expected $CT_WANT
  got      $got"
    chmod 0755 "$CT_TMP/$CT_ASSET"
    ct_say "verified $("$CT_TMP/$CT_ASSET" --version 2>/dev/null || echo 'unknown version')"

    # Verified first, executable second, in place third: a truncated or tampered
    # download must never be executable at a stable path, not even briefly.
    if [ -n "$ct_dlonly" ]; then
        mkdir -p "$(dirname "$ct_dlonly")" || ct_die "cannot create $(dirname "$ct_dlonly")"
        cp "$CT_TMP/$CT_ASSET" "$ct_dlonly" && chmod 0755 "$ct_dlonly" \
            || ct_die "cannot write $ct_dlonly"
        ct_say "wrote $ct_dlonly"
        exit 0
    fi

    bin="$ct_prefix/bin/$CT_ASSET"
    mkdir -p "$ct_prefix/bin" || ct_die "cannot create $ct_prefix/bin"
    cp "$CT_TMP/$CT_ASSET" "$bin" && chmod 0755 "$bin" || ct_die "cannot write $bin"
    ct_say "installed $bin"

    # A warning, not an error: the shell hook calls the tool by absolute path (@BIN@ is
    # baked in at install time), so colours work either way. Only typing the command
    # yourself needs this.
    case ":${PATH:-}:" in
        *":$ct_prefix/bin:"*) ;;
        *) ct_warn "$ct_prefix/bin is not on your PATH. Colours will still work — the
  shell hook calls the tool by absolute path — but to run it by hand, add:
      export PATH=\"$ct_prefix/bin:\$PATH\"" ;;
    esac

    rm -rf "$CT_TMP"; trap - EXIT HUP INT TERM

    # Hand over to the installer that lives inside the artifact.
    #
    # --prefix is passed so the tool computes the same target path this script just
    # wrote to; it then recognises "already running from $bin" and skips copying itself.
    #
    # </dev/null because this script is being read from a pipe: a child that reads stdin
    # would swallow whatever of it is left. The escapes do not care — the tool opens
    # /dev/tty on its own fd (lib/emit.sh: ct_tty_init).
    exec "$bin" --install --prefix="$ct_prefix" "$@" </dev/null
}

main "$@"
