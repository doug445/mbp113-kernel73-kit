#!/usr/bin/env bash
# diagnose.sh — what does kernel 7.3+ break on this MacBookPro11,3? No sudo, changes nothing.
#   bash diagnose.sh
set -u
bad()  { echo "  BROKEN  $*"; NB=$((NB + 1)); }
good() { echo "  ok      $*"; }
info() { echo "  info    $*"; }
NB=0
SMC=/sys/devices/platform/applesmc.768

. /etc/os-release
echo "== machine"
info "$(/usr/bin/cat /sys/class/dmi/id/product_name 2>/dev/null), Fedora $VERSION_ID, kernel $(/usr/bin/uname -r)"
[ "$(/usr/bin/cat /sys/class/dmi/id/product_name 2>/dev/null)" = MacBookPro11,3 ] || info "this kit was made on a MacBookPro11,3"

echo "== speakers (CS4208 codec)"
HW=""
for h in /sys/class/sound/hwC*D*; do
    [ "$(/usr/bin/cat "$h/chip_name" 2>/dev/null)" = CS4208 ] && { HW=$h; break; }
done
if [ -z "$HW" ]; then
    info "no CS4208 codec found; speaker fix not applicable"
else
    info "$HW: subsystem $(/usr/bin/cat "$HW/subsystem_id")"
    l=$(/usr/bin/journalctl -k -b --no-pager -q -o cat 2>/dev/null | /usr/bin/grep 'autoconfig for CS4208' | /usr/bin/tail -1)
    p=$(/usr/bin/journalctl -k -b --no-pager -q -o cat 2>/dev/null | /usr/bin/grep 'CS4208: picked' | /usr/bin/tail -1)
    [ -n "$p" ] && info "${p#*hdaudioC?D?: }"
    d13=$(/usr/bin/awk '$1=="0x13"{print $2}' "$HW/driver_pin_configs" 2>/dev/null)
    u13=$(/usr/bin/awk '$1=="0x13"{print $2}' "$HW/user_pin_configs" 2>/dev/null)
    i13=$(/usr/bin/awk '$1=="0x13"{print $2}' "$HW/init_pin_configs" 2>/dev/null)
    info "pin 0x13 (2nd speaker output): BIOS ${i13:-?}  driver ${d13:--}  user ${u13:--}"
    case "$l" in
        *"line_outs=2 (0x12/0x13"*) good "both speaker outputs active" ;;
        *"line_outs=1 (0x12/"*) bad "only one speaker output (quiet, tinny, no bass): kernel 7.3 MacBook Air pin table" ;;
        "") info "can't read the kernel log (journalctl -k); judge by pin 0x13 above" ;;
        *) info "${l#*hdaudioC?D?: }" ;;
    esac
    [ -e /usr/lib/firmware/cs4208-mbp113-pins.fw ] && good "speaker pin patch installed" || info "speaker pin patch not installed"
fi

echo "== fans"
if [ ! -d "$SMC" ]; then
    info "no applesmc device"
else
    if [ -e "$SMC/fan1_input" ]; then FAN=$SMC; info "applesmc legacy layout (kernel <= 7.2)"
    else FAN=$(/usr/bin/ls -d "$SMC"/hwmon/hwmon* 2>/dev/null | /usr/bin/head -1); info "applesmc hwmon layout (kernel 7.3+): $FAN"; fi
    info "fans $(/usr/bin/cat "$FAN/fan1_input" 2>/dev/null)/$(/usr/bin/cat "$FAN/fan2_input" 2>/dev/null) rpm (max $(/usr/bin/cat "$FAN/fan1_max" 2>/dev/null)/$(/usr/bin/cat "$FAN/fan2_max" 2>/dev/null))"
    t=$(/usr/bin/sensors -u coretemp-isa-0000 2>/dev/null | /usr/bin/awk '/temp1_input/{print int($2); exit}')
    [ -n "$t" ] && info "CPU package ${t} °C"
    if [ ! -x /usr/sbin/mbpfan ] && [ ! -x /usr/bin/mbpfan ]; then
        bad "mbpfan not installed: the SMC alone runs the fans (late and slow)"
    else
        M=$(command -v mbpfan || echo /usr/sbin/mbpfan)
        if /usr/bin/systemctl is-active --quiet mbpfan.service; then good "mbpfan running ($M)"
        else bad "mbpfan installed but not running: $(/usr/bin/journalctl -u mbpfan -b -n 50 --no-pager -o cat 2>/dev/null | /usr/bin/grep -m1 -iE 'could not|error|fail')"; fi
        # Upstream mbpfan 2.5.0 (2026-11-17) supports the hwmon layout itself and
        # also restores fan speeds after resume. "Ignoring fan %d" comes from its
        # commit 4760a26 and survives stripping, so it identifies >= 2.5.0.
        if /usr/bin/grep -qa 'Ignoring fan %d' "$M"; then
            good "mbpfan is upstream >= 2.5.0 (hwmon layout + restores fan speeds after resume)"
        elif /usr/bin/grep -qa 'applesmc hwmon interface' "$M"; then
            good "mbpfan is the kernel-7.3 patched build (kit)"
            info "superseded by upstream mbpfan 2.5.0, which also restores fan speeds after resume:"
            info "  https://github.com/doug445/mbp-resume-fix  ->  sudo bash mbpfan/install-mbpfan.sh"
        elif [ "$FAN" != "$SMC" ]; then
            bad "mbpfan is unpatched: on this kernel it finds 'no fans'"
        else
            info "mbpfan unpatched (fine on this kernel)"
        fi
    fi
    for n in 1 2; do [ -e "$FAN/pwm${n}_enable" ] && info "pwm${n}_enable=$(/usr/bin/cat "$FAN/pwm${n}_enable") (1 = mbpfan, 2 = SMC)"; done
fi

echo "== tools"
# On Fedora 42+ /usr/local/sbin is a symlink to bin: same file, check it once.
seen=" "
for pb in /usr/local/bin/powerbolt /usr/local/sbin/powerbolt; do
    [ -e "$pb" ] || continue
    real=$(/usr/bin/readlink -f "$pb")
    case "$seen" in *" $real "*) continue ;; esac
    seen="$seen$real "
    /usr/bin/grep -q HWMON_FANS "$pb" && good "$pb fixed" || bad "$pb uses the old fan paths (fan buttons don't work on 7.3)"
done
[ -e /usr/local/bin/powerbolt ] || [ -e /usr/local/sbin/powerbolt ] || info "Power Bolt not installed (skipped)"
if [ -e "$HOME/.local/bin/nouveau-smi" ]; then
    /usr/bin/grep -q 'hwmon/hwmon' "$HOME/.local/bin/nouveau-smi" && good "nouveau-smi fixed" || bad "nouveau-smi can't see the fans on 7.3"
else
    info "nouveau-smi not installed (skipped)"
fi

echo
[ "$NB" = 0 ] && echo "NOTHING BROKEN" || echo "$NB problem(s). Fix: sudo bash $(cd -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")" && pwd)/install.sh"
