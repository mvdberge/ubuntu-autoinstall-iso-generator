#!/bin/bash
# Author: Martin Kaiser
# SPDX-License-Identifier: MIT
#
# MIT License
# Copyright (c) 2026 Martin Kaiser
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
set -e
timestamp=$(date +%Y-%m-%d__%H-%M)
start_time=$(date +%s)

# All known Ubuntu releases.
# Current releases + codenames: https://releases.ubuntu.com/
# The newest point release (e.g. 24.04.5 server vs. 24.04.5.1 desktop) is not
# listed here: it is resolved at runtime from the release's signed SHA256SUMS.
declare -A ubuntu_releases=(
  # codename: release version
  [jammy]="22.04"
  [noble]="24.04"
  [oracular]="24.10"   # EOL, served from old-releases.ubuntu.com
  [plucky]="25.04"     # EOL, served from old-releases.ubuntu.com
  [questing]="25.10"
  [resolute]="26.04"
  [stonking]="26.10"
)

# Ubuntu CD Image Automatic Signing Key (2012) <cdimage@ubuntu.com>, signs SHA256SUMS.
# Fingerprint cross-checked against https://ubuntu.com/tutorials/how-to-verify-ubuntu
script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
signing_keyring="${script_dir}/keys/ubuntu-cdimage-signing-key-2012.gpg"
signing_key_fpr="843938DF228D22F7B3742BC0D94AA3F0EFE21092"

usage() {
  echo "Usage: $0 <version> <flavor> [tty] [baudrate]"
  echo "  version  : codename (e.g. questing) or numeric (e.g. 25.10)"
  echo "  flavor   : server | desktop"
  echo "  tty      : serial console TTY (e.g. ttyS2). Omit to use the default kernel console (no serial redirection)."
  echo "  baudrate : serial console speed (e.g. 115200n8, default: 115200n8)"
  echo "  Known codenames: ${!ubuntu_releases[*]}"
  echo "  The ISO is extracted below \$TMPDIR (default /tmp), which needs about the ISO's size in free space."
  exit 1
}

[[ $# -lt 2 || $# -gt 4 ]] && usage

version_arg="$1"
flavor="$2"
console_tty="${3:-}"
console_baudrate="${4:-115200n8}"

# Resolve version_arg: accept codename or numeric version
if [[ -v ubuntu_releases["$version_arg"] ]]; then
  code_name="$version_arg"
  ubuntu_version="${ubuntu_releases[$code_name]}"
else
  # Treat as numeric version; find the matching codename for display
  ubuntu_version="$version_arg"
  code_name=""
  for cn in "${!ubuntu_releases[@]}"; do
    if [[ "${ubuntu_releases[$cn]}" == "$version_arg" ]]; then
      code_name="$cn"
      break
    fi
  done
  if [[ -z "$code_name" ]]; then
    echo "ERROR: version '${version_arg}' not found in known releases"
    exit 1
  fi
fi

case "$flavor" in
  server)  iso_suffix="live-server-amd64.iso" ;;
  desktop) iso_suffix="desktop-amd64.iso" ;;
  *)
    echo "ERROR: Unknown flavor '${flavor}'. Use 'server' or 'desktop'."
    exit 1
esac

# Desktop ISOs before 24.04 ship the Ubiquity installer, which ignores the
# 'autoinstall' kernel argument and the nocloud seed: the resulting ISO would
# boot into the interactive installer instead of installing unattended.
if [[ "$flavor" == desktop && "$(printf '%s\n' "$ubuntu_version" 24.04 | sort -V | head -n1)" != 24.04 ]]; then
  echo "ERROR: The Ubuntu ${ubuntu_version} desktop ISO does not support autoinstall (Ubiquity installer)."
  echo "       Use 'server' for ${ubuntu_version}, or desktop 24.04 or newer."
  exit 1
fi

output_iso="ubuntu_${ubuntu_version}_${flavor}"
if [[ -n "$console_tty" ]]; then
  console_tty_filename="$(printf '%s' "$console_tty" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]')"
  output_iso+="_${console_tty_filename}"
fi
output_iso+="_autoinstall_${timestamp}.iso"

for tool in xorriso wget gpgv sha256sum; do
  if ! command -v "$tool" &>/dev/null; then
    echo "ERROR: ${tool} not found. Install it with: sudo apt install ${tool/sha256sum/coreutils}"
    exit 1
  fi
done
if [[ ! -f "$signing_keyring" ]]; then
  echo "ERROR: signing key ${signing_keyring} not found"
  exit 1
fi

echo "Generating autoinstall provisioning ISO at ${timestamp} (Ubuntu ${ubuntu_version} ${code_name} ${flavor})"

# True if $2 is a valid signature of $1 made by the pinned Ubuntu CD image key.
verify_sums() {
  gpgv --status-fd 1 --keyring "$signing_keyring" "$2" "$1" 2>/dev/null |
    grep -q "^\[GNUPG:\] VALIDSIG ${signing_key_fpr} "
}

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

# ── Step 1: Fetch signed checksum list ───────────────────────────────────────
# SHA256SUMS decides which point release is the newest and which checksum the
# ISO must have. EOL releases move to old-releases.ubuntu.com. A cached copy
# keeps building from a cached ISO possible without network access.
sums_file="ubuntu-${ubuntu_version}-SHA256SUMS"
mirror=""
# Small files: fail fast instead of wget's default of 20 tries with 900 s read timeout
sums_wget=(wget -q --timeout=30 --tries=3)
for base in "https://releases.ubuntu.com/${ubuntu_version}" \
            "https://old-releases.ubuntu.com/releases/${ubuntu_version}"; do
  if "${sums_wget[@]}" -O "${sums_file}.part" "${base}/SHA256SUMS" &&
     "${sums_wget[@]}" -O "${sums_file}.gpg.part" "${base}/SHA256SUMS.gpg"; then
    if ! verify_sums "${sums_file}.part" "${sums_file}.gpg.part"; then
      rm -f "${sums_file}.part" "${sums_file}.gpg.part"
      echo "ERROR: invalid signature on ${base}/SHA256SUMS. Refusing to continue."
      exit 1
    fi
    mv "${sums_file}.part" "$sums_file"
    mv "${sums_file}.gpg.part" "${sums_file}.gpg"
    mirror="$base"
    break
  fi
done
rm -f "${sums_file}.part" "${sums_file}.gpg.part"

if [[ -z "$mirror" ]]; then
  if [[ ! -f "$sums_file" || ! -f "${sums_file}.gpg" ]]; then
    echo "ERROR: could not download SHA256SUMS for Ubuntu ${ubuntu_version} from releases.ubuntu.com or old-releases.ubuntu.com"
    exit 1
  fi
  echo "WARNING: could not download SHA256SUMS, using cached ${sums_file}"
  if ! verify_sums "$sums_file" "${sums_file}.gpg"; then
    echo "ERROR: invalid signature on cached ${sums_file}. Delete it and retry with network access."
    exit 1
  fi
fi

# Newest point release of the requested flavor, e.g. ubuntu-24.04.5.1-desktop-amd64.iso
source_iso=$(grep -oE "ubuntu-${ubuntu_version//./\\.}(\.[0-9]+)*-${iso_suffix//./\\.}\$" "$sums_file" | sort -V | tail -n1)
if [[ -z "$source_iso" ]]; then
  echo "ERROR: no ${iso_suffix} listed in SHA256SUMS for Ubuntu ${ubuntu_version}"
  exit 1
fi
expected_sha256=$(awk -v f="$source_iso" '$2 == f || $2 == "*" f {print $1}' "$sums_file")

# ── Step 2: Download source ISO (cached, checksum-verified) ──────────────────
# The download goes to a .part file (resumed with -c after an abort) and is only
# moved into place once its checksum matches, so a broken download never ends
# up in the cache.
iso_ok=""
if [[ -f "$source_iso" ]]; then
  echo "Verifying cached source ISO: $source_iso ..."
  if [[ "$(sha256_of "$source_iso")" == "$expected_sha256" ]]; then
    iso_ok=1
  else
    echo "WARNING: cached ${source_iso} does not match SHA256SUMS, downloading it again"
  fi
fi
if [[ -z "$iso_ok" ]]; then
  if [[ -z "$mirror" ]]; then
    echo "ERROR: ${source_iso} is not cached and the download server is unreachable"
    exit 1
  fi
  echo "Downloading Ubuntu ${ubuntu_version} ${flavor} from ${mirror}/${source_iso} ..."
  wget --show-progress -c -O "${source_iso}.part" "${mirror}/${source_iso}"
  echo "Verifying checksum ..."
  if [[ "$(sha256_of "${source_iso}.part")" != "$expected_sha256" ]]; then
    rm -f "${source_iso}.part"
    echo "ERROR: checksum mismatch for downloaded ${source_iso}. Removed it, please retry."
    exit 1
  fi
  mv "${source_iso}.part" "$source_iso"
fi

# ── Step 3: Set up work directory ────────────────────────────────────────────
# Honors $TMPDIR (default /tmp). The extracted ISO needs about as much space as
# the ISO itself, and /tmp is often a RAM-backed tmpfs: point TMPDIR at a disk
# if it is too small.
tmp_base="${TMPDIR:-/tmp}"
iso_bytes=$(stat -c %s "$source_iso")
needed_bytes=$(( iso_bytes + iso_bytes / 10 ))
# The output ISO (about the same size again) is written to the current directory
if [[ "$(stat -c %d "$tmp_base")" == "$(stat -c %d .)" ]]; then
  needed_bytes=$(( needed_bytes * 2 ))
fi
free_bytes=$(df --output=avail -B1 "$tmp_base" | tail -n1)
if (( free_bytes < needed_bytes )); then
  echo "ERROR: not enough free space in ${tmp_base}: $(( needed_bytes >> 20 )) MiB needed, $(( free_bytes >> 20 )) MiB available."
  echo "       Point TMPDIR at a larger disk, e.g.: TMPDIR=/var/tmp $0 $*"
  exit 1
fi
work_dir=$(mktemp -d "${tmp_base}/trecs_iso_${output_iso}.XXXXXX")
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

# ── Step 4: Extract ISO filesystem content ────────────────────────────────────
echo "Extracting ISO content to ${work_dir} ..."
if ! xorriso -osirrox on -dev "$source_iso" -extract / "$work_dir" 2>/dev/null; then
  echo "ERROR: extracting ${source_iso} failed (out of space in ${tmp_base}?)"
  exit 1
fi
chmod -R u+w "$work_dir"

# ── Step 5: Patch grub.cfg ────────────────────────────────────────────────────
# - timeout=0              : boot immediately, no interactive menu (headless)
# - autoinstall            : trigger subiquity unattended installer
# - ds=nocloud\;s=/cdrom/nocloud/ : point cloud-init at the seed dir baked into the ISO
#                            (the ';' must be backslash-escaped: GRUB's linux command
#                            parses an unescaped ';' as a statement separator, which
#                            would silently truncate the datasource arg and drop the seed path)
# - console=${console_tty},${console_baudrate} : route kernel output to the selected serial port (optional; omitted if no tty given)
# - toram                  : copy live system to RAM so the SSD can be wiped + reinstalled
extra_cmdline="autoinstall toram ds=nocloud\\\\;s=/cdrom/nocloud/"
if [[ -n "$console_tty" ]]; then
  console="${console_tty},${console_baudrate}"
  echo "Routing kernel console output to console=${console}"
  extra_cmdline+=" console=${console}"
else
  echo "No serial console configured; using default kernel console."
fi
escaped_cmdline="${extra_cmdline//\//\\/}"
echo "  escaped_cmdline=${escaped_cmdline}"

echo "Patching grub.cfg ..."
for grub_cfg in "${work_dir}/boot/grub/grub.cfg" "${work_dir}/boot/grub/loopback.cfg"; do
  [[ -f "$grub_cfg" ]] || continue
  sed -i \
    -e 's/^set timeout=.*/set timeout=0/' \
    -e 's/^set timeout_style=.*/set timeout_style=countdown/' \
    -e "/linux.*casper\\/vmlinuz/s/---/${escaped_cmdline} ---/" \
    "$grub_cfg"
done

# ── Step 6: Inject nocloud seed ───────────────────────────────────────────────
# user-data : the autoinstall / cloud-init config
# meta-data : required by the nocloud datasource (can be empty)
echo "Injecting autoinstall config ..."
mkdir -p "${work_dir}/nocloud"
cp "$(pwd)/user-data" "${work_dir}/nocloud/user-data"
touch "${work_dir}/nocloud/meta-data"

# ── Step 7: Repack with correct El Torito / EFI boot structure ───────────────
# Problem with the previous cp + xorriso-dev approach: xorriso growing the ISO
# 9660 section did not update the GPT, so the appended EFI partition became
# unreachable. Proxmox/UEFI boot then fails with "not a bootable disk".
#
# Fix: full remaster via xorriso -as mkisofs, which rebuilds the entire boot
# structure (MBR hybrid, El Torito BIOS entry, appended EFI partition + GPT).
#
# Boot parameters are derived dynamically from the source ISO so this works for
# any Ubuntu version and both server and desktop flavors.
#
# The '-e' EFI El Torito entry from the source ISO encodes the appended EFI
# partition at its original offset/size. We replace it with the generic
# 'appended_partition_2:::' form so xorriso resolves it against the newly
# appended EFI partition image in the output ISO.
echo "Repacking ISO (this takes a while) ..."

el_torito=$(xorriso -indev "$source_iso" -report_el_torito as_mkisofs 2>/dev/null | \
  sed "s|'--interval:appended_partition_2[^']*'|'--interval:appended_partition_2:::'|" | \
  tr '\n' ' ')

if ! eval "xorriso -as mkisofs $el_torito -r -V Ubuntu-Autoinstall -o '${output_iso}' '${work_dir}'" >/dev/null; then
  echo "ERROR: xorriso repack failed (see error output above)"
  exit 1
fi

elapsed=$(( $(date +%s) - start_time ))
printf "Successfully created %s after %02d:%02d:%02d elapsed.\n" \
  "$output_iso" $(( elapsed/3600 )) $(( elapsed%3600/60 )) $(( elapsed%60 ))


