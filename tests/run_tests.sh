#!/bin/bash
# Tests for generate_autoinstall_iso.sh
#   Part A: the real script, real signing key and the real Ubuntu servers
#           (needs network; SHA256SUMS is fetched, ISO downloads are only logged)
#   Part B: a copy with a throwaway test key and a tiny ISO, full build offline
# Usage: tests/run_tests.sh [repo-dir]
# Run directories go below $TMPDIR (default /tmp) and are removed on success.
set -u
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
repo=$(readlink -f "${1:-$here/..}")
T=$(mktemp -d "${TMPDIR:-/tmp}/autoinstall-tests.XXXXXX")
pass=0
fail=0

ok()  { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }
# expect <description> <condition...>
expect() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has()    { grep -qF -- "$2" "$1"; }
has_re() { grep -qE -- "$2" "$1"; }
rc_is()  { [[ "$(cat "$1/rc")" == "$2" ]]; }

# ── Part A ────────────────────────────────────────────────────────────────────
A="$T/a"
mkdir -p "$A/bin"
# wget stub: passes SHA256SUMS through to the real wget, logs ISO URLs instead
# of downloading them. OFFLINE=1 fails everything, TAMPER=1 alters SHA256SUMS.
cat > "$A/bin/wget" <<'EOF'
#!/bin/bash
url="${*: -1}"
out=""
prev=""
for a in "$@"; do [[ "$prev" == -O ]] && out="$a"; prev="$a"; done
case "$url" in
  *.iso) echo "$url" >> "$ISO_LOG"; exit 8 ;;
esac
[[ -n "${OFFLINE:-}" ]] && exit 4
/usr/bin/wget "$@" || exit $?
if [[ -n "${TAMPER:-}" && "$url" == */SHA256SUMS ]]; then
  sed -i '1s/^./0/' "$out"
fi
EOF
chmod +x "$A/bin/wget"

# run_a <dir> <args...>: runs the real script in <dir>, output in <dir>/out
run_a() {
  local d=$1; shift
  mkdir -p "$d"
  : > "$d/iso_log"
  (cd "$d" && PATH="$A/bin:$PATH" ISO_LOG="$d/iso_log" bash "$repo/generate_autoinstall_iso.sh" "$@" > "$d/out" 2>&1)
  echo $? > "$d/rc"
}

echo "Part A: resolving ISOs against the real Ubuntu servers"
rel="https://releases\.ubuntu\.com"
old="https://old-releases\.ubuntu\.com/releases"
while read -r version flavor url_re; do
  d="$A/res_${version}_${flavor}"
  run_a "$d" "$version" "$flavor"
  expect "$version $flavor -> $(head -n1 "$d/iso_log")" has_re "$d/iso_log" "^${url_re}\$"
done <<EOF
jammy server ${rel}/22\.04/ubuntu-22\.04(\.[0-9]+)*-live-server-amd64\.iso
noble server ${rel}/24\.04/ubuntu-24\.04(\.[0-9]+)*-live-server-amd64\.iso
noble desktop ${rel}/24\.04/ubuntu-24\.04(\.[0-9]+)*-desktop-amd64\.iso
24.04 desktop ${rel}/24\.04/ubuntu-24\.04(\.[0-9]+)*-desktop-amd64\.iso
oracular server ${old}/24\.10/ubuntu-24\.10(\.[0-9]+)*-live-server-amd64\.iso
oracular desktop ${old}/24\.10/ubuntu-24\.10(\.[0-9]+)*-desktop-amd64\.iso
plucky server ${old}/25\.04/ubuntu-25\.04(\.[0-9]+)*-live-server-amd64\.iso
plucky desktop ${old}/25\.04/ubuntu-25\.04(\.[0-9]+)*-desktop-amd64\.iso
questing server (${rel}|${old})/25\.10/ubuntu-25\.10(\.[0-9]+)*-live-server-amd64\.iso
questing desktop (${rel}|${old})/25\.10/ubuntu-25\.10(\.[0-9]+)*-desktop-amd64\.iso
resolute server ${rel}/26\.04/ubuntu-26\.04(\.[0-9]+)*-live-server-amd64\.iso
resolute desktop ${rel}/26\.04/ubuntu-26\.04(\.[0-9]+)*-desktop-amd64\.iso
stonking server ${rel}/26\.10/ubuntu-26\.10(\.[0-9]+)*-live-server-amd64\.iso
26.10 desktop ${rel}/26\.10/ubuntu-26\.10(\.[0-9]+)*-desktop-amd64\.iso
EOF
d="$A/res_noble_server"
expect "signature verified, SHA256SUMS cached" test -s "$d/ubuntu-24.04-SHA256SUMS"
expect "failed download leaves no ISO in the cache" test -z "$(find "$d" -maxdepth 1 -name '*.iso')"

echo "Part A: arguments and desktop < 24.04"
d="$A/jammy_desktop"; OFFLINE=1 run_a "$d" jammy desktop
expect "jammy desktop is rejected" rc_is "$d" 1
expect "jammy desktop names Ubiquity" has "$d/out" "Ubiquity installer"
expect "jammy desktop downloads nothing" test ! -s "$d/iso_log"
d="$A/order_wrong"; OFFLINE=1 run_a "$d" server 26.04
expect "swapped arguments are rejected" has "$d/out" "version 'server' not found"

echo "Part A: without network"
d="$A/offline_nocache"; OFFLINE=1 run_a "$d" noble server
expect "offline without cache: clear message" has "$d/out" "could not download SHA256SUMS"
expect "offline without cache: exit 1" rc_is "$d" 1
d="$A/offline_cache"
mkdir -p "$d"
cp "$A/res_noble_server/ubuntu-24.04-SHA256SUMS"* "$d/"
OFFLINE=1 run_a "$d" noble server
expect "offline: cached SHA256SUMS are used" has "$d/out" "using cached ubuntu-24.04-SHA256SUMS"
expect "offline without ISO: clear message" has "$d/out" "is not cached and the download server is unreachable"
d="$A/offline_tampered"
mkdir -p "$d"
cp "$A/res_noble_server/ubuntu-24.04-SHA256SUMS"* "$d/"
sed -i '1s/^./0/' "$d/ubuntu-24.04-SHA256SUMS"
OFFLINE=1 run_a "$d" noble server
expect "tampered cached SHA256SUMS are rejected" has "$d/out" "invalid signature on cached"
expect "tampered cache: no ISO requested" test ! -s "$d/iso_log"

echo "Part A: tampering and broken cache"
d="$A/mitm"; TAMPER=1 run_a "$d" noble server
expect "tampered SHA256SUMS from the server are rejected" has "$d/out" "invalid signature on https://releases.ubuntu.com/24.04/SHA256SUMS"
expect "tampering: exit 1" rc_is "$d" 1
expect "tampering: nothing cached" test ! -e "$d/ubuntu-24.04-SHA256SUMS"
expect "tampering: no ISO requested" test ! -s "$d/iso_log"
d="$A/bad_cache"
mkdir -p "$d"
noble_iso=$(basename "$(head -n1 "$A/res_noble_server/iso_log")")
echo garbage > "$d/$noble_iso"
run_a "$d" noble server
expect "broken cached ISO is detected" has "$d/out" "does not match SHA256SUMS, downloading it again"
expect "broken cached ISO: download requested" has "$d/iso_log" "$noble_iso"
expect "broken cached ISO: run fails (wget stub)" rc_is "$d" 8

# ── Part B ────────────────────────────────────────────────────────────────────
echo "Part B: full build with a test key and a tiny ISO"
B="$T/b"
mkdir -p "$B/repo/keys" "$B/bin" "$B/mirror/24.04" "$B/isoroot/boot/grub" "$B/isoroot/casper" "$B/gnupg"
chmod 700 "$B/gnupg"
export GNUPGHOME="$B/gnupg"
gpg --batch -q --passphrase '' --quick-gen-key "Test Key <test@example.invalid>" rsa2048 sign never 2>/dev/null
test_fpr=$(gpg --with-colons --list-keys 2>/dev/null | awk -F: '$1 == "fpr" {print $10; exit}')
gpg --export "$test_fpr" > "$B/repo/keys/ubuntu-cdimage-signing-key-2012.gpg"
sed "s/^signing_key_fpr=.*/signing_key_fpr=\"${test_fpr}\"/" "$repo/generate_autoinstall_iso.sh" > "$B/repo/generate_autoinstall_iso.sh"
cp "$repo/user-data" "$B/repo/user-data"

cat > "$B/isoroot/boot/grub/grub.cfg" <<'EOF'
set timeout=30
menuentry "Try or Install Ubuntu Server" {
	linux	/casper/vmlinuz  ---
	initrd	/casper/initrd
}
EOF
echo kernel > "$B/isoroot/casper/vmlinuz"
iso_name="ubuntu-24.04.5-live-server-amd64.iso"
xorriso -as mkisofs -r -V TEST -o "$B/mirror/24.04/$iso_name" "$B/isoroot" 2>/dev/null
(
  cd "$B/mirror/24.04" || exit 1
  sha256sum -b "$iso_name"
  echo "1111111111111111111111111111111111111111111111111111111111111111 *ubuntu-24.04.4-live-server-amd64.iso"
  echo "2222222222222222222222222222222222222222222222222222222222222222 *ubuntu-24.04.5.1-desktop-amd64.iso"
  echo "3333333333333333333333333333333333333333333333333333333333333333 *ubuntu-24.04.5-wsl-amd64.wsl"
) > "$B/mirror/24.04/SHA256SUMS"
gpg --batch -q --detach-sign -o "$B/mirror/24.04/SHA256SUMS.gpg" "$B/mirror/24.04/SHA256SUMS" 2>/dev/null
unset GNUPGHOME

# wget stub: serves files from $B/mirror, logs ISO downloads, emulates -c
cat > "$B/bin/wget" <<'EOF'
#!/bin/bash
url="${*: -1}"
out=""
prev=""
cont=""
for a in "$@"; do
  [[ "$prev" == -O ]] && out="$a"
  [[ "$a" == -c ]] && cont=1
  prev="$a"
done
[[ "$url" == https://releases.ubuntu.com/* ]] || exit 8
src="$MIRROR/${url#https://releases.ubuntu.com/}"
[[ -f "$src" ]] || exit 8
[[ "$url" == *.iso ]] && echo "$url" >> "$ISO_LOG"
have=0
[[ -n "$cont" && -f "$out" ]] && have=$(stat -c %s "$out")
size=$(stat -c %s "$src")
if (( have >= size )); then exit 0; fi
if (( have > 0 )); then tail -c +"$((have + 1))" "$src" >> "$out"; else cp "$src" "$out"; fi
EOF
chmod +x "$B/bin/wget"

# run_b <dir> <args...>: runs the test copy in <dir> with $TMPDIR=<dir>/tmp
run_b() {
  local d=$1; shift
  mkdir -p "$d/tmp"
  cp "$B/repo/user-data" "$d/"
  : > "$d/iso_log"
  (cd "$d" && PATH="${EXTRA_PATH:+$EXTRA_PATH:}$B/bin:$PATH" MIRROR="$B/mirror" ISO_LOG="$d/iso_log" TMPDIR="$d/tmp" \
    bash "$B/repo/generate_autoinstall_iso.sh" "$@" > "$d/out" 2>&1)
  echo $? > "$d/rc"
}

d="$B/full"
run_b "$d" noble server ttyS2
expect "full build: exit 0" rc_is "$d" 0
expect "full build: newest server ISO picked" has "$d/iso_log" "/24.04/$iso_name"
expect "full build: ISO cached" test -f "$d/$iso_name"
expect "full build: no .part left" test ! -e "$d/$iso_name.part"
expect "full build: TMPDIR is used" has "$d/out" "Extracting ISO content to $d/tmp/trecs_iso_"
expect "full build: work dir cleaned up" test -z "$(ls -A "$d/tmp")"
out_iso=$(find "$d" -maxdepth 1 -name 'ubuntu_24.04_server_ttys2_autoinstall_*.iso' -print -quit)
expect "full build: output ISO created" test -n "$out_iso"
if [[ -n "$out_iso" ]]; then
  xorriso -osirrox on -indev "$out_iso" -extract /boot/grub/grub.cfg "$d/grub.cfg" -extract /nocloud/user-data "$d/user-data.out" 2>/dev/null
  expect "output ISO: grub.cfg patched" has "$d/grub.cfg" 'autoinstall toram ds=nocloud\;s=/cdrom/nocloud/ console=ttyS2,115200n8 ---'
  expect "output ISO: timeout=0" has "$d/grub.cfg" "set timeout=0"
  expect "output ISO: user-data embedded" cmp -s "$d/user-data.out" "$B/repo/user-data"
fi

run_b "$d" noble server
expect "second run: cached ISO is verified" has "$d/out" "Verifying cached source ISO"
expect "second run: no download" test ! -s "$d/iso_log"

d="$B/resume"
mkdir -p "$d"
head -c 100000 "$B/mirror/24.04/$iso_name" > "$d/$iso_name.part"
run_b "$d" noble server
expect "leftover .part: download resumes and succeeds" rc_is "$d" 0
expect "leftover .part: ISO cached afterwards" cmp -s "$d/$iso_name" "$B/mirror/24.04/$iso_name"

d="$B/corrupt_part"
mkdir -p "$d"
head -c "$(stat -c %s "$B/mirror/24.04/$iso_name")" /dev/zero > "$d/$iso_name.part"
run_b "$d" noble server
expect "corrupt .part: checksum mismatch reported" has "$d/out" "checksum mismatch"
expect "corrupt .part: removed" test ! -e "$d/$iso_name.part"
expect "corrupt .part: not moved into the cache" test ! -e "$d/$iso_name"
expect "corrupt .part: exit 1" rc_is "$d" 1

d="$B/nospace"
mkdir -p "$d/fakebin"
printf '#!/bin/bash\necho Avail\necho 1000\n' > "$d/fakebin/df"
chmod +x "$d/fakebin/df"
EXTRA_PATH="$d/fakebin" run_b "$d" noble server
expect "not enough space: clear message with TMPDIR hint" has "$d/out" "Point TMPDIR at a larger disk"
expect "not enough space: exit 1" rc_is "$d" 1

echo
echo "Result: ${pass} ok, ${fail} failed"
if (( fail == 0 )); then
  rm -rf "$T"
else
  echo "Run output kept in ${T}"
  exit 1
fi
