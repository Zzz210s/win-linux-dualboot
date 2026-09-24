# win-linux-dualboot

English | [简体中文](README.zh-CN.md)

A reproducible, reversible playbook for Windows 11 Pro + Kubuntu 26.04 LTS dual-boot on identical fresh devices.

This repository is a deployment playbook, not an installer. It ships the step manuals (three tracks, L0 to L5), the artifact contract each stage must leave behind, one script per step card (Windows-side PowerShell and Linux-side shell) with their shared contract libraries, and the partition, verification and risk registers that pin everything down. Every card names the script that judges it, and every script defaults to the safe direction: `--check` / `-Check` prints a verdict and writes nothing, and only an explicit `--apply` / `-Apply` (usually with `--yes` / `-Yes`) touches the system.

The material has two layers. The design documents ([docs/design/00-design.md](docs/design/00-design.md) plus its card-format and step-automation companions, and [docs/design/04-kubuntu-variant-design.md](docs/design/04-kubuntu-variant-design.md) for the Kubuntu switch) record *why* the design looks the way it does: target device class, four invariants, key decisions with the rejected alternatives, the recovery matrix and the 34-entry risk register. The manuals ([docs/00-overview.md](docs/00-overview.md) onwards) are the executable part: cards with a 做 / 看到 pass criterion and a 出错时 pointer.

Nothing in here has been executed on a real machine yet: all scripts are fixture-level verified only. See [Status](#status) before you trust a single command.

## Table of Contents

- [Background](#background)
- [Usage](#usage)
- [Three tracks](#three-tracks)
- [Repository layout](#repository-layout)
- [Invariants](#invariants)
- [Target device class](#target-device-class)
- [Partition layout](#partition-layout)
- [Rollback strategy and snap avoidance](#rollback-strategy-and-snap-avoidance)
- [Isolation and the shared disk](#isolation-and-the-shared-disk)
- [In-place recovery](#in-place-recovery)
- [Robustness measures](#robustness-measures)
- [Verification](#verification)
- [Risks](#risks)
- [Status](#status)
- [Contributing](#contributing)
- [License](#license)

## Background

Dual-boot guides usually fail in one of two ways:

1. They shrink partitions on a live production system. Shrink failures, "trying to move immovable files", BitLocker demanding a recovery key and "the installer cannot see my NVMe" all come from that step.
2. They leave the firmware boot order pointing at Linux. Whenever the Linux partitions are later formatted, the next reboot stops at `grub>` / `grub rescue>` and Windows will not start either.

This playbook assumes a clean-slate install instead, so the partition table is decided once rather than edited surgically later, and it treats "remove Linux safely" as a first-class procedure rather than an afterthought. The Linux side is a traditional apt-based system, which makes the trade-off explicit: packages install immediately (no layering, no reboot-to-apply), the LTS window is three years, but there is no one-command system rollback either — recovery is a package downgrade plus an in-place reinstall. snap packages are avoided outright. Both premises, and the full cause analysis, are in [docs/00-overview.md](docs/00-overview.md) and sections 1, 3 and 4 of the design document.

## Usage

Start at [docs/00-overview.md](docs/00-overview.md): it defines the tracks, the four invariants, the device parameter table (whose field names every manual reuses verbatim) and the stage-to-document mapping. Then walk your track in order, checking off [checklists/deploy.md](checklists/deploy.md) (L0 to L4) and [checklists/rollback.md](checklists/rollback.md) (L5) as you go.

| Track / stage | Manual | Artifact the stage must leave under `baseline/` |
|---|---|---|
| Shared base, L0 pre-install | [docs/01-firmware.md](docs/01-firmware.md) | `00-firmware.md` |
| Shared base, partitioning | [docs/02-partitioning.md](docs/02-partitioning.md) | partition record (`01-partitions.txt` for W/D, the partition section of `03-efi-layout.txt` for L) |
| W, L1 Windows install | [docs/03-windows.md](docs/03-windows.md) | `01-partitions.txt`, `01-activation.md` |
| W, L2 preflight and baseline (hard gate) | [docs/03-windows.md](docs/03-windows.md) | `02-preflight-report.md`, `02-esp-backup/`, `02-firmware-entries.txt`, `02-partitions.txt` |
| L, L3 Kubuntu install | [docs/04-kubuntu.md](docs/04-kubuntu.md) | `03-efi-layout.txt` |
| L / D, L4 first-boot convergence | [docs/05-first-boot.md](docs/05-first-boot.md) | `04-first-boot.md`, `04-robustness.md` |
| D, L5 decommission and rescue | [docs/07-rescue.md](docs/07-rescue.md) | checkoff in [checklists/rollback.md](checklists/rollback.md) |

Three rules govern the whole run:

- **A stage without its artifact is unfinished** and must not be followed by the next stage.
- **L2 is the only hard gate**: if the report ends with "结论: 禁止进入 L3" (a red item), do not continue to the Linux install.
- **Every stage is judged by observable output**, not by "it looked fine" — each card states what to run and what a pass (`看到:`) looks like.

Every step card also names its script, and the card ↔ script binding is machine-checked in both directions (`scripts/repo/check-docs.sh` rules C9b/C9c/C9d against `scripts/*/steps.tsv`). Scripts are read-only by default as described above; the Linux-side ones additionally require root and `--yes` for any write.

## Three tracks

The playbook is three tracks that share one base, so **either system can be installed on its own**:

| Track | Scenario | Machine steps | Content |
|---|---|---|---|
| Shared base | needed by all three tracks | about 3 | firmware settings, two install media, target-disk check |
| **W** | Windows only | about 5 | partition, install, activate, disable Fast Startup and hibernation, converge |
| **L** | Kubuntu only | about 6 | install, first boot (driver/mount/time/snap), converge, package-rollback drill |
| **D** | dual-boot | shared base + W + L + 4 coexistence increments | reserve 115 GiB, boot-invariant checks, `ntfs3` shared volume, decommission and rescue |

The four dual-boot-only increments are: the 115 GiB reservation, the boot-invariant check (`BootOrder` first entry is always Windows Boot Manager), the `ntfs3` shared volume, and the L5 decommission path. Everything else is shared with — or identical to — a single-system install.

## Repository layout

```
docs/                  the playbook, numbered in execution order (00 to 10)
docs/design/           why the design looks like this (decisions, risks, rejected options)
checklists/            deploy.md (L0-L4, three tracks) and rollback.md (L5) checkoff lists
scripts/windows/       per-card PowerShell scripts plus shared contract libraries
scripts/linux/         per-card Linux-side scripts plus shared contract libraries
scripts/repo/          self-checks for this repository (docs structure, script syntax)
templates/             diskpart script and fstab/GRUB/unattended-upgrades/journald/user-dirs snippets
baseline/              per-device artifacts, never committed (only README.md is tracked)
```

## Invariants

Every step obeys these four. They, not any particular tool, are what prevent a bootloader lockout.

| # | Invariant | Failure mode it prevents |
|---|---|---|
| I1 | `BootOrder` always lists **Windows Boot Manager first** | After the Linux partitions are deleted, the firmware still points at the now-missing `\EFI\ubuntu\shimx64.efi` and the machine stops at `grub rescue>` |
| I2 | Boot into Linux only through a **one-shot `BootNext`** (or the vendor boot-menu key), never by reordering `BootOrder` | A permanent ordering that nobody remembers to undo |
| I3 | Never overwrite `\EFI\Microsoft\`, never change the `{bootmgr}` path | A third party owning the Windows boot path, which then breaks on a future update |
| I4 | Before touching the partition table or firmware settings, have a usable baseline: BitLocker suspended, ESP imaged, firmware entries snapshotted | No way back except reinstalling |

I3 gets structural support here: Windows and Kubuntu each own a separate ESP, so a Windows update can only rewrite the ESP that holds `\EFI\Microsoft\` and cannot reach `\EFI\ubuntu\`.

The reason the invariants work is that the "stuck at the grub prompt" failure is not a broken GRUB — it is a stale firmware entry that still points at a deleted bootloader and sits ahead of Windows in the boot order. As long as I1 and I2 hold, the firmware falls through to Windows even after the Linux side has been wiped ([docs/00-overview.md](docs/00-overview.md)).

## Target device class

All of the following must hold:

- a single NVMe SSD of the nominal 1 TB class, UEFI + GPT. Capacity wording matters: a 1024 GB model yields about 953.7 GiB, which is what the partition table is built for; a 1000 GB model yields only about 931.3 GiB and shifts `D:` from about 635 GiB to about 613 GiB, with the other seven entries unchanged
- hybrid graphics (integrated plus a discrete NVIDIA or AMD GPU)
- a whole-disk format is acceptable: both systems are fresh installs, there is no "keep the existing system" path
- Windows 11 Pro on the Windows side, **Kubuntu 26.04 LTS** (Plasma 6.6, Wayland-only, Calamares installer, three-year LTS window through April 2029, kernel 7.0) on the Linux side

Documented deviations get either an adaptation branch (two or more disks, a disk far from 1 TB, discrete-GPU-only, a read-only shared mount, a shared-ESP fallback) or are explicitly **not supported** by v1: disk encryption, a locked VMD/RAID controller mode, a firmware that can only boot from the first disk, or a snapshot-based rollback stack. The device parameter table that absorbs vendor differences (`DISK`, `VENDOR`, `BOOT_MENU_KEY`, `DISK_MODEL`, `DISK_SIZE`, `UBUNTU_ESP_SIZE`, ...) is defined in [docs/00-overview.md](docs/00-overview.md) and is filled in once per device. The snap-avoidance policy (minimal install, purge leftovers, apt pin) is part of the contract, not an optional preference — see section 3 of [docs/design/04-kubuntu-variant-design.md](docs/design/04-kubuntu-variant-design.md).

## Partition layout

Eight entries on a nominal 1 TB NVMe (about 953 GiB usable):

| # | Partition | Size | Type | Role |
|---|---|---|---|---|
| 1 | ESP Windows | 2 GiB | EFI System (FAT32) | Windows only; holds `\EFI\Microsoft\` and `\EFI\BOOT\` |
| 2 | MSR | 16 MiB | Microsoft Reserved | Windows |
| 3 | Windows system `C:` | 200 GiB | NTFS | system and programs; the only partition formatted when reinstalling Windows |
| 4 | Windows data `D:` | approx. 635 GiB | NTFS | games, downloads, documents, container images; the dual-boot shared volume |
| 5 | ESP Ubuntu | 1 GiB | EFI System (FAT32) | Kubuntu's own ESP, holding `\EFI\ubuntu\`; mounted at `/boot/efi` |
| 6 | `/boot` | 1 GiB | ext4 | separate so a root-only reinstall can keep the kernel and the GRUB modules |
| 7 | Ubuntu root | approx. 113 GiB | ext4 | `/` (the Ubuntu default; btrfs is not needed because there is no snapshot stack) |
| 8 | WinRE | 1 GiB | Recovery | Windows recovery environment, at the end of the disk |

That is about 953 GiB in total (2 + 0.016 + 200 + 635 + 1 + 1 + 113 + 1). The Ubuntu side accounts for 115 GiB (1 + 1 + 113) and the shared data partition for roughly two thirds of the disk.

- **The three Ubuntu partitions are created later, inside the 115 GiB unallocated region reserved in L1.** The L1 `diskpart` script stops at `D:` and deliberately leaves the rest unallocated; the L3 Calamares installer cuts `ESP-Ubuntu` 1 GiB + `/boot` 1 GiB + root approx. 113 GiB out of that region.
- **The two ESPs are never shared.** Windows keeps its own 2 GiB ESP, Kubuntu gets its own 1 GiB ESP. Neither size may be shrunk by an installer.
- There is no swap partition: swapping is zram plus a 4 GiB swapfile, configured in L4, and hibernation is out of scope.
- The table is pre-built with `diskpart` ([templates/partitions.txt](templates/partitions.txt)), which is also why a whole-disk format is a prerequisite.

## Rollback strategy and snap avoidance

Kubuntu 26.04 LTS is a traditional, mutable system, and the playbook is explicit about what that buys and what it costs:

- **Packages install immediately.** `sudo apt install` takes effect at once; there is no read-only `/usr`, no layering step and no reboot-to-apply. System-level tools come straight from the archive.
- **The LTS window is three years (through April 2029)** with security updates only, so a release upgrade (`do-release-upgrade`) is a rare, planned event with its own card rather than a recurring chore.
- **Rollback is package-level plus in-place reinstall**: downgrade a single package with `apt install <pkg>=<version>` and freeze it with `apt-mark hold` ([scripts/linux/rollback-pkg.sh](scripts/linux/rollback-pkg.sh) lists available versions, holds and unholds); for system-level damage, reinstall in place (see [docs/07-rescue.md](docs/07-rescue.md)) — the data disk `D:` is untouched either way. There is no one-command system rollback on this track, and that trade-off was accepted up front.
- **snap is avoided as a set, not as a habit**: minimal install (S1), purge leftovers (S2) and an apt pin with `Pin-Priority: -1` (S3), plus a non-snap browser from Mozilla's official APT repository. Keeping `snapd` around is not an option: the `firefox` archive entry is a transitional package, and `do-release-upgrade` reintroduces snap on its own.
- **Deliberately not used (被否)**: `snapd`, `snapper` / `timeshift` / `grub-btrfs` / btrfs snapshots, ZFS root snapshots, and custom Secure Boot keys with self-signed drivers. NVIDIA runs on Ubuntu's officially pre-signed packages via `ubuntu-drivers`, so no key enrolment is needed.
- **Four rollback granularities**: single package <-> `rollback-pkg.sh`; configuration <-> the `.dbk.bak` copies each script leaves behind; baseline <-> the ESP backup plus firmware entries; stage <-> the L5 decommission path.

## Isolation and the shared disk

System and data are separated on both operating systems, so a crash on one side never costs you the other half of the machine:

- **Windows**: a 200 GiB system partition (`C:`) plus an approx. 635 GiB data partition (`D:`). Known folders (Desktop, Documents, Downloads, Pictures, Videos, Music), game libraries and container images are redirected to `D:`, so reinstalling Windows formats `C:` only. The split is deliberate: `C:` is the throwaway partition, `D:` is the one worth protecting.
- **Kubuntu**: an approx. 113 GiB root plus a separate 1 GiB `/boot`. Documents, downloads, pictures and desktop live on the shared volume, which is what keeps root small; `/home` is an ordinary directory on root, so backing up before a reinstall means copying `~` to the shared volume first.

`D:` is a **shared partition** rather than a private Windows volume: Windows accesses it natively, and Kubuntu mounts it read-write through the in-kernel `ntfs3` driver, so office files edited in Windows are reachable from Linux by switching systems — no copying, no transfer medium. Four conditions make it safe, and all four are preconditions rather than suggestions:

1. Fast Startup and hibernation disabled in Windows, otherwise NTFS stays in a dirty "hybrid shutdown" state and the Linux mount can fail or corrupt data.
2. No BitLocker or device encryption on `D:`, otherwise Linux cannot read it without extra tooling.
3. Fixed `uid`/`gid`/`umask` plus `windows_names` on the mount, because `ntfs3` has no POSIX permission bits (see [templates/fstab.snippet](templates/fstab.snippet)).
4. No work that depends on POSIX semantics on the shared volume: symlinks, hard links, case-sensitive renames and permission-bit-sensitive scripts stay on the Linux root, where those semantics exist.

Mounting is scripted ([scripts/linux/mount-shared.sh](scripts/linux/mount-shared.sh)) and the user-directory redirect for the Linux side is scripted too ([scripts/linux/xdg-redirect.sh](scripts/linux/xdg-redirect.sh)). Acceptance includes a bidirectional visibility test: write a marker in Windows, read it in Linux, then do it the other way round.

## In-place recovery

Both systems can be recovered **in place, on the original disk**, and the playbook treats that as a design goal rather than a hope:

- **Windows is broken** -> reinstall Windows formatting `C:` only; `D:`, the three Ubuntu partitions, MSR and WinRE are left untouched. The installer rebuilds `\EFI\Microsoft\` on the Windows ESP and may overwrite `\EFI\BOOT\bootx64.efi` there; the Ubuntu ESP is a different partition and is not affected.
- **Kubuntu is broken** -> copy `~` to the shared volume first, then reinstall Kubuntu formatting the root partition (ext4) only, keeping `/boot` and the Ubuntu ESP (mounted, never formatted), so the Windows side and the shared data survive.
- **Only the boot layer is broken** -> do not reinstall at all: restore the ESP from the L2 baseline, rebuild with `bcdboot`, clean the stale NVRAM entry ([docs/07-rescue.md](docs/07-rescue.md)).

The single most dangerous step in the whole flow — flagged as such at every place it appears — is **formatting the wrong ESP**: one of them holds `\EFI\Microsoft\`, and formatting it takes both systems down at once.

## Robustness measures

Losing a usable system costs far more than a reinstall, so the Kubuntu side gets nine measures (R1 to R9 in section 4.7 of the design document), each with a matching rollback point:

1. **Back up before any change**: `baseline/` and the `/etc` files each script is about to touch (`fstab`, `user-dirs.dirs`, GRUB defaults, apt fragments) get a `.dbk.bak` copy first;
2. **Package-level rollback**: `apt install <pkg>=<version>` plus `apt-mark hold`, with `--list` / `--check` / `--unhold` to inspect and release the freeze;
3. **A separate `/boot` plus retained old kernels**: a bad upgrade still leaves a bootable older kernel in the GRUB menu, and `BootNext` complements kernel selection without violating I2;
4. **A permanent rescue medium**: the Kubuntu install USB doubles as a live environment and is not recycled;
5. **Crash observability**: journald made persistent, so `journalctl -b -1` still works after a failed boot;
6. **OOM and memory pressure**: zram verified (preferably `systemd-zram-generator`, falling back to `zram-tools`) plus a 4 GiB swapfile, with `systemd-oomd` enabled;
7. **An always-on SSH rescue channel**, so a dead desktop can still be debugged from another machine;
8. **A conservative update policy**: `unattended-upgrades` installs security updates only and never reboots (`Automatic-Reboot "false"`);
9. **Disk health monitoring** through `smartmontools`/`smartd`, alongside the distribution's default filesystem check.

## Verification

Completion is judged by [docs/08-verification.md](docs/08-verification.md) being fully green, not by "it installed". That list has six groups:

- **A. boot safety (A1-A8)** — Windows Boot Manager first in `BootOrder` across repeated reboots, `\EFI\Microsoft\` identical to the L2 baseline, `{bootmgr}` path unchanged, no permanent ordering ever written, the ubuntu entry last in `BootOrder`, the two ESPs provably independent, plus a **reversible decommission drill**.
- **B. system function (B1-B11)** — Wayland session, GPU driver healthy with nouveau as fallback, Secure Boot still on and no self-signed keys, driver source proven to be the official Ubuntu package, `ntfs3` read-write mount with `nofail`, bidirectional visibility on the shared volume, **snap zero-residue** (empty `snap list`, no `snapd` in `dpkg -l`, no candidate in `apt-cache policy`, no `snapd` in a simulated `apt-get install firefox`), redirected home directories, RTC in UTC, Bluetooth pairing surviving a system switch, `fwupd` seeing the device.
- **C. dual-boot switching (C1-C3)** — one-shot `BootNext` into Linux without changing the default, one-command return to Windows, order stable after three switches.
- **D. removability (D1-D6)** — the L5 five-step decommission walked through, system/data isolation verified item by item, both in-place reinstall paths exercised, and the non-reinstall boot repair path proven.
- **E. records (E1-E5)** — artifacts complete and not committed, deviations written back to the device parameter table.
- **F. robustness (F1-F9)** — a real package-level rollback plus in-place reinstall drilled once (with data on `D:` still present afterwards), package rollback and pre-change backups usable, journald persistent, update policy as configured (security only, no auto-reboot), SSH rescue reachable, `systemd-oomd` and zram active, `smartd` reporting PASSED, and `nofail` present on the entries L4 writes while deliberately absent from `/boot/efi`.

The two read-only judges are [scripts/linux/verify-all.sh](scripts/linux/verify-all.sh) and [scripts/windows/verify-all.ps1](scripts/windows/verify-all.ps1); when both sides write a summary, point `--out-dir` / `-OutDir` somewhere other than the hand-filled device copy so they do not overwrite it. An unchecked item is only acceptable when it is recorded as a known exception with its impact written down; otherwise the device counts as unfinished. At least one device has to complete the whole set before the playbook can be called a reference implementation — no device has yet.

## Risks

The register — risk, consequence and mitigation — lives in section 9 of [docs/design/00-design.md](docs/design/00-design.md) (34 entries), with a per-stage quick lookup plus 23 symptom cards in [docs/10-faq.md](docs/10-faq.md). It covers Intel VMD/RAID controller modes, BitLocker recovery prompts triggered by partition or firmware changes, Windows updates rewriting its ESP or the SBAT/DBX episode, NVIDIA driver and Secure Boot signature handling on the Ubuntu side, Fast Startup plus dual NTFS writers, firmware that only boots from the first disk, picking the wrong target disk, RTC and Bluetooth state divergence, `ntfs3` write damage on the shared volume, Calamares pointing `/boot/efi` at the Windows ESP, `do-release-upgrade` or a transitional `firefox` package dragging snap back in, and hardware faults misdiagnosed as dual-boot problems.

The Windows activation route is also a risk entry: the playbook documents the flow and links to the upstream project rather than shipping any activation script, and the repository deliberately contains no such script. Install-media checks split by vendor reality: the Kubuntu ISO is compared against the official `SHA256SUMS` file, while the Windows ISO is limited to "official download domain plus official installer verification", because Microsoft does not publish SHA256 values for Windows 11 ISOs ([docs/01-firmware.md](docs/01-firmware.md)).

## Status

- **Design and manuals: complete.** The design documents are final, and all manuals ([docs/00-overview.md](docs/00-overview.md) through [docs/10-faq.md](docs/10-faq.md)) plus both checkoff lists are written.
- **Scripts: delivered, fixture-level verified only.** Every step card has its script and the card ↔ script binding is machine-checked. `bash scripts/repo/check-docs.sh` reports `check-docs: OK` (card format, references, links) and `bash scripts/repo/check-scripts.sh` reports `check-scripts: OK` (200-line limit, `bash -n` syntax, PowerShell parsing, printing `SKIP` for any checker not installed on the machine). **None of the scripts has been run on a target machine yet**, and the PowerShell helpers have not been executed against real hardware — their evidence is the fixture suites under `.superpowers/`, not a device.
- **No reference implementation yet.** No device has been taken through L0 to L5, so `baseline/` is empty apart from its README and the verification list has no completed instance. Treat the commands and pass criteria as reviewed-on-paper and fixture-tested, not as field-tested.
- **Per-device artifacts are never committed.** `baseline/*` is git-ignored except [baseline/README.md](baseline/README.md); it holds partition tables, ESP images, firmware entry snapshots and activation state, and it stays local.

## Contributing

The self-checks are the contract: run `bash scripts/repo/check-docs.sh` and `bash scripts/repo/check-scripts.sh` before committing, keep every manual's card format (`### NN-K` cards with 看到 / 坑 / 出错时 and a `脚本:` line) intact, keep each script under 200 lines, and never commit `baseline/*` artifacts, AI process files or emoji. When a change alters the design rather than a step, update [docs/design/00-design.md](docs/design/00-design.md) first and the manuals second.

## License

MIT, see [LICENSE](LICENSE).
