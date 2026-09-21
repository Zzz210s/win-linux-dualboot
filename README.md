# win-linux-dualboot

English | [简体中文](README.zh-CN.md)

A reproducible, reversible playbook for Windows 11 Pro + Ubuntu 26.04 LTS dual-boot on identical fresh devices.

This repository is a deployment playbook, not an installer. It ships the step-by-step manuals (L0 to L5), the artifact contract each stage must leave behind, four Windows PowerShell helpers, ten Ubuntu-side shell scripts and two repository self-check scripts, plus the partition, verification and risk registers that pin everything down. The goal is to walk a bare, single-disk machine to a working dual-boot install, and to be able to remove Linux again without ever breaking the Windows bootloader.

The material has two layers. The design document ([docs/design/00-design.md](docs/design/00-design.md)) records *why* the design looks the way it does: target device class, four invariants, key decisions with the rejected alternatives, the recovery matrix and the risk register. The manuals ([docs/00-overview.md](docs/00-overview.md) onwards) are the executable part: stages, steps, expected output, failure handling and rollback.

Nothing in here has been executed on a target machine yet. See [Status](#status) before you trust a single command.

## Table of Contents

- [Background](#background)
- [Usage](#usage)
- [Repository layout](#repository-layout)
- [Invariants](#invariants)
- [Target device class](#target-device-class)
- [Partition layout](#partition-layout)
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

This playbook assumes a clean-slate install instead, so the partition table is decided once rather than edited surgically later, and it treats "remove Linux safely" as a first-class procedure rather than an afterthought. Both premises, and the full cause analysis, are in [docs/00-overview.md](docs/00-overview.md) and sections 1 and 3 of the design document.

## Usage

Start at [docs/00-overview.md](docs/00-overview.md): it defines the four invariants, the device parameter table (whose field names every manual reuses verbatim) and the stage-to-document mapping. Then work through the stages in order, checking off [checklists/deploy.md](checklists/deploy.md) as you go.

| Stage | Manual | Artifact the stage must leave under `baseline/` |
|---|---|---|
| L0 pre-install preparation | [docs/01-firmware.md](docs/01-firmware.md) | `00-firmware.md` |
| L1 Windows install | [docs/03-windows.md](docs/03-windows.md) | `01-partitions.txt`, `01-activation.md` |
| L2 preflight and baseline (hard gate) | [docs/03-windows.md](docs/03-windows.md) | `02-preflight-report.md`, `02-esp-backup/`, `02-firmware-entries.txt`, `02-partitions.txt` |
| L3 Ubuntu install | [docs/04-silverblue.md](docs/04-silverblue.md) | `03-efi-layout.txt` |
| L4 first-boot convergence | [docs/05-first-boot.md](docs/05-first-boot.md) | `04-first-boot.md`, `04-robustness.md` |
| L5 decommission and rescue | [docs/07-rescue.md](docs/07-rescue.md) | checkoff in [checklists/rollback.md](checklists/rollback.md) |

Three rules govern the whole run:

- **A stage without its artifact is unfinished** and must not be followed by the next stage.
- **L2 is the only hard gate**: if the report ends with "结论: 禁止进入 L3" (a red item), do not continue to the Ubuntu install.
- **Every stage is judged by observable output**, not by "it looked fine" — each manual step states what to run and what a pass looks like.

The per-stage checkoff lists are [checklists/deploy.md](checklists/deploy.md) (L0 to L4) and [checklists/rollback.md](checklists/rollback.md) (L5: decommission, boot rescue, in-place reinstall, baseline rollback).

Scripts default to the safe direction: the Ubuntu-side scripts print a plan and change nothing unless `--apply` is passed as root, and the Windows-side helpers are read-only or dry-run (`-WhatIf`) until told otherwise. See the script headers in `scripts/windows/` and `scripts/linux/` for the exact options; each manual states which script belongs to which step.

## Repository layout

```
docs/                  the playbook, numbered in execution order (00 to 10)
docs/design/           why the design looks like this (decisions, risks, rejected options)
checklists/            deploy.md (L0-L4) and rollback.md (L5) checkoff lists
scripts/windows/       PowerShell helpers: preflight, ESP backup, BootNext, baseline verify
scripts/linux/         Ubuntu-side helpers: storage, hardening, graphics, mounts, first boot
scripts/repo/          self-checks for this repository (docs structure, script syntax)
templates/             diskpart script and fstab/GRUB/sysctl/config snippets
baseline/              per-device artifacts, never committed (only README.md is tracked)
```

## Invariants

Every step obeys these four. They, not any particular tool, are what prevent a bootloader lockout.

| # | Invariant | Failure mode it prevents |
|---|---|---|
| I1 | `BootOrder` always lists **Windows Boot Manager first** | After the Linux partitions are deleted, the firmware still points at the now-missing `\EFI\ubuntu\grubx64.efi` and the machine stops at `grub rescue>` |
| I2 | Boot into Linux only through a **one-shot `BootNext`** (or the vendor boot-menu key), never by reordering `BootOrder` | A permanent ordering that nobody remembers to undo |
| I3 | Never overwrite `\EFI\Microsoft\`, never change the `{bootmgr}` path | A third party owning the Windows boot path, which then breaks on a future update |
| I4 | Before touching the partition table or firmware settings, have a usable baseline: BitLocker suspended, ESP imaged, firmware entries snapshotted | No way back except reinstalling |

The reason these four work is that the "stuck at the grub prompt" failure is not a broken GRUB — it is a stale firmware entry that still points at a deleted bootloader and sits ahead of Windows in the boot order. As long as I1 and I2 hold, the firmware falls through to Windows even after the Linux side has been wiped ([docs/00-overview.md](docs/00-overview.md)).

## Target device class

All of the following must hold:

- a single NVMe SSD of the nominal 1 TB class — about 953 GiB usable, that is "close to, but under 1 TB", not 1 TiB — with UEFI + GPT
- hybrid graphics (integrated plus a discrete NVIDIA or AMD GPU)
- a whole-disk format is acceptable: both Windows and Linux are fresh installs, there is no "keep the existing system" path
- Windows 11 Pro on the Windows side, Ubuntu 26.04 LTS (GNOME 50, Wayland) on the Linux side

Documented deviations get either an adaptation branch (two or more disks, a disk far from 1 TB, discrete-GPU-only, a non-GNOME desktop, read-only shared mount) or are explicitly **not supported** by v1: an existing ESP smaller than 1 GiB, BitLocker already enabled and impossible to suspend, a locked VMD/RAID controller mode, disk encryption, or a firmware that can only boot from the first disk. The device parameter table that absorbs vendor differences (`DISK`, `VENDOR`, `BOOT_MENU_KEY`, `DISK_MODEL`, `DISK_SIZE`, ...) is defined in [docs/00-overview.md](docs/00-overview.md) and is filled in once per device.

## Partition layout

On a nominal 1 TB NVMe (about 953 GiB usable):

| # | Partition | Size | Type | Role |
|---|---|---|---|---|
| 1 | ESP | 2 GiB | EFI System (FAT32) | shared by Windows and Ubuntu; mounted at `/boot/efi` on the Linux side |
| 2 | MSR | 16 MiB | Microsoft Reserved | Windows |
| 3 | Windows system `C:` | 200 GiB | NTFS | system and programs; the only partition formatted when reinstalling Windows |
| 4 | Windows data `D:` | approx. 635 GiB | NTFS | data, games, container images; the dual-boot shared volume |
| 5 | Ubuntu root | 100 GiB | ext4 | `/` (kernels live in `/boot` inside root, no separate `/boot`) |
| 6 | Snapshot | 15 GiB | ext4 | `/snapshots`, pre-change snapshots |
| 7 | WinRE | 1 GiB | Recovery | Windows recovery environment, at the end of the disk |

That is about 953 GiB in total (2 + 0.016 + 200 + 635 + 100 + 15 + 1). The Linux side accounts for 115 GiB (root 100 + snapshot 15) and the shared data partition for roughly two thirds of the disk. There is no swap partition: swapping is handled later by zram plus a swapfile. The ESP size is not negotiable, because the Windows installer cannot be talked into creating a 2 GiB ESP after the fact — the table is pre-built with `diskpart` ([templates/partitions.txt](templates/partitions.txt)), which is also why a whole-disk format is a prerequisite.

## Isolation and the shared disk

System and data are separated on both operating systems, so a crash on one side never costs you the other half of the machine:

- **Windows**: a 200 GiB system partition (`C:`) plus an approx. 635 GiB data partition (`D:`). Known folders (Desktop, Documents, Downloads, Pictures, Videos, Music), game libraries and container images are redirected to `D:`, so reinstalling Windows formats `C:` only. The split is deliberate: `C:` is the throwaway partition, `D:` is the one worth protecting.
- **Ubuntu**: a 100 GiB root plus a dedicated 15 GiB snapshot partition. Documents, downloads, pictures and desktop live on the shared volume, which is what keeps root at 100 GiB; a bad upgrade rolls root back without destroying snapshot history.

`D:` is a **shared partition** rather than a private Windows volume: Windows accesses it natively, and Ubuntu mounts it read-write through the in-kernel `ntfs3` driver, so office files edited in Windows are reachable from Linux by switching systems — no copying, no transfer medium. Four conditions make it safe, and all four are preconditions rather than suggestions:

1. Fast Startup and hibernation disabled in Windows, otherwise NTFS stays in a dirty "hybrid shutdown" state and the Linux mount can fail or corrupt data.
2. No BitLocker or device encryption on `D:`, otherwise Linux cannot read it without extra tooling.
3. Fixed `uid`/`gid`/`umask` plus `windows_names` on the mount, because `ntfs3` has no POSIX permission bits (see [templates/fstab.snippet](templates/fstab.snippet)).
4. No work that depends on POSIX semantics on the shared volume: symlinks, hard links, case-sensitive renames and permission-bit-sensitive scripts stay on the Linux root, where those semantics exist.

Mounting is scripted ([scripts/linux/mount-shared.sh](scripts/linux/mount-shared.sh)) and the user-directory redirect for the Linux side is scripted too ([scripts/linux/xdg-redirect.sh](scripts/linux/xdg-redirect.sh)). Acceptance includes a bidirectional visibility test: write a marker in Windows, read it in Linux, then do it the other way round.

## In-place recovery

Both systems can be recovered **in place, on the original disk**, and the playbook treats that as a design goal rather than a hope:

- **Windows is broken** -> reinstall Windows formatting `C:` only; `D:`, all Linux partitions, the ESP, MSR and WinRE are left untouched, and the Windows installer rebuilds `\EFI\Microsoft\` itself.
- **Ubuntu is broken** -> reinstall Ubuntu formatting the root partition only, keeping the ESP (reused, never formatted) and the snapshot partition (mounted, not formatted), so the Windows side and the snapshot history survive.
- **Only the boot layer is broken** -> do not reinstall at all: restore the ESP from the L2 baseline, rebuild with `bcdboot`, and clean up the NVRAM entries.

The single most dangerous step in the whole playbook, and therefore stated as a first rule everywhere it applies, is formatting the ESP: it holds `\EFI\Microsoft\` too, so it takes both systems down at once. Procedures and pass criteria are in [docs/07-rescue.md](docs/07-rescue.md) and section 4 of [checklists/rollback.md](checklists/rollback.md).

## Robustness measures

Losing a working system costs far more than reinstalling it, so the Ubuntu side gets nine measures (design section 4.7, R1 to R9):

1. a pre-change snapshot before kernel, driver or major-version upgrades, not on a timer
2. a dedicated 15 GiB snapshot partition at `/snapshots`, so snapshots do not compete with root for space
3. old kernels kept, plus `GRUB_DEFAULT=saved` for one-shot booting, complementing firmware-level `BootNext`
4. a permanent rescue USB (the installation stick is kept, marked "verified working", not recycled)
5. persistent journald, so a crash or failed boot can still be diagnosed afterwards
6. zram plus an activated `systemd-oomd` against memory pressure
7. an always-on SSH rescue channel, so a dead desktop can be debugged from another machine
8. a conservative update policy: security updates only, never an automatic reboot, and kernel/GPU driver packages deliberately excluded
9. disk health monitoring (`smartmontools`/`smartd`) alongside the default ext4 `fsck` policy

Rollback points for each measure are listed in the design document; [scripts/linux/hardening.sh](scripts/linux/hardening.sh) and [scripts/linux/storage.sh](scripts/linux/storage.sh) implement the ones that touch the system.

## Verification

Completion is judged by [docs/08-verification.md](docs/08-verification.md) being fully green, not by "it installed". That list has six groups:

- **A. boot safety (A1-A7)** — Windows Boot Manager first in `BootOrder` across repeated reboots, `\EFI\Microsoft\` byte-identical to the L2 baseline, `{bootmgr}` path unchanged, no permanent ordering ever written, plus a **reversible decommission drill**: remove `\EFI\ubuntu\` temporarily, confirm the machine still boots Windows unattended with no `grub rescue>` prompt, then restore `\EFI\ubuntu\` from the copy saved in step 2 (the L2 baseline does **not** contain that subtree).
- **B. system function (B1-B10)** — Wayland session, GPU driver healthy with nouveau as fallback, Secure Boot still on, `ntfs3` read-write mount with `nofail`, bidirectional visibility on the shared volume, redirected home directories, RTC in UTC, Bluetooth pairing surviving a system switch, `fwupd` seeing the device.
- **C. dual-boot switching (C1-C4)** — one-shot `BootNext` into Linux without changing the default, one-command return to Windows, order stable after three switches.
- **D. removability (D1-D6)** — the L5 five-step decommission walked through, system/data isolation verified item by item, both in-place reinstall paths exercised, and the non-reinstall boot repair path proven.
- **E. records (E1-E5)** — artifacts complete and not committed, deviations written back to the device parameter table.
- **F. robustness (F1-F9)** — a real snapshot rollback drilled once, snapshot partition visible in `df`, old kernel bootable, journald persistent, update policy as configured, SSH rescue reachable, `systemd-oomd` and zram active, `smartd` reporting PASSED, `nofail` present on the three entries L4 writes (shared volume, /snapshots, swapfile) and deliberately absent from /boot/efi.

An unchecked item is only acceptable when it is recorded as a known exception with its impact written down; otherwise the device counts as unfinished. At least one device has to complete the whole set before the playbook can be called a reference implementation — no device has yet.

## Risks

Known failure classes are registered with mitigations in section 9 of [docs/design/00-design.md](docs/design/00-design.md) (34 entries), with a per-stage quick lookup in [docs/10-faq.md](docs/10-faq.md): Intel VMD/RAID controller modes, BitLocker recovery prompts triggered by partition or firmware changes, Windows updates rewriting the ESP or the SBAT/DBX episode that broke Linux booting, NVIDIA module signatures under Secure Boot, Fast Startup plus dual NTFS writers, firmware that only boots from the first disk, picking the wrong target disk during install, RTC and Bluetooth state divergence between the two systems, `ntfs3` write damage on the shared volume, and hardware faults misdiagnosed as dual-boot problems.

The Windows activation route is also a risk entry: the playbook documents the flow and links to the upstream project rather than shipping any activation script, and the repository deliberately contains no such script. Windows ISO checksums are limited to "official download domain plus official installer verification", because Microsoft does not publish SHA256 values for Windows 11 ISOs; only the Ubuntu ISO is compared against the published `SHA256SUMS` ([docs/01-firmware.md](docs/01-firmware.md)).

## Status

- **Design and manuals: complete.** The design document is final, and all eleven manuals (`docs/00-overview.md` through `docs/10-faq.md`) plus both checkoff lists are written.
- **Scripts: delivered, not exercised.** All 16 scripts are committed and `bash scripts/repo/check-scripts.sh` passes (it enforces the 200-line limit, `bash -n` syntax and PowerShell parsing, and prints `SKIP` for any checker not installed on the machine). None of the scripts has been run on a target machine, and the PowerShell helpers have not been executed against the reference hardware.
- **No reference implementation yet.** No device has been taken through L0 to L5, so `baseline/` is empty apart from its README and the verification list has no completed instance. Treat the commands and pass criteria as reviewed-on-paper, not as field-tested.
- **Per-device artifacts are never committed.** `baseline/*` is git-ignored except [baseline/README.md](baseline/README.md); it holds partition tables, ESP images, firmware entry snapshots and activation state, and it stays local.

## Contributing

The self-checks are the contract: run `bash scripts/repo/check-docs.sh` and `bash scripts/repo/check-scripts.sh` before committing, keep every manual's six-section structure (目标 / 前置条件 / 步骤 / 验证 / 失败处理 / 回滚) intact, keep each script under 200 lines, and never commit `baseline/*` artifacts, AI process files or emoji. When a change alters the design rather than a step, update [docs/design/00-design.md](docs/design/00-design.md) first and the manuals second.

## License

MIT, see [LICENSE](LICENSE).
