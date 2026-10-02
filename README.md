# win-linux-dualboot

English | [简体中文](README.zh-CN.md)

A reproducible, reversible playbook for Windows 11 IoT Enterprise LTSC 2024 + Fedora 44 Silverblue dual-boot on identical fresh devices.

This repository is a deployment playbook, not an installer. It ships the step manuals (three tracks, L0 to L5), the artifact contract each stage must leave behind, one script per step card (47 action cards, 45 step scripts: Windows-side PowerShell and Linux-side shell) with their shared contract libraries, and the partition, verification and risk registers that pin everything down. Every card names the script that judges it, and every script defaults to the safe direction: `--check` / `-Check` prints a verdict and writes nothing, and only an explicit `--apply` / `-Apply` (usually with `--yes` / `-Yes`) touches the system.

The material has two layers. The design documents ([docs/design/00-design.md](docs/design/00-design.md) plus its card-format and step-automation companions, and [docs/design/02-fedora-atomic-variant-design.md](docs/design/02-fedora-atomic-variant-design.md) for the current variant, plus [docs/design/06-atomic-restore-design.md](docs/design/06-atomic-restore-design.md) for the 2026-09-25 switch back to the atomic edition) record *why* the design looks the way it does: target device class, four invariants, key decisions with the rejected alternatives, the recovery matrix and the 38-entry risk register. The manuals ([docs/00-overview.md](docs/00-overview.md) onwards) are the executable part: cards with a 做 / 看到 pass criterion and a 出错时 pointer.

Nothing in here has been executed on a real machine yet: all scripts are fixture-level verified only. See [Status](#status) before you trust a single command.

## Table of Contents

- [Background](#background)
- [Usage](#usage)
- [Three tracks](#three-tracks)
- [Repository layout](#repository-layout)
- [Invariants](#invariants)
- [Target device class](#target-device-class)
- [Partition layout](#partition-layout)
- [Rollback strategy and atomic semantics](#rollback-strategy-and-atomic-semantics)
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

This playbook assumes a clean-slate install instead, so the partition table is decided once rather than edited surgically later, and it treats "remove Linux safely" as a first-class procedure rather than an afterthought. The Linux side is Fedora 44 Silverblue, an atomic, immutable system: the base is read-only, extra packages are layered and only take effect after a reboot, and the whole system can be rolled back to the previous deployment from the GRUB menu. Each release is supported for about 13 months (a new version every six months), so the version upgrade (`rpm-ostree rebase`) is a recurring, planned event with its own card. snapd does not exist on an atomic system at all, which is what makes the snap-residue problem structurally impossible. Both premises, and the full cause analysis, are in [docs/00-overview.md](docs/00-overview.md) and sections 1, 3 and 4 of the design document.

## Usage

Start at [docs/00-overview.md](docs/00-overview.md): it defines the tracks, the four invariants, the device parameter table (whose field names every manual reuses verbatim) and the stage-to-document mapping. Then walk your track in order, checking off [checklists/deploy.md](checklists/deploy.md) (L0 to L4) and [checklists/rollback.md](checklists/rollback.md) (L5) as you go.

| Track / stage | Manual | Artifact the stage must leave under `baseline/` |
|---|---|---|
| Shared base, L0 pre-install | [docs/01-firmware.md](docs/01-firmware.md) | `00-firmware.md` |
| Shared base, partitioning | [docs/02-partitioning.md](docs/02-partitioning.md) | partition record (`01-partitions.txt` for W/D, the partition section of `03-efi-layout.txt` for L) |
| W, L1 Windows install | [docs/03-windows.md](docs/03-windows.md) | `01-partitions.txt`, `01-activation.md` |
| W, L2 preflight and baseline (hard gate) | [docs/03-windows.md](docs/03-windows.md) | `02-preflight-report.md`, `02-esp-backup/`, `02-firmware-entries.txt`, `02-partitions.txt` |
| L, L3 Silverblue install | [docs/04-silverblue.md](docs/04-silverblue.md) | `03-efi-layout.txt` |
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
| **L** | Silverblue only | about 6 | install, first boot (driver/MOK/mount/time), converge, deployment-rollback drill |
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
templates/             diskpart script and fstab/GRUB/rpm-ostreed/journald/user-dirs/zram snippets
baseline/              per-device artifacts, never committed (only README.md is tracked)
```

## Invariants

Every step obeys these four. They, not any particular tool, are what prevent a bootloader lockout.

| # | Invariant | Failure mode it prevents |
|---|---|---|
| I1 | `BootOrder` always lists **Windows Boot Manager first** | After the Linux partitions are deleted, the firmware still points at the now-missing `\EFI\fedora\shimx64.efi` and the machine stops at `grub rescue>` |
| I2 | Boot into Linux only through a **one-shot `BootNext`** (or the vendor boot-menu key), never by reordering `BootOrder` | A permanent ordering that nobody remembers to undo |
| I3 | Never overwrite `\EFI\Microsoft\`, never change the `{bootmgr}` path | A third party owning the Windows boot path, which then breaks on a future update |
| I4 | Before touching the partition table or firmware settings, have a usable baseline: BitLocker suspended, ESP imaged, firmware entries snapshotted | No way back except reinstalling |

I3 gets structural support here: Windows and Silverblue each own a separate ESP, so a Windows update can only rewrite the ESP that holds `\EFI\Microsoft\` and cannot reach `\EFI\fedora\`.

The reason the invariants work is that the "stuck at the grub prompt" failure is not a broken GRUB — it is a stale firmware entry that still points at a deleted bootloader and sits ahead of Windows in the boot order. As long as I1 and I2 hold, the firmware falls through to Windows even after the Linux side has been wiped ([docs/00-overview.md](docs/00-overview.md)).

## Target device class

All of the following must hold:

- a single NVMe SSD of the nominal 1 TB class, UEFI + GPT. Capacity wording matters: a 1024 GB model yields about 953.7 GiB, which is what the partition table is built for; a 1000 GB model yields only about 931.3 GiB and shifts `D:` from about 635 GiB to about 613 GiB, with the other seven entries unchanged
- hybrid graphics (integrated plus a discrete NVIDIA or AMD GPU)
- a whole-disk format is acceptable: both systems are fresh installs, there is no "keep the existing system" path
- Windows 11 IoT Enterprise LTSC 2024 (24H2 / build 26100, supported to 2034-10) on the Windows side, **Fedora 44 Silverblue** (GNOME 50, Wayland, Anaconda installer, an approx. 13-month support window with a new release every six months) on the Linux side

Documented deviations get either an adaptation branch (two or more disks, a disk far from 1 TB, discrete-GPU-only, a read-only shared mount, a shared-ESP fallback) or are explicitly **not supported** by v1: disk encryption, a locked VMD/RAID controller mode, a firmware that can only boot from the first disk, or a snapshot-based rollback stack. The device parameter table that absorbs vendor differences (`DISK`, `VENDOR`, `BOOT_MENU_KEY`, `DISK_MODEL`, `DISK_SIZE`, `FEDORA_ESP_SIZE`, ...) is defined in [docs/00-overview.md](docs/00-overview.md) and is filled in once per device. The atomic semantics (read-only base, layered installs that need a reboot, a deployment as the rollback unit) are part of the contract, not an optional preference — see [docs/design/02-fedora-atomic-variant-design.md](docs/design/02-fedora-atomic-variant-design.md) and section 3 of [docs/design/00-design.md](docs/design/00-design.md).

## Partition layout

Eight entries on a nominal 1 TB NVMe (about 953 GiB usable):

| # | Partition | Size | Type | Role |
|---|---|---|---|---|
| 1 | ESP Windows | 2 GiB | EFI System (FAT32) | Windows only; holds `\EFI\Microsoft\` and `\EFI\BOOT\` |
| 2 | MSR | 16 MiB | Microsoft Reserved | Windows |
| 3 | Windows system `C:` | 200 GiB | NTFS | system and programs; the only partition formatted when reinstalling Windows |
| 4 | Windows data `D:` | approx. 635 GiB | NTFS | games, downloads, documents, container images; the dual-boot shared volume |
| 5 | ESP Fedora | 1 GiB | EFI System (FAT32) | Silverblue's own ESP, holding `\EFI\fedora\`; mounted at `/boot/efi` |
| 6 | `/boot` | 1 GiB | ext4 | separate so a root-only reinstall can keep the kernel and the GRUB modules |
| 7 | Fedora root | approx. 113 GiB | btrfs | `/` (the atomic default; `/boot` stays ext4) |
| 8 | WinRE | 1 GiB | Recovery | Windows recovery environment, at the end of the disk |

That is about 953 GiB in total (2 + 0.016 + 200 + 635 + 1 + 1 + 113 + 1). The Fedora side accounts for 115 GiB (1 + 1 + 113) and the shared data partition for roughly two thirds of the disk.

- **The three Fedora partitions are created later, inside the 115 GiB unallocated region reserved in L1.** The L1 `diskpart` script stops at `D:` and deliberately leaves the rest unallocated; the L3 Anaconda installer cuts `ESP-Fedora` 1 GiB + `/boot` 1 GiB + root approx. 113 GiB out of that region.
- **The two ESPs are never shared.** Windows keeps its own 2 GiB ESP, Silverblue gets its own 1 GiB ESP. Neither size may be shrunk by an installer.
- There is no swap partition: swapping is zram plus a 4 GiB swapfile, configured in L4, and hibernation is out of scope.
- The table is pre-built with `diskpart` ([templates/partitions.txt](templates/partitions.txt)), which is also why a whole-disk format is a prerequisite.

## Rollback strategy and atomic semantics

Fedora 44 Silverblue is an atomic, immutable system, and the playbook is explicit about what that buys and what it costs:

- **The running system is a deployment, not a package set.** `/usr` is read-only, and the previous deployment stays on disk and boots from the same GRUB menu. `rpm-ostree rollback` switches back to it, and `rpm-ostree pin` keeps a known-good deployment from being garbage collected ([scripts/linux/rollback-deploy.sh](scripts/linux/rollback-deploy.sh) reports the deployment list, pins and whether a rollback candidate exists). This is the one-command system rollback the earlier Kubuntu-era design had to give up.
- **Extra packages are layered, and a layer only takes effect after a reboot.** `rpm-ostree install` stages a new deployment; the running system is unchanged until you boot into it. GUI software comes from Flatpak instead of the base image.
- **Each release is supported for about 13 months** (a new version every six months), so the version upgrade (`rpm-ostree rebase`) is a recurring, planned event with its own card rather than a rare one.
- **User data is not part of the deployment.** `/var` — and therefore `/home`, which is a symlink to `/var/home` — survives a rollback untouched; a root-only reinstall still costs you `~`, so copy it to the shared volume first (see [docs/07-rescue.md](docs/07-rescue.md)). The data disk `D:` is untouched either way.
- **snapd does not exist here.** An atomic base ships no snap daemon and has no apt to pull one in, so the snap-residue problem — which the Kubuntu variant could only keep supressing, and which was recorded as a design gap — is structurally impossible here rather than merely contained; the switch back is recorded in [docs/design/06-atomic-restore-design.md](docs/design/06-atomic-restore-design.md).
- **Secure Boot stays on; no self-signed drivers.** NVIDIA support comes from the ublue NVIDIA variant image, whose kernel modules are pre-signed inside the image; a one-time MOK registration (`mokutil`, driven by an `ujust` task) enrols the ublue key so those modules load. Now verified against upstream (2026-09-27): the image is `ghcr.io/ublue-os/bluefin-nvidia:<stream>` (streams `gts` / `stable` / `stable-daily` / `latest`), the MOK task is `ujust enroll-secure-boot-key` with password `universalblue` and key `/etc/pki/akmods/certs/akmods-ublue.der`, and upstream issue #284 is **still open** — which is exactly why Fedora gets its own ESP and its own `/boot`. Still device-side: pick the stream whose Fedora version matches the installed one (Bluefin's `stable` can lag a release), and confirm that the firmware boots a second ESP on the same disk.
- **Deliberately not used (被否)**: `snapper` / `timeshift` / `grub-btrfs` / btrfs snapshot stacks, ZFS root snapshots, and per-package downgrades as the primary recovery path — the deployment is the unit of rollback, and the immutable base has no supported `dnf downgrade` story.
- **Four rollback granularities**: deployment <-> `rpm-ostree rollback` plus `pin`; configuration <-> the `.dbk.bak` copies each script leaves behind; baseline <-> the ESP backup plus firmware entries; stage <-> the L5 decommission path.

## Isolation and the shared disk

System and data are separated on both operating systems, so a crash on one side never costs you the other half of the machine:

- **Windows**: a 200 GiB system partition (`C:`) plus an approx. 635 GiB data partition (`D:`). Known folders (Desktop, Documents, Downloads, Pictures, Videos, Music), game libraries and container images are redirected to `D:`, so reinstalling Windows formats `C:` only. The split is deliberate: `C:` is the throwaway partition, `D:` is the one worth protecting.
- **Silverblue**: an approx. 113 GiB btrfs root plus a separate 1 GiB `/boot`. Documents, downloads, pictures and desktop live on the shared volume, which is what keeps root small; `/home` is a symlink to `/var/home`, so it survives a deployment rollback but not a root-only reinstall, and backing up means copying `~` to the shared volume first.

`D:` is a **shared partition** rather than a private Windows volume: Windows accesses it natively, and Silverblue mounts it read-write through the in-kernel `ntfs3` driver, so office files edited in Windows are reachable from Linux by switching systems — no copying, no transfer medium. Four conditions make it safe, and all four are preconditions rather than suggestions:

1. Fast Startup and hibernation disabled in Windows, otherwise NTFS stays in a dirty "hybrid shutdown" state and the Linux mount can fail or corrupt data.
2. No BitLocker or device encryption on `D:`, otherwise Linux cannot read it without extra tooling.
3. Fixed `uid`/`gid`/`umask` plus `windows_names` on the mount, because `ntfs3` has no POSIX permission bits (see [templates/fstab.snippet](templates/fstab.snippet)).
4. No work that depends on POSIX semantics on the shared volume: symlinks, hard links, case-sensitive renames and permission-bit-sensitive scripts stay on the Linux root, where those semantics exist.

Mounting is scripted ([scripts/linux/mount-shared.sh](scripts/linux/mount-shared.sh)) and the user-directory redirect for the Linux side is scripted too ([scripts/linux/xdg-redirect.sh](scripts/linux/xdg-redirect.sh)). Acceptance includes a bidirectional visibility test: write a marker in Windows, read it in Linux, then do it the other way round.

## In-place recovery

Both systems can be recovered **in place, on the original disk**, and the playbook treats that as a design goal rather than a hope:

- **Windows is broken** -> reinstall Windows formatting `C:` only; `D:`, the three Fedora partitions, MSR and WinRE are left untouched. The installer rebuilds `\EFI\Microsoft\` on the Windows ESP and may overwrite `\EFI\BOOT\bootx64.efi` there; the Fedora ESP is a different partition and is not affected.
- **Silverblue is broken** -> try the previous deployment first (`rollback-deploy.sh --apply --yes`, or pick it in the GRUB menu); if that is not enough, copy `~` to the shared volume, then reinstall Silverblue formatting the root partition (btrfs) only, keeping `/boot` and the Fedora ESP (mounted, never formatted), so the Windows side and the shared data survive.
- **Only the boot layer is broken** -> do not reinstall at all: restore the ESP from the L2 baseline, rebuild with `bcdboot`, clean the stale NVRAM entry ([docs/07-rescue.md](docs/07-rescue.md)).

The single most dangerous step in the whole flow — flagged as such at every place it appears — is **formatting the wrong ESP**: one of them holds `\EFI\Microsoft\`, and formatting it takes both systems down at once.

## Robustness measures

Losing a usable system costs far more than a reinstall, so the Silverblue side gets nine measures (R1 to R9 in section 4.7 of the design document), each with a matching rollback point:

1. **Back up before any change**: `baseline/` and the `/etc` files each script is about to touch (`fstab`, `user-dirs.dirs`, GRUB defaults, `rpm-ostreed.conf`) get a `.dbk.bak` copy first;
2. **Deployment-level rollback**: `rpm-ostree rollback` returns to the previous deployment and `rpm-ostree pin` protects a known-good one from garbage collection, with `--pin` / `--unpin` / `--check` to inspect and freeze or release it ([scripts/linux/rollback-deploy.sh](scripts/linux/rollback-deploy.sh));
3. **A separate `/boot` plus the GRUB deployment menu**: a bad upgrade still leaves the previous deployment selectable at boot, and `BootNext` complements that without violating I2;
4. **A permanent rescue medium**: the Silverblue install USB doubles as a live environment and is not recycled;
5. **Crash observability**: journald made persistent, so `journalctl -b -1` still works after a failed boot;
6. **OOM and memory pressure**: zram verified (`zramctl` lists `zram0`; only if it does not, the `templates/zram-generator.conf` fallback is written) plus a 4 GiB swapfile, with `systemd-oomd` enabled;
7. **An always-on SSH rescue channel**, so a dead desktop can still be debugged from another machine;
8. **A conservative update policy**: `rpm-ostreed-automatic` is set to `check` / `download` only and never applies an update or reboots on its own;
9. **Disk health monitoring** through `smartmontools`/`smartd`, alongside the distribution's default filesystem check.

## Verification

Completion is judged by [docs/08-verification.md](docs/08-verification.md) being fully green, not by "it installed". That list has six groups:

- **A. boot safety (A1-A8)** — Windows Boot Manager first in `BootOrder` across repeated reboots, `\EFI\Microsoft\` identical to the L2 baseline, `{bootmgr}` path unchanged, no permanent ordering ever written, the fedora entry last in `BootOrder`, the two ESPs provably independent, plus a **reversible decommission drill**.
- **B. system function (B1-B11)** — Wayland session with no X11 option, GPU driver healthy with nouveau as fallback and a non-empty module signer, Secure Boot still on with no self-signed keys, driver source proven to be the ublue pre-signed NVIDIA image, one-time MOK enrolment present (`mokutil --list-enrolled`), `ntfs3` read-write mount with `nofail`, bidirectional visibility on the shared volume, redirected home directories, RTC in UTC, Bluetooth pairing surviving a system switch, `fwupd` seeing the device.
- **C. dual-boot switching (C1-C3)** — one-shot `BootNext` into Linux without changing the default, one-command return to Windows, order stable after three switches.
- **D. removability (D1-D6)** — the L5 five-step decommission walked through, system/data isolation verified item by item, both in-place reinstall paths exercised, and the non-reinstall boot repair path proven.
- **E. records (E1-E5)** — artifacts complete and not committed, deviations written back to the device parameter table.
- **F. robustness (F1-F9)** — a real deployment rollback plus in-place reinstall drilled once (pin, update, `rollback-deploy.sh --apply --yes`, reboot, `nvidia` still loaded and `/var` data intact, then unpin; data on `D:` still present afterwards), the rollback path and pre-change backups usable, journald persistent, update policy as configured (`check` / `download` only, no auto-apply, no auto-reboot), SSH rescue reachable, `systemd-oomd` and zram active, `smartd` reporting PASSED, and `nofail` present on the entries L4 writes while deliberately absent from `/boot/efi`.

The two read-only judges are [scripts/linux/verify-all.sh](scripts/linux/verify-all.sh) and [scripts/windows/verify-all.ps1](scripts/windows/verify-all.ps1); when both sides write a summary, point `--out-dir` / `-OutDir` somewhere other than the hand-filled device copy so they do not overwrite it. An unchecked item is only acceptable when it is recorded as a known exception with its impact written down; otherwise the device counts as unfinished. At least one device has to complete the whole set before the playbook can be called a reference implementation — no device has yet.

## Risks

The register — risk, consequence and mitigation — lives in section 9 of [docs/design/00-design.md](docs/design/00-design.md) (38 entries), with a per-stage quick lookup plus 28 symptom cards in [docs/10-faq.md](docs/10-faq.md). It covers Intel VMD/RAID controller modes, BitLocker recovery prompts triggered by partition or firmware changes, Windows updates rewriting its ESP or the SBAT/DBX episode, NVIDIA driver signing and the one-time ublue MOK enrolment on the Fedora side, Fast Startup plus dual NTFS writers, firmware that only boots from the first disk, picking the wrong target disk, RTC and Bluetooth state divergence, `ntfs3` write damage on the shared volume, Anaconda picking the Windows ESP as the Linux `/boot/efi` (upstream issue #284), an atomic-base `rebase` that lands on a broken kernel or driver, and hardware faults misdiagnosed as dual-boot problems.

The Windows activation route is also a risk entry: the playbook documents the flow and links to the upstream project rather than shipping any activation script, and the repository deliberately contains no such script. Install-media checks split by vendor reality: the Fedora Silverblue ISO is compared against Fedora's official `*-CHECKSUM` file and its GPG signature, while the Windows ISO is limited to "official download domain plus official installer verification", because Microsoft does not publish SHA256 values for Windows 11 ISOs ([docs/01-firmware.md](docs/01-firmware.md)).

## Status

- **Design and manuals: complete.** The design documents are final, and all manuals ([docs/00-overview.md](docs/00-overview.md) through [docs/10-faq.md](docs/10-faq.md)) plus both checkoff lists are written.
- **Scripts: delivered, fixture-level verified only.** Every step card has its script and the card ↔ script binding is machine-checked. `bash scripts/repo/check-docs.sh` reports `check-docs: OK` (card format, references, links) and `bash scripts/repo/check-scripts.sh` reports `check-scripts: OK` (200-line limit, `bash -n` syntax, PowerShell parsing, printing `SKIP` for any checker not installed on the machine). **None of the scripts has been run on a target machine yet**, and the PowerShell helpers have not been executed against real hardware — their evidence is the fixture suites under `.superpowers/`, not a device.
- **No reference implementation yet.** No device has been taken through L0 to L5, so `baseline/` is empty apart from its README and the verification list has no completed instance. Treat the commands and pass criteria as reviewed-on-paper and fixture-tested, not as field-tested.
- **Per-device artifacts are never committed.** `baseline/*` is git-ignored except [baseline/README.md](baseline/README.md); it holds partition tables, ESP images, firmware entry snapshots and activation state, and it stays local.

## Contributing

The self-checks are the contract: run `bash scripts/repo/check-docs.sh` and `bash scripts/repo/check-scripts.sh` before committing, keep every manual's card format (`### NN-K` cards with 看到 / 坑 / 出错时 and a `脚本:` line) intact, keep each script under 200 lines, and never commit `baseline/*` artifacts, AI process files or emoji. When a change alters the design rather than a step, update [docs/design/00-design.md](docs/design/00-design.md) first and the manuals second.

## License

MIT, see [LICENSE](LICENSE).
