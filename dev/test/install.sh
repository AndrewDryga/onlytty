#!/bin/sh
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/../.." && pwd)
SCRIPT="$ROOT/install.sh"
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT INT TERM

fail() {
  printf 'install test: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  file=$1
  text=$2
  grep -F "$text" "$file" >/dev/null 2>&1 || {
    printf '--- %s ---\n' "$file" >&2
    sed -n '1,160p' "$file" >&2
    fail "expected to find: $text"
  }
}

write_fake_tools() {
  fakebin=$1
  mkdir -p "$fakebin"

  cat >"$fakebin/uname" <<'SH'
#!/bin/sh
case "$1" in
  -s) printf '%s\n' Linux;;
  -m) printf '%s\n' x86_64;;
  *) exit 2;;
esac
SH

  cat >"$fakebin/curl" <<'SH'
#!/bin/sh
out=
effective=0
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2;;
    -w) effective=1; shift 2;;
    -*) shift;;
    *) url=$1; shift;;
  esac
done

if [ "$effective" = 1 ]; then
  printf '%s' 'https://github.com/AndrewDryga/onlytty/releases/tag/v9.9.9'
  exit 0
fi

[ -n "$out" ] || exit 2
case "$url" in
  */SHA256SUMS) printf '%s  %s\n' deadbeef onlytty-9.9.9-linux-amd64.tar.gz >"$out";;
  *) printf '%s\n' 'fake archive' >"$out";;
esac
SH

  cat >"$fakebin/sha256sum" <<'SH'
#!/bin/sh
printf '%s  %s\n' deadbeef "$1"
SH

  cat >"$fakebin/tar" <<'SH'
#!/bin/sh
outdir=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C) outdir=$2; shift 2;;
    *) shift;;
  esac
done

[ -n "$outdir" ] || exit 2
cat >"$outdir/onlytty" <<'BIN'
#!/bin/sh
: "${ONLYTTY_TEST_ARGV:?}"
{
  printf 'argc=%s\n' "$#"
  i=1
  for arg do
    printf 'arg%s=%s\n' "$i" "$arg"
    i=$((i + 1))
  done
} >"$ONLYTTY_TEST_ARGV"
exit "${ONLYTTY_TEST_EXIT:-23}"
BIN
chmod 0755 "$outdir/onlytty"
SH

  chmod 0755 "$fakebin/uname" "$fakebin/curl" "$fakebin/sha256sum" "$fakebin/tar"
}

run_install() {
  name=$1
  shift

  casedir="$TMPROOT/$name"
  fakebin="$casedir/bin"
  prefix="$casedir/prefix"
  argv="$casedir/argv"
  out="$casedir/out"
  err="$casedir/err"
  mkdir -p "$casedir"
  write_fake_tools "$fakebin"

  set +e
  PATH="$fakebin:/usr/bin:/bin" \
    PREFIX="$prefix" \
    ONLYTTY_TEST_ARGV="$argv" \
    ONLYTTY_TEST_EXIT=23 \
    sh "$SCRIPT" "$@" >"$out" 2>"$err"
  status=$?
  set -e

  printf '%s\n' "$casedir"
  return "$status"
}

casedir=
if casedir=$(run_install command --version 9.9.9 claude --continue); then
  fail "expected install-and-run to exit with the fake onlytty status"
else
  status=$?
  [ "$status" -eq 23 ] || fail "expected fake onlytty exit 23, got $status"
fi
assert_contains "$casedir/out" "Installed onlytty 9.9.9"
assert_contains "$casedir/out" "Starting: $casedir/prefix/onlytty -- claude --continue"
cat >"$casedir/expected" <<'EOF'
argc=3
arg1=--
arg2=claude
arg3=--continue
EOF
cmp -s "$casedir/expected" "$casedir/argv" || {
  printf '--- expected ---\n' >&2
  sed -n '1,80p' "$casedir/expected" >&2
  printf '--- actual ---\n' >&2
  sed -n '1,80p' "$casedir/argv" >&2
  fail "install-and-run argv mismatch"
}

if casedir=$(run_install delimiter --version 9.9.9 -- claude); then
  fail "expected delimiter install-and-run to exit with the fake onlytty status"
else
  status=$?
  [ "$status" -eq 23 ] || fail "expected fake onlytty exit 23, got $status"
fi
cat >"$casedir/expected" <<'EOF'
argc=2
arg1=--
arg2=claude
EOF
cmp -s "$casedir/expected" "$casedir/argv" || fail "delimiter argv mismatch"

bad="$TMPROOT/bad-option"
mkdir -p "$bad"
set +e
PREFIX="$bad/prefix" sh "$SCRIPT" --versoin 9.9.9 >"$bad/out" 2>"$bad/err"
status=$?
set -e
[ "$status" -ne 0 ] || fail "expected unknown installer option to fail"
assert_contains "$bad/err" "unknown option: --versoin"
[ ! -e "$bad/prefix/onlytty" ] || fail "unknown option should not install"

help="$TMPROOT/help"
mkdir -p "$help"
sh "$SCRIPT" --help >"$help/out"
assert_contains "$help/out" "curl -fsSL https://onlytty.com/install.sh | sh -s -- claude"
