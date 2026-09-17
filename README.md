# win-linux-dualboot

English | [简体中文](README.zh-CN.md)

A reproducible playbook for installing **Windows 11 Pro + Ubuntu 26.04 LTS** as a dual-boot setup on a *fresh, same-spec device* — one that can be deployed on many identical machines, and that can be **fully removed again without breaking the Windows bootloader**.

> Status: **design phase**. The design document is complete; the step-by-step playbook and scripts are being written.

## The problem this solves

Most dual-boot guides fail in one of two ways:

1. They tell you to shrink partitions on a live production system, which is where "shrink failed", "BitLocker asked for a recovery key" and "the installer cannot see my NVMe" stories come from.
2. They leave the firmware boot order pointing at Linux. When you later format the Linux partition, the next reboot stops at a `grub>` / `grub rescue>` prompt — and Windows will not start.

This playbook assumes a **clean-slate install** (so partitioning is decided once, not surgically edited later) and treats "removing Linux safely" as a first-class, tested procedure rather than an afterthought.

## Four invariants

Every step in this playbook obeys these. They, not any particular tool, are what prevent bootloader lockout.

| # | Invariant | Failure mode it prevents |
|---|---|---|
| I1 | `BootOrder` always lists **Windows Boot Manager first** | Reboot stops at a stale entry after Linux is deleted |
| I2 | Boot into Linux with a **one-shot `BootNext`** (or the vendor boot menu), never by reordering `BootOrder` | A permanent ordering nobody remembers to undo |
| I3 | Never overwrite `\EFI\Microsoft\`; never change the `{bootmgr}` path | A third party owning the Windows boot path |
| I4 | Before touching the partition table or firmware settings: **back up the baseline** (BitLocker suspended, ESP imaged, firmware entries snapshotted) | No way back except reinstalling |

## Isolation on both sides

The plan isolates system from data on **both** operating systems, so a crash never costs you the other half of the machine:

- **Windows**: a 200 GiB system partition (`C:`) plus a ~635 GiB data partition (`D:`); known folders, game libraries and container images are redirected to `D:`. Reinstalling Windows formats `C:` only.
- **Ubuntu**: a 100 GiB root plus a dedicated 15 GiB snapshot partition. Documents, downloads, pictures and desktop live on the shared partition, so root stays small; rolling back a bad upgrade restores root without destroying snapshot history.

Both sides can be recovered **in place, on the original disk**: the design document (section 4.8) describes reinstalling Windows while formatting `C:` only, reinstalling Ubuntu while formatting root only (never the ESP), and the non-reinstall path for bootloader-only damage.

## A disk both systems can read

`D:` is a **shared partition**: Windows accesses it natively, Ubuntu mounts it read-write through the in-kernel `ntfs3` driver, so office files opened in Windows are reachable from Linux simply by switching systems — no copying, no transfer medium. Four conditions make it safe: Fast Startup and hibernation disabled, no BitLocker on `D:`, fixed `uid`/`gid`/`umask` plus `windows_names` mount options, and no POSIX-semantics-sensitive work (symlinks, permission bits, case-sensitive renames) on the shared volume.

## Target device class

Applicable when the machine matches all of:

- single NVMe SSD, nominal 1 TB (about 953 GiB usable — this is the "close to, but under 1 TB" class, not 1 TiB), UEFI + GPT
- hybrid graphics (integrated + discrete NVIDIA/AMD)
- Windows 11 Pro as the Windows target, Ubuntu 26.04 LTS as the Linux target
- the whole disk may be formatted

Devices that deviate (two drives, an existing ESP smaller than 1 GiB, BitLocker already enabled, a locked VMD/RAID mode that cannot be changed, discrete-GPU-only) are documented as either an adaptation branch or explicitly **not supported** — see `docs/00-overview.md`.

## Layout

```
docs/                  playbook, in execution order (00-09)
docs/design/           why the design looks like this
scripts/windows/       PowerShell helpers, read-only or dry-run by default
scripts/linux/         first-boot convergence helpers
templates/             diskpart script, fstab/sysctl snippets
checklists/            deploy and rollback checklists
baseline/              per-device deployment artifacts (never committed)
```

## How to use it

Start at `docs/00-overview.md` and follow the stages in order. Each stage ends with a verifiable artifact under `baseline/`; a stage without an artifact is considered unfinished. Stage L2 is a hard gate: if it reports a red item, do not continue to the Ubuntu installation.

## Verification

Completion is judged by `docs/08-verification.md` being fully green — not by "it installed". The verification set includes a **reversible decommission drill**: temporarily remove `\EFI\ubuntu\`, confirm the machine still boots Windows unattended with no `grub rescue` prompt, then restore from the ESP image. A separate group verifies robustness: a snapshot rollback drilled once, persistent journald, a reachable SSH rescue channel, a conservative update policy and SMART disk health. A third group verifies in-place recovery: system/data isolation is real, and both reinstall paths have been walked through.

## Robustness measures

Losing a working system costs far more than reinstalling it, so the Ubuntu side is hardened with nine measures: pre-change snapshots backed by a dedicated 15 GiB snapshot partition, old kernels kept alongside `GRUB_DEFAULT=saved` for one-shot booting, a permanent rescue USB, persistent journald for post-crash diagnosis, zram plus `systemd-oomd` for memory pressure, an always-on SSH rescue channel, a conservative update policy (security updates only, never auto-reboot), SMART monitoring, and `nofail` on every non-root mount. Details in `docs/design/00-design.md` section 4.7.

## Risks

Known failure classes (Intel VMD/RAID, BitLocker recovery prompts, Windows updates rewriting the ESP, NVIDIA module signatures under Secure Boot, RTC/Bluetooth state divergence between the two systems) are listed with mitigations in `docs/09-risks.md`.

## License

MIT — see [LICENSE](LICENSE).
