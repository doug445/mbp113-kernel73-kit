#!/usr/bin/env bash
# install.sh — kernel 7.3+ fixes for a MacBookPro11,3 (speakers + fan control).
#
#   bash diagnose.sh               see what's broken first (no sudo)
#   sudo bash install.sh --check   preflight only, changes nothing
#   sudo bash install.sh           install; reboot afterwards for the speaker fix
#   sudo bash install.sh --uninstall
#
# 1. Speakers: kernel 7.3 commit 82cfab6a5262 matches PCI SSID 8086:7270 to the
#    MacBook Air 6 pin table. That disables speaker pin 0x13 (quiet, tinny, no bass),
#    the mic jack and SPDIF. Fix: an HDA patch file restoring THIS Mac's BIOS pins
#    (generated here from init_pin_configs) + an snd-hda-intel patch= option.
# 2. Fans: kernel 7.3 commit 94f5081d3592 moved applesmc's fan files into
#    hwmon/hwmonN/ (fanN_output -> fanN_target, fanN_manual -> pwmN_enable).
#    mbpfan 2.4.0 then finds "no fans". Installs mbpfan (upstream master 64dfd35 +
#    files/mbpfan-kernel73-hwmon.patch). An existing /etc/mbpfan.conf is kept.
#    SUPERSEDED: upstream mbpfan 2.5.0 (2026-11-17) fixes this AND restores fan
#    speeds after resume. If it's installed, this step keeps it untouched; for new
#    installs prefer https://github.com/doug445/mbp-resume-fix mbpfan/install-mbpfan.sh
# 3. Power Bolt and nouveau-smi: replaced with fixed versions, only if already installed.
# Every replaced file is backed up as <file>.pre-kernel73.
set -u

HERE=$(cd -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")" && pwd)
F="$HERE/files"
STATE=/var/lib/mbp113-kernel73-kit
FW=/usr/lib/firmware/cs4208-mbp113-pins.fw
CONF=/etc/modprobe.d/cs4208-mbp113.conf
SMC=/sys/devices/platform/applesmc.768
MBPFAN=/usr/sbin/mbpfan
CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1

die() { echo "FAILED: $*" >&2; exit 1; }
ok()  { echo "  ok: $*"; }
skip(){ echo "  skip: $*"; }
smc_auto() {
    for p in "$SMC"/hwmon/hwmon*/pwm[12]_enable; do [ -w "$p" ] && echo 2 > "$p"; done
    for p in "$SMC"/fan[12]_manual; do [ -w "$p" ] && echo 0 > "$p"; done
}
backup() { [ -e "$1" ] && [ ! -e "$1.pre-kernel73" ] && /usr/bin/cp -a "$1" "$1.pre-kernel73"; return 0; }

[ "$(/usr/bin/id -u)" = 0 ] || die "run with sudo"
U=${SUDO_USER:-}
UH=""; [ -n "$U" ] && UH=$(/usr/bin/getent passwd "$U" | /usr/bin/cut -d: -f6)

# ------------------------------------------------------------------ uninstall
if [ "${1:-}" = "--uninstall" ]; then
    /usr/bin/rm -f "$FW" "$CONF"; echo "  speaker patch removed (takes effect at reboot)"
    if ! /usr/bin/grep -qa 'applesmc hwmon interface' "$MBPFAN" 2>/dev/null; then
        # Only ever undo the kit's own build. Upstream mbpfan >= 2.5.0 (or anything
        # else installed since) is left alone, and so is an old backup.
        echo "  mbpfan is not the kit build; leaving it alone"
    elif [ -e "$MBPFAN.pre-kernel73" ]; then
        /usr/bin/cp -a "$MBPFAN.pre-kernel73" "$MBPFAN"; echo "  previous mbpfan restored"
    elif [ -e "$STATE/mbpfan-new" ]; then
        /usr/bin/systemctl disable --now mbpfan.service 2>/dev/null; smc_auto
        /usr/bin/rm -f "$MBPFAN" /etc/systemd/system/mbpfan.service
        [ -e "$STATE/mbpfan-conf-new" ] && /usr/bin/rm -f /etc/mbpfan.conf
        echo "  mbpfan removed (it was not installed before)"
    fi
    seen=" "
    for f in /usr/local/bin/powerbolt /usr/local/sbin/powerbolt ${UH:+"$UH/.local/bin/nouveau-smi"}; do
        [ -e "$f.pre-kernel73" ] || continue
        real=$(/usr/bin/readlink -f "$f.pre-kernel73")
        case "$seen" in *" $real "*) continue ;; esac   # sbin -> bin: same file
        seen="$seen$real "
        /usr/bin/cp -a "$f.pre-kernel73" "$f" && echo "  restored $f"
    done
    /usr/bin/rm -rf "$STATE"
    /usr/bin/systemctl daemon-reload
    /usr/bin/systemctl is-enabled --quiet mbpfan.service 2>/dev/null && /usr/bin/systemctl restart mbpfan.service
    echo "DONE. Uninstalled. Reboot to drop the speaker patch."
    exit 0
fi

/usr/bin/pgrep -x 'dnf|dnf5|rpm' >/dev/null && die "a package manager is running"
for f in mbpfan mbpfan.service mbpfan.conf mbpfan-src-patched.tar.gz powerbolt nouveau-smi; do
    [ -e "$F/$f" ] || die "kit incomplete: missing files/$f"
done

# ------------------------------------------------------------------ 1 speakers
echo "== 1/3 speakers"
HW=""
for h in /sys/class/sound/hwC*D*; do
    [ "$(/usr/bin/cat "$h/chip_name" 2>/dev/null)" = CS4208 ] && { HW=$h; break; }
done
DO_SPK=0
if [ -z "$HW" ]; then
    skip "no CS4208 codec"
elif [ "$(/usr/bin/cat "$HW/subsystem_id")" != 0x106b5e00 ]; then
    skip "CS4208 subsystem $(/usr/bin/cat "$HW/subsystem_id") is not the MBP 11,3 one (0x106b5e00)"
elif ! /usr/bin/grep -q '^CONFIG_SND_HDA_PATCH_LOADER=y' "/lib/modules/$(/usr/bin/uname -r)/config" 2>/dev/null; then
    skip "kernel lacks CONFIG_SND_HDA_PATCH_LOADER"
elif /usr/bin/grep -rlsE 'snd.hda.intel.*patch=' /etc/modprobe.d/ | /usr/bin/grep -v "^$CONF$" | /usr/bin/grep -q .; then
    skip "another /etc/modprobe.d file already sets snd-hda-intel patch="
else
    i13=$(/usr/bin/awk '$1=="0x13"{print $2}' "$HW/init_pin_configs")
    [ "$i13" = 0x90100112 ] || die "this Mac's BIOS pin 0x13 is '$i13', not the speaker 0x90100112; not touching it"
    [ "$(/usr/bin/grep -c . "$HW/init_pin_configs")" = 19 ] || die "unexpected pin count in $HW/init_pin_configs"
    ok "codec CS4208 0x106b5e00, BIOS pin 0x13 = speaker"
    d13=$(/usr/bin/awk '$1=="0x13"{print $2}' "$HW/driver_pin_configs")
    [ -n "$d13" ] && [ "$d13" != "$i13" ] && echo "  this kernel overrides pin 0x13 with $d13: bug present" \
        || echo "  this kernel doesn't override pin 0x13 (patch is harmless, guards future kernels)"
    DO_SPK=1
fi

# ------------------------------------------------------------------ 2 fans
echo "== 2/3 fans"
[ -d "$SMC" ] || die "no applesmc device: not a Mac?"
# Upstream mbpfan 2.5.0 (2026-11-17) supports the hwmon layout itself AND
# restores fan speeds after resume, so it supersedes this kit's patched build.
# Never replace it. "Ignoring fan %d" comes from its commit 4760a26.
T=""
KEEP_MBPFAN=0
if [ -x "$MBPFAN" ] && /usr/bin/grep -qa 'Ignoring fan %d' "$MBPFAN"; then
    KEEP_MBPFAN=1
    ok "upstream mbpfan >= 2.5.0 already installed; keeping it (supersedes the kit build)"
else
    T=$(/usr/bin/mktemp -d) || die "mktemp"
    /usr/bin/install -m 0755 "$F/mbpfan" "$T/mbpfan" || die "stage mbpfan"
    if "$T/mbpfan" -h 2>&1 | /usr/bin/grep -q 'Usage'; then
        ok "prebuilt mbpfan runs here"
    else
        echo "  prebuilt mbpfan doesn't run here; building from files/mbpfan-src-patched.tar.gz"
        command -v make >/dev/null && command -v cc >/dev/null || die "need gcc + make to build mbpfan (dnf install gcc make)"
        /usr/bin/tar -C "$T" -xzf "$F/mbpfan-src-patched.tar.gz" || die "unpack source"
        /usr/bin/make -C "$T/src" >/dev/null 2>&1 || die "mbpfan build failed"
        /usr/bin/install -m 0755 "$T/src/bin/mbpfan" "$T/mbpfan" || die "stage built mbpfan"
    fi
    /usr/bin/grep -qa 'applesmc hwmon interface' "$T/mbpfan" || die "staged mbpfan is not the patched build"
    if [ -x "$MBPFAN" ]; then ok "existing mbpfan will be replaced (backup $MBPFAN.pre-kernel73)"; else ok "mbpfan will be newly installed"; fi
    echo "  note: prefer upstream mbpfan 2.5.0, which also restores fan speeds after resume:"
    echo "        https://github.com/doug445/mbp-resume-fix  ->  sudo bash mbpfan/install-mbpfan.sh"
fi
[ -e /etc/mbpfan.conf ] && ok "keeping existing /etc/mbpfan.conf" || ok "installing kit /etc/mbpfan.conf (55/62/78 °C)"

# ------------------------------------------------------------------ 3 tools
echo "== 3/3 Power Bolt / nouveau-smi"
PBS=""
seen=" "
for pb in /usr/local/bin/powerbolt /usr/local/sbin/powerbolt; do
    [ -e "$pb" ] || continue
    # Fedora 42+: /usr/local/sbin -> bin, so both names are one file. Handle it once.
    real=$(/usr/bin/readlink -f "$pb")
    case "$seen" in *" $real "*) continue ;; esac
    seen="$seen$real "
    /usr/bin/grep -q 'thermal monitor and cooling-profile helper' "$pb" || { skip "$pb is not this Power Bolt"; continue; }
    PBS="$PBS $pb"
done
[ -n "$PBS" ] && ok "will update:$PBS" || skip "Power Bolt not installed"
NSMI=""
[ -n "$UH" ] && [ -e "$UH/.local/bin/nouveau-smi" ] && NSMI="$UH/.local/bin/nouveau-smi"
[ -n "$NSMI" ] && ok "will update $NSMI" || skip "nouveau-smi not installed"

if [ "$CHECK" = 1 ]; then [ -n "$T" ] && /usr/bin/rm -rf "$T"; echo "== check passed, nothing changed"; exit 0; fi

# ------------------------------------------------------------------ install
echo "== installing"
/usr/bin/mkdir -p "$STATE" || die "mkdir $STATE"
if [ "$DO_SPK" = 1 ]; then
    {
        echo "# CS4208 pins for MacBookPro11,3 = this Mac's BIOS values (kernel 7.3 regression,"
        echo "# commit 82cfab6a5262). Generated by mbp113-kernel73-kit on $(/usr/bin/date +%F)."
        echo
        echo "[codec]"
        echo "$(/usr/bin/cat "$HW/vendor_id") $(/usr/bin/cat "$HW/subsystem_id") $(/usr/bin/basename "$HW" | /usr/bin/sed 's/.*D//')"
        echo
        echo "[pincfg]"
        /usr/bin/cat "$HW/init_pin_configs"
    } > "$FW" || die "write $FW"
    printf '%s\n' "# Kernel 7.3 CS4208 regression on MacBookPro11,3: restore BIOS pins (mbp113-kernel73-kit)" \
        "options snd-hda-intel patch=cs4208-mbp113-pins.fw,cs4208-mbp113-pins.fw,cs4208-mbp113-pins.fw" > "$CONF" \
        || die "write $CONF"
    /usr/sbin/restorecon -F "$FW" "$CONF"
    ok "speaker patch installed (active after reboot)"
fi

if [ "$KEEP_MBPFAN" = 1 ]; then
    ok "mbpfan left as is (upstream >= 2.5.0): $(/usr/bin/systemctl is-active mbpfan.service)"
else
    [ -x "$MBPFAN" ] || : > "$STATE/mbpfan-new"
    /usr/bin/systemctl stop mbpfan.service 2>/dev/null
    backup "$MBPFAN"
    /usr/bin/install -m 0755 -o root -g root "$T/mbpfan" "$MBPFAN" || { smc_auto; die "install mbpfan"; }
    /usr/bin/rm -rf "$T"
    if [ ! -e /etc/systemd/system/mbpfan.service ] && [ ! -e /usr/lib/systemd/system/mbpfan.service ]; then
        /usr/bin/install -m 0644 "$F/mbpfan.service" /etc/systemd/system/mbpfan.service || die "install unit"
    fi
    if [ ! -e /etc/mbpfan.conf ]; then
        /usr/bin/install -m 0644 "$F/mbpfan.conf" /etc/mbpfan.conf || die "install conf"
        : > "$STATE/mbpfan-conf-new"
    fi
    /usr/sbin/restorecon -F "$MBPFAN" /etc/mbpfan.conf /etc/systemd/system/mbpfan.service 2>/dev/null
    /usr/bin/systemctl daemon-reload
    /usr/bin/systemctl enable mbpfan.service >/dev/null 2>&1
    /usr/bin/systemctl reset-failed mbpfan.service 2>/dev/null
    /usr/bin/systemctl start mbpfan.service
    /usr/bin/sleep 4
    if /usr/bin/systemctl is-active --quiet mbpfan.service; then
        ok "mbpfan running"
    else
        smc_auto
        /usr/bin/journalctl -u mbpfan -n 6 --no-pager -o cat
        die "mbpfan did not stay up; fans handed back to the SMC"
    fi
fi

for pb in $PBS; do
    backup "$pb"; /usr/bin/install -m 0755 -o root -g root "$F/powerbolt" "$pb" || die "install $pb"
    /usr/sbin/restorecon -F "$pb"; ok "updated $pb"
done
if [ -n "$NSMI" ]; then
    backup "$NSMI"; /usr/bin/install -m 0755 -o "$U" -g "$(/usr/bin/id -gn "$U")" "$F/nouveau-smi" "$NSMI" || die "install nouveau-smi"
    ok "updated $NSMI"
fi

/usr/bin/sync
echo
echo "DONE. Fans: fixed now. Speakers: reboot, then run: bash $HERE/diagnose.sh"
