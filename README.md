# mbp113-kernel73-kit

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Free and open source](https://img.shields.io/badge/Free%20and%20open%20source-brightgreen.svg)](LICENSE)
[![Platform: MacBookPro11,3](https://img.shields.io/badge/platform-MacBook%20Pro%2011%2C3%20(Late%202013)-lightgrey.svg)](#tested-on)

Fixes for what **Linux 7.3** broke on the **MacBook Pro 11,3** (Late 2013, 15"
Retina, CS4208 audio, GT 750M): quiet, tinny speakers with no bass, and fan
control that stops working.

| Problem on kernel 7.3+ | Cause | Fix |
|---|---|---|
| Speakers quiet, tinny, no bass (headphones fine) | `82cfab6a5262` maps PCI SSID 8086:7270 to the MacBook Air 6 pin table, which disables speaker pin 0x13 (plus the mic jack and SPDIF) | An HDA patch file built from **this Mac's own BIOS pins** (`/usr/lib/firmware/cs4208-mbp113-pins.fw`) plus `/etc/modprobe.d/cs4208-mbp113.conf` |
| mbpfan: "could not detect any fan"; the Mac runs hot | `94f5081d3592` moved the applesmc fan files to `hwmon/hwmonN/` (`_output` → `_target`, `_manual` → `pwmN_enable`) | **Superseded:** upstream mbpfan 2.5.0 fixes this and also restores fan speeds after resume. Install it with [mbp-resume-fix](https://github.com/doug445/mbp-resume-fix) `mbpfan/install-mbpfan.sh`. If it's installed, this kit leaves it alone. The kit's old patched build (`files/`: prebuilt binary, patch, source tarball) is only used when no mbpfan ≥ 2.5.0 is present. |
| Power Bolt fan buttons / nouveau-smi fan readout dead | same applesmc change | Fixed versions, installed only if the tool is already present |

## Usage

```bash
bash diagnose.sh                   # what's broken; no sudo, changes nothing
sudo bash install.sh --check       # preflight; changes nothing
sudo bash install.sh               # install
# reboot (needed for the speaker fix), then:
bash diagnose.sh                   # should end with NOTHING BROKEN
```

Undo: `sudo bash install.sh --uninstall`. Replaced files are kept as
`*.pre-kernel73` and restored on uninstall. Uninstall only ever removes the
kit's own mbpfan build, never an upstream mbpfan ≥ 2.5.0.

The scripts are always run with `bash`, so lost exec bits (for example after
copying the kit to an exFAT USB stick) don't matter.

## Speaker fix: how it's safe

`install.sh` only writes the speaker patch when all of these are true:

- the codec is a CS4208 with subsystem `0x106b5e00` (the MacBook Pro 11,3),
- the kernel has `CONFIG_SND_HDA_PATCH_LOADER`,
- this Mac's BIOS pin 0x13 really is the speaker (`0x90100112`), with the
  expected 19 pins, and
- no other `/etc/modprobe.d` file already sets `snd-hda-intel patch=`.

The patch is generated from the machine's own `init_pin_configs`, so it restores
exactly what the firmware set up. On kernels without the bug it's harmless.

`files/upstream-report.txt` is a regression report drafted for the ALSA
maintainers, with the bisect, the pin tables before and after, and the
workaround.

## Status (2026-11-21)

- **Speakers:** still needed on 7.3.4. The kernel still overrides pin 0x13 to
  `0x500000f0`.
- **Fans:** fixed upstream in mbpfan 2.5.0 (2026-11-17). Use that.
- The scripts treat `/usr/local/sbin/powerbolt` and `/usr/local/bin/powerbolt`
  as one file on Fedora 42+, where `sbin` is a symlink to `bin`.

## GPU driver: use nouveau, never NVIDIA's driver on Kepler

The GT 750M is a **Kepler** GPU. **Use the open-source nouveau driver and don't
install NVIDIA's proprietary driver on these Macs.** The only NVIDIA branch that
still supports Kepler is the end-of-life 470xx legacy driver. An identical
MacBook Pro running it became unusable, with KWin compositor corruption and
other major problems. The test machine has always run nouveau, and this kit was
developed and tested on nouveau only.

## Tested on

- MacBookPro11,3 (Late 2013, i7-4850HQ, GT 750M on nouveau), Fedora 44 with
  kernel 7.3.3, and Fedora 45 with kernel 7.3.4.

## Related projects

Also made for the MacBook Pro 11,3 on Linux (nouveau, Plasma 6):

- [mbp-resume-fix](https://github.com/doug445/mbp-resume-fix): fixes what closing and reopening the lid breaks, a CPU stuck at 800 MHz (BD_PROCHOT) and fans stuck at minimum, and installs upstream mbpfan 2.5.0.
- [matrixrain-plasma6](https://github.com/doug445/matrixrain-plasma6): a Matrix rain wallpaper for Plasma 6, with the glow removed and animation that stops while a maximized window covers it.

## License

The kit's own scripts and tools (`install.sh`, `diagnose.sh`,
`files/powerbolt`, `files/nouveau-smi`) are MIT, see [LICENSE](LICENSE).

The mbpfan files in `files/` (`mbpfan`, `mbpfan-kernel73-hwmon.patch`,
`mbpfan-src-patched.tar.gz`, `mbpfan.conf`, `mbpfan.service`) come from
[linux-on-mac/mbpfan](https://github.com/linux-on-mac/mbpfan) and are
**GPL-3.0**, see [files/COPYING.mbpfan](files/COPYING.mbpfan). The complete
corresponding source for the prebuilt `files/mbpfan` is
`files/mbpfan-src-patched.tar.gz`.
