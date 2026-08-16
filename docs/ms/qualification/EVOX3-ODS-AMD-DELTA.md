# EVO-X3 ODS v2.6.0 AMD / Strix Halo Host Delta Audit

Date: 2026-08-16

Scope: audit ODS v2.6.0 AMD / Strix Halo host-level changes against the
already-qualified EVO-X3 baseline. This document is analysis only. It does not
authorize changing the host, runtime code, BIOS, firewall, or EVO-X3 state.

Qualified EVO-X3 baseline:

- Ryzen AI Max+ 395 / Radeon 8060S
- 128 GB unified memory
- BIOS UMA 64 GB
- Ubuntu Server 24.04
- Kernel baseline `7.0.0-28-generic`
- Existing Ollama path qualified
- Qwen3-Coder-30B approximately 67-70 eval tok/s
- 100% GPU
- 10 consecutive generations clean
- UFW + Tailscale restriction

Audit sources:

- `AGENTS.md`
- `docs/ms/`
- `ods/installers/phases/10-amd-tuning.sh`
- `ods/config/system-tuning/README.md`
- `ods/config/system-tuning/amdgpu.conf`
- `ods/config/system-tuning/amdgpu_llm_optimized.conf`
- `ods/config/system-tuning/99-ods.conf`
- `ods/installers/phases/05-docker.sh`
- `ods/installers/phases/06-directories.sh`
- `ods/installers/phases/11-services.sh`
- `ods/installers/lib/compose-select.sh`
- `ods/docker-compose.base.yml`
- `ods/docker-compose.amd.yml`
- `ods/docker-compose.multigpu-amd.yml`
- `ods/docs/SUPPORT-MATRIX.md`
- `ods/docs/KNOWN-GOOD-VERSIONS.md`
- `ods/docs/TAILSCALE.md`
- `ods/docs/ODS-PROXY.md`
- `ods/config/network-exposure-policy.json`

## Summary Recommendation

Do not apply ODS AMD host tuning as a bundle to the qualified EVO-X3 host.
Several ODS recommendations are plausible for a fresh Strix Halo appliance, but
they are not equivalent to the current qualified EVO-X3 state.

High-risk deltas:

- BIOS UMA: ODS recommends minimum UMA, but EVO-X3 is qualified at 64 GB UMA.
  Classification: REJECT.
- GTT: ODS would generate about 90% of RAM for GTT on 128 GB, while the
  qualified host already reaches target performance. Classification: TEST.
- `amd_iommu=off`: ODS proposes disabling AMD IOMMU for performance. This is a
  security and future NPU/device-isolation regression from an unknown current
  GRUB state. Classification: TEST, with a strong preference to defer.
- Managed Lemonade/ROCm container: ODS AMD runtime is not the already-qualified
  Ollama runtime. Classification: TEST.
- Tailscale reachability docs require `BIND_ADDRESS=0.0.0.0`; the qualified
  host is UFW + Tailscale restricted, so do not widen global binds without a
  separate network/security approval. Classification: REJECT for global bind
  widening.

## Host-Level Delta Register

### 1. BIOS UMA Frame Buffer

- Source file: `ods/installers/phases/10-amd-tuning.sh`;
  `ods/config/system-tuning/README.md`;
  `ods/config/system-tuning/amdgpu_llm_optimized.conf`
- Current host state: BIOS UMA 64 GB, qualified with Ollama and
  Qwen3-Coder-30B at approximately 67-70 eval tok/s.
- ODS proposed state: set UMA Frame Buffer Size to 512 MB minimum, or 512 MB /
  1 GB per static tuning docs.
- Purpose: leave more system RAM outside fixed UMA so HIP/GTT can use the
  unified pool dynamically.
- Expected benefit: potential improvement for ODS's Lemonade/ROCm GTT strategy
  on fresh Strix Halo installs.
- Security implication: BIOS-only change; no direct network/security exposure.
- Operational implication: requires physical/firmware access and changes the
  known-good memory topology.
- Compatibility risk: high. This directly conflicts with the qualified EVO-X3
  64 GB UMA baseline and may invalidate existing Ollama evidence.
- Reboot required? Yes.
- Rollback: restore BIOS UMA Frame Buffer Size to 64 GB.
- Before verification commands:

```bash
sudo dmidecode -t memory
grep -H . /sys/class/drm/card*/device/mem_info_vram_total /sys/class/drm/card*/device/mem_info_gtt_total 2>/dev/null
uname -r
ollama ps || true
```

- After verification commands:

```bash
grep -H . /sys/class/drm/card*/device/mem_info_vram_total /sys/class/drm/card*/device/mem_info_gtt_total 2>/dev/null
uname -r
ollama ps || true
# Repeat the existing 10-generation Qwen3-Coder-30B qualification run and compare eval tok/s, GPU %, and errors.
```

- Classification: REJECT.

### 2. GTT Allocation and TTM Page Limits

- Source file: `ods/installers/phases/10-amd-tuning.sh`;
  `ods/config/system-tuning/amdgpu_llm_optimized.conf`;
  `ods/config/system-tuning/README.md`
- Current host state: unknown explicit `/etc/modprobe.d` GTT settings; host is
  qualified at 128 GB unified memory, 64 GB UMA, kernel `7.0.0-28-generic`.
- ODS proposed state: install `/etc/modprobe.d/amdgpu_llm_optimized.conf` with
  generated values. On 128 GB RAM, phase 10 selects 90% of RAM, roughly
  `gttsize=115000` MB, `pages_limit=gtt_bytes/4096`, and
  `page_pool_size=pages_limit/2`. Static file proposes `gttsize=120000`,
  `pages_limit=31457280`, `page_pool_size=15728640`.
- Purpose: increase GPU-visible GTT memory for large LLM weights and reduce
  allocation latency.
- Expected benefit: may help ODS Lemonade/ROCm load larger models or long
  contexts.
- Security implication: none direct, but larger GPU-visible memory increases
  blast radius of GPU driver faults.
- Operational implication: consumes/reserves a very large portion of RAM for GPU
  memory management and may affect Docker, page cache, Ollama, and other
  services.
- Compatibility risk: medium/high. Current host is already qualified; changing
  GTT can affect kernel `7.0.0-28-generic`, amdgpu behavior, and existing
  Ollama stability.
- Reboot required? Yes, after modprobe config and initramfs rebuild.
- Rollback:

```bash
sudo rm -f /etc/modprobe.d/amdgpu_llm_optimized.conf
sudo update-initramfs -u
sudo reboot
```

- Before verification commands:

```bash
uname -r
cat /proc/cmdline
find /etc/modprobe.d -maxdepth 1 -type f -name '*amdgpu*' -o -name '*ttm*'
modprobe -c | grep -E '^(options (amdgpu|ttm) .*|blacklist (amdgpu|ttm))'
grep -H . /sys/class/drm/card*/device/mem_info_vram_total /sys/class/drm/card*/device/mem_info_gtt_total 2>/dev/null
free -h
```

- After verification commands:

```bash
uname -r
cat /proc/cmdline
modprobe -c | grep -E '^(options (amdgpu|ttm) .*)'
grep -H . /sys/class/drm/card*/device/mem_info_vram_total /sys/class/drm/card*/device/mem_info_gtt_total 2>/dev/null
free -h
dmesg -T | grep -Ei 'amdgpu|ttm|gtt|kfd|oom|fail|error' | tail -200
# Repeat 10 consecutive generations and compare eval tok/s, GPU %, memory pressure, and dmesg.
```

- Classification: TEST.

### 3. `amdgpu` Modprobe Parameters

- Source file: `ods/config/system-tuning/amdgpu.conf`;
  `ods/installers/phases/10-amd-tuning.sh`
- Current host state: unknown explicit `amdgpu` modprobe options.
- ODS proposed state:

```conf
options amdgpu ppfeaturemask=0xffffffff
options amdgpu gpu_recovery=1
```

- Purpose: expose all AMD power-management features and enable GPU hang
  recovery.
- Expected benefit: potentially better tuning visibility and better recovery
  from hangs.
- Security implication: no direct network exposure; broader power-management
  surface may change driver behavior.
- Operational implication: can alter power/thermal behavior and recovery
  semantics under load.
- Compatibility risk: medium. Qualified Ollama stability may already depend on
  current defaults.
- Reboot required? Usually yes for reliable module parameter application.
- Rollback:

```bash
sudo rm -f /etc/modprobe.d/amdgpu.conf
sudo update-initramfs -u
sudo reboot
```

- Before verification commands:

```bash
modprobe -c | grep '^options amdgpu'
systool -vm amdgpu 2>/dev/null | grep -E 'ppfeaturemask|gpu_recovery' || true
cat /sys/module/amdgpu/parameters/ppfeaturemask 2>/dev/null || true
cat /sys/module/amdgpu/parameters/gpu_recovery 2>/dev/null || true
```

- After verification commands:

```bash
modprobe -c | grep '^options amdgpu'
cat /sys/module/amdgpu/parameters/ppfeaturemask 2>/dev/null || true
cat /sys/module/amdgpu/parameters/gpu_recovery 2>/dev/null || true
dmesg -T | grep -Ei 'amdgpu|gpu recovery|ring timeout|reset' | tail -200
```

- Classification: TEST.

### 4. `amd_iommu=off` GRUB Kernel Parameter

- Source file: `ods/installers/phases/10-amd-tuning.sh`;
  `ods/config/system-tuning/README.md`
- Current host state: unknown current GRUB command line; qualified kernel is
  `7.0.0-28-generic`.
- ODS proposed state: for single-GPU AMD APU, append `amd_iommu=off` or replace
  `iommu=pt` with `amd_iommu=off`; for multi-GPU, recommend `iommu=pt`.
- Purpose: reduce IOMMU overhead for GPU memory access.
- Expected benefit: ODS comments claim about 2-6% or 6% memory bandwidth /
  inference improvement.
- Security implication: disables AMD IOMMU, weakening DMA isolation and
  device-isolation protections.
- Operational implication: bootloader change; can affect device passthrough,
  future XDNA/NPU support, virtualization, and peripheral isolation.
- Compatibility risk: high. The current host is already qualified; disabling
  IOMMU may not be needed and has security tradeoffs.
- Reboot required? Yes.
- Rollback:

```bash
sudo sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/s/[[:space:]]amd_iommu=off//g' /etc/default/grub
sudo update-grub
sudo reboot
```

- Before verification commands:

```bash
uname -r
cat /proc/cmdline
grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub
dmesg -T | grep -Ei 'iommu|amd-vi|ivrs' | tail -100
```

- After verification commands:

```bash
uname -r
cat /proc/cmdline
dmesg -T | grep -Ei 'iommu|amd-vi|ivrs|amdgpu|kfd' | tail -200
# Repeat the existing Ollama benchmark and compare against 67-70 eval tok/s.
```

- Classification: TEST. Do not test until lower-risk runtime-only experiments
  have failed to meet target.

### 5. Initramfs Rebuild

- Source file: `ods/installers/phases/10-amd-tuning.sh`;
  `ods/config/system-tuning/README.md`
- Current host state: kernel baseline `7.0.0-28-generic`; initramfs currently
  qualified with existing host state.
- ODS proposed state: run `update-initramfs -u` or `dracut --force` after GTT
  and modprobe changes.
- Purpose: ensure module options apply on next boot.
- Expected benefit: makes GTT/amdgpu/ttm options deterministic at boot.
- Security implication: modifies boot artifacts; no direct network exposure.
- Operational implication: boot-critical change; bad initramfs can complicate
  recovery.
- Compatibility risk: medium, tied to the modprobe/GRUB changes above.
- Reboot required? The rebuild itself does not, but the intended effect does.
- Rollback: remove the modprobe config that triggered the rebuild, run
  `sudo update-initramfs -u`, then reboot.
- Before verification commands:

```bash
uname -r
ls -lh /boot/initrd.img-$(uname -r)
find /etc/modprobe.d -maxdepth 1 -type f -name '*amdgpu*' -o -name '*ttm*'
```

- After verification commands:

```bash
uname -r
ls -lh /boot/initrd.img-$(uname -r)
journalctl -b -p warning..alert --no-pager | grep -Ei 'initramfs|amdgpu|ttm|kfd' || true
```

- Classification: TEST only as a dependent step for approved GTT/modprobe
  experiments.

### 6. `/dev/kfd` Availability and `amdkfd` Load

- Source file: `ods/installers/phases/10-amd-tuning.sh`;
  `ods/installers/lib/detection.sh`;
  `ods/docker-compose.amd.yml`;
  `ods/docker-compose.multigpu-amd.yml`
- Current host state: qualified Ollama GPU path; exact `/dev/kfd` state not
  recorded in the supplied baseline.
- ODS proposed state: require `/dev/kfd` and try `sudo -n modprobe amdkfd` if
  missing; pass `/dev/kfd` into AMD containers.
- Purpose: ROCm compute access from containers.
- Expected benefit: required for ODS managed AMD/Lemonade ROCm container path.
- Security implication: exposes GPU compute device to containers that mount it.
- Operational implication: if missing, ODS ROCm containers fail; if present,
  container access depends on group/device permissions.
- Compatibility risk: low for read-only verification; medium for container
  passthrough.
- Reboot required? No for `modprobe`; reboot may be required if driver stack is
  not initialized cleanly.
- Rollback: stop containers using `/dev/kfd`; unload only if safe and unused:
  `sudo modprobe -r amdkfd`.
- Before verification commands:

```bash
ls -l /dev/kfd
lsmod | grep -E '^amdkfd|^amdgpu'
stat -c '%n %a %U:%G %t:%T' /dev/kfd
```

- After verification commands:

```bash
ls -l /dev/kfd
docker inspect ods-llama-server --format '{{json .HostConfig.Devices}}' 2>/dev/null || true
dmesg -T | grep -Ei 'kfd|amdkfd|hsa' | tail -100
```

- Classification: KEEP for verifying presence; TEST for granting container
  passthrough.

### 7. `/dev/dri` and Render Nodes

- Source file: `ods/installers/phases/10-amd-tuning.sh`;
  `ods/docker-compose.amd.yml`;
  `ods/docker-compose.multigpu-amd.yml`
- Current host state: qualified 100% GPU utilization; exact render node and
  permissions not recorded in the supplied baseline.
- ODS proposed state: require `/dev/dri/renderD128`; pass `/dev/dri` into AMD
  containers.
- Purpose: render and compute device access for ROCm/Vulkan workloads.
- Expected benefit: required for ODS AMD containers and dashboard GPU telemetry.
- Security implication: exposes DRM/render device nodes to containers.
- Operational implication: containers fail if nodes are absent or inaccessible.
- Compatibility risk: low for verification; medium for passthrough.
- Reboot required? No, unless amdgpu is not loaded correctly.
- Rollback: remove `/dev/dri` device mappings from compose and recreate
  containers.
- Before verification commands:

```bash
ls -la /dev/dri
stat -c '%n %a %U:%G %t:%T' /dev/dri/* 2>/dev/null
grep -H . /sys/class/drm/renderD*/device/{vendor,device} 2>/dev/null
```

- After verification commands:

```bash
docker inspect ods-llama-server --format '{{json .HostConfig.Devices}}' 2>/dev/null || true
dmesg -T | grep -Ei 'drm|amdgpu|kfd' | tail -100
```

- Classification: KEEP for verifying presence; TEST for container passthrough.

### 8. User Membership in `render` and `video`

- Source file: `ods/installers/phases/10-amd-tuning.sh`
- Current host state: unknown supplied group membership.
- ODS proposed state: `sudo usermod -aG render,video "$USER"`.
- Purpose: allow the invoking user and rootless/user-context tooling to access
  `/dev/kfd` and `/dev/dri`.
- Expected benefit: avoids permission failures for GPU containers or local ROCm
  commands.
- Security implication: grants direct GPU/render access to the user; this can
  expand access to display/GPU memory surfaces.
- Operational implication: requires logout/login or `newgrp`; changes user
  privileges persistently.
- Compatibility risk: low/medium. Usually necessary for ROCm workflows, but the
  current host may already work without changing groups.
- Reboot required? No; re-login required for active shell membership.
- Rollback:

```bash
sudo gpasswd -d "$USER" render
sudo gpasswd -d "$USER" video
# Log out and back in.
```

- Before verification commands:

```bash
id "$USER"
getent group render video
stat -c '%n %a %U:%G' /dev/kfd /dev/dri/renderD* 2>/dev/null
```

- After verification commands:

```bash
id "$USER"
groups "$USER"
docker run --rm --device=/dev/kfd --device=/dev/dri ubuntu:24.04 ls -l /dev/kfd /dev/dri 2>/dev/null || true
```

- Classification: TEST. Keep only if a containerized AMD runtime is approved
  and permissions are otherwise failing.

### 9. Sysctl Memory Tuning

- Source file: `ods/config/system-tuning/99-ods.conf`;
  `ods/installers/phases/10-amd-tuning.sh`;
  `ods/config/system-tuning/README.md`
- Current host state: unknown current `vm.swappiness` and
  `vm.vfs_cache_pressure`.
- ODS proposed state:

```conf
vm.swappiness=10
vm.vfs_cache_pressure=50
```

- Purpose: reduce swap aggressiveness and retain inode/dentry cache longer.
- Expected benefit: may reduce inference stalls under memory pressure.
- Security implication: none direct.
- Operational implication: host-wide memory behavior changes for all workloads,
  including Docker and existing Ollama.
- Compatibility risk: low/medium. Reasonable values, but not proven necessary
  for the qualified EVO-X3 baseline.
- Reboot required? No; applies immediately with `sysctl --system`.
- Rollback:

```bash
sudo rm -f /etc/sysctl.d/99-ods.conf
sudo sysctl -w vm.swappiness=60 vm.vfs_cache_pressure=100
```

- Before verification commands:

```bash
sysctl vm.swappiness vm.vfs_cache_pressure
free -h
vmstat 1 5
```

- After verification commands:

```bash
sysctl vm.swappiness vm.vfs_cache_pressure
free -h
vmstat 1 5
# Repeat 10-generation qualification and watch swap activity.
```

- Classification: TEST.

### 10. `tuned` Accelerator Performance Profile

- Source file: `ods/installers/phases/10-amd-tuning.sh`;
  `ods/config/system-tuning/README.md`
- Current host state: unknown `tuned` installation/profile; qualified
  performance already established.
- ODS proposed state: install `tuned`, enable the service, and set
  `accelerator-performance`.
- Purpose: set CPU governor/performance policy for lower prompt-processing
  latency.
- Expected benefit: ODS docs claim 5-8% prompt processing improvement.
- Security implication: installing packages and enabling a system service
  expands host maintenance surface.
- Operational implication: increases power/thermal load; may affect noise,
  thermals, and long-run stability.
- Compatibility risk: medium. The host's clean 10-generation run could be
  thermally sensitive.
- Reboot required? No.
- Rollback:

```bash
sudo tuned-adm off
sudo systemctl disable --now tuned
# Optional if installed only for this experiment:
sudo apt remove tuned
```

- Before verification commands:

```bash
command -v tuned-adm && tuned-adm active || true
systemctl is-active tuned || true
cpupower frequency-info 2>/dev/null | sed -n '1,80p' || true
sensors 2>/dev/null | sed -n '1,120p' || true
```

- After verification commands:

```bash
tuned-adm active
systemctl is-active tuned
cpupower frequency-info 2>/dev/null | sed -n '1,80p' || true
sensors 2>/dev/null | sed -n '1,120p' || true
# Repeat benchmark and compare prompt tok/s, eval tok/s, thermals, and fan/noise.
```

- Classification: TEST.

### 11. Systemd User Maintenance Timers

- Source file: `ods/installers/phases/10-amd-tuning.sh`;
  `ods/scripts/systemd/openclaw-session-cleanup.timer`;
  `ods/scripts/systemd/openclaw-session-cleanup.service`;
  `ods/scripts/systemd/memory-shepherd-workspace.timer`;
  `ods/scripts/systemd/memory-shepherd-workspace.service`;
  `ods/scripts/systemd/memory-shepherd-memory.timer`;
  `ods/scripts/systemd/memory-shepherd-memory.service`
- Current host state: not part of the qualified Ollama host baseline.
- ODS proposed state: copy user units to `~/.config/systemd/user`, enable
  `openclaw-session-cleanup.timer`, `memory-shepherd-workspace.timer`, and
  `memory-shepherd-memory.timer`.
- Purpose: clean OpenClaw sessions every 60s and maintain/reset memory-shepherd
  baseline files.
- Expected benefit: ODS agent hygiene; no AMD performance benefit.
- Security implication: persistent user automation modifies files in the user's
  ODS tree.
- Operational implication: background tasks run after install and can change
  workspace files.
- Compatibility risk: medium for MS/Ops agent governance. Not needed for AMD
  inference qualification.
- Reboot required? No.
- Rollback:

```bash
systemctl --user disable --now openclaw-session-cleanup.timer memory-shepherd-workspace.timer memory-shepherd-memory.timer
rm -f ~/.config/systemd/user/openclaw-session-cleanup.* ~/.config/systemd/user/memory-shepherd-*
systemctl --user daemon-reload
```

- Before verification commands:

```bash
systemctl --user list-timers --all | grep -E 'openclaw|memory-shepherd' || true
loginctl show-user "$USER" -p Linger
```

- After verification commands:

```bash
systemctl --user list-timers --all | grep -E 'openclaw|memory-shepherd'
journalctl --user -u openclaw-session-cleanup.service -u memory-shepherd-workspace.service -u memory-shepherd-memory.service --no-pager | tail -100
```

- Classification: REJECT for AMD host qualification.

### 12. User Lingering

- Source file: `ods/installers/phases/10-amd-tuning.sh`
- Current host state: unknown `loginctl` linger state.
- ODS proposed state: `loginctl enable-linger "$(whoami)"`.
- Purpose: keep user systemd timers alive after logout.
- Expected benefit: keeps ODS user maintenance timers running.
- Security implication: allows user services to persist without an active login
  session.
- Operational implication: more persistent background activity; can surprise
  operators on headless systems.
- Compatibility risk: medium; not required for AMD performance.
- Reboot required? No.
- Rollback:

```bash
loginctl disable-linger "$USER"
```

- Before verification commands:

```bash
loginctl show-user "$USER" -p Linger
systemctl --user list-units --type=service --state=running
```

- After verification commands:

```bash
loginctl show-user "$USER" -p Linger
loginctl user-status "$USER" | sed -n '1,120p'
```

- Classification: REJECT for AMD host qualification.

### 13. Docker Engine Installation, Docker Group, and AMD Docker 29.3 Downgrade

- Source file: `ods/installers/phases/05-docker.sh`;
  `ods/ods-cli`
- Current host state: Docker state/version not provided; EVO-X3 Ollama path is
  already qualified.
- ODS proposed state: install/start Docker if missing; add invoking user to
  `docker`; if AMD and Docker `29.3.*`, downgrade to `29.2.1` due to `/dev/dri`
  passthrough regression.
- Purpose: run ODS compose stack and avoid AMD device passthrough failures.
- Expected benefit: required for ODS managed container runtime.
- Security implication: `docker` group is effectively root-equivalent on the
  host; package downgrade changes patch posture.
- Operational implication: Docker daemon, package repositories, service restart,
  and possible version pin drift.
- Compatibility risk: medium/high if host Docker is used by other workloads.
- Reboot required? No; re-login may be required for `docker` group.
- Rollback:

```bash
sudo gpasswd -d "$USER" docker
sudo apt install docker-ce docker-ce-cli docker-compose-plugin
sudo systemctl restart docker
```

- Before verification commands:

```bash
docker version
docker compose version
id "$USER"
dpkg -l | grep -E 'docker-ce|docker-ce-cli|docker-compose-plugin' || true
```

- After verification commands:

```bash
docker version
docker compose version
id "$USER"
docker run --rm --device=/dev/dri ubuntu:24.04 ls /dev/dri 2>/dev/null || true
```

- Classification: TEST only if ODS container runtime is being evaluated on a
  disposable clone or approved maintenance window. REJECT on the qualified
  EVO-X3 host unless needed and approved.

### 14. AMD Compose Device Passthrough and Group IDs

- Source file: `ods/docker-compose.amd.yml`;
  `ods/docker-compose.multigpu-amd.yml`;
  `ods/ods-cli`
- Current host state: existing Ollama runtime qualified; no ODS AMD container
  qualification supplied.
- ODS proposed state: run `llama-server` as Lemonade/ROCm with:
  `/dev/dri:/dev/dri`, `/dev/kfd:/dev/kfd`, `VIDEO_GID`, `RENDER_GID`,
  `HSA_XNACK=1`, `ROCBLAS_USE_HIPBLASLT=1`, optional
  `HSA_OVERRIDE_GFX_VERSION=11.5.1` for gfx1151, and
  `LEMONADE_LLAMACPP_ROCM_BIN=/opt/llama-custom/llama-server` for Strix Halo.
- Purpose: containerized ROCm inference on Strix Halo.
- Expected benefit: ODS-supported AMD runtime path.
- Security implication: gives the container direct GPU device access; inference
  port is exposed through base compose host mapping.
- Operational implication: new container runtime competes with existing Ollama
  for GPU and memory; possible port conflicts on `OLLAMA_PORT`.
- Compatibility risk: high with existing Ollama unless isolated by port,
  service state, and GPU memory.
- Reboot required? No.
- Rollback:

```bash
docker compose -f docker-compose.base.yml -f docker-compose.amd.yml down
```

- Before verification commands:

```bash
docker ps --format 'table {{.Names}}\t{{.Ports}}\t{{.Status}}'
ollama ps || true
ss -ltnp | grep -E ':11434|:8080|:4000|:3000|:3002' || true
stat -c '%n %a %U:%G' /dev/kfd /dev/dri/renderD* 2>/dev/null
```

- After verification commands:

```bash
docker compose -f docker-compose.base.yml -f docker-compose.amd.yml ps
docker inspect ods-llama-server --format '{{json .HostConfig.Devices}} {{json .HostConfig.GroupAdd}}'
curl -fsS http://127.0.0.1:${OLLAMA_PORT:-11434}/api/v1/health || curl -fsS http://127.0.0.1:${OLLAMA_PORT:-11434}/health
ollama ps || true
```

- Classification: TEST.

### 15. Runtime Route Change: Ollama-Qualified Path to ODS Lemonade/LiteLLM

- Source file: `ods/installers/phases/06-directories.sh`;
  `ods/docker-compose.amd.yml`;
  `ods/docker-compose.base.yml`;
  `ods/config/litellm/strix-halo-config.yaml`
- Current host state: Ollama qualified.
- ODS proposed state: for AMD local installs, set `ODS_MODE=lemonade`,
  `LLM_BACKEND=lemonade`, route services through `http://litellm:4000`, and
  expose the managed Lemonade/llama-server API on the host port
  `${OLLAMA_PORT:-11434}`.
- Purpose: make ODS services use managed AMD Lemonade/ROCm inference.
- Expected benefit: consistent ODS AMD service routing and model metadata.
- Security implication: LiteLLM key enforcement is used internally; host
  inference port may be unauthenticated depending on the service route.
- Operational implication: not equivalent to existing Ollama; model IDs, API
  shape, context handling, health checks, and telemetry differ.
- Compatibility risk: high for existing Ollama workloads and benchmark
  comparability.
- Reboot required? No.
- Rollback:

```bash
docker compose -f docker-compose.base.yml -f docker-compose.amd.yml down
# Restore previous Ollama service/process and previous client endpoint settings.
```

- Before verification commands:

```bash
ollama ps || true
curl -fsS http://127.0.0.1:11434/api/tags || true
ss -ltnp | grep ':11434' || true
```

- After verification commands:

```bash
curl -fsS http://127.0.0.1:${OLLAMA_PORT:-11434}/api/v1/models || true
curl -fsS http://127.0.0.1:${OLLAMA_PORT:-11434}/api/v1/health || true
docker logs --tail 200 ods-litellm 2>/dev/null || true
# Repeat workload against the same client path used by production.
```

- Classification: TEST. Do not replace the qualified Ollama path without a
  separate runtime qualification.

### 16. Host Port Binding and UFW/Tailscale Restrictions

- Source file: `ods/docker-compose.base.yml`;
  `ods/installers/phases/06-directories.sh`;
  `ods/installers/phases/11-services.sh`;
  `ods/scripts/linux-install-preflight.sh`;
  `ods/docs/TAILSCALE.md`;
  `ods/docs/ODS-PROXY.md`;
  `ods/config/network-exposure-policy.json`
- Current host state: UFW + Tailscale restriction.
- ODS proposed state: default service host bindings use
  `${BIND_ADDRESS:-127.0.0.1}`. Installer can preserve or set
  `BIND_ADDRESS=0.0.0.0`; Tailscale docs require `ods-proxy` and
  `BIND_ADDRESS=0.0.0.0` for tailnet reachability. Phase 11 can add scoped UFW
  rules from Docker network subnets to host-agent port 7710.
- Purpose: default local-only service exposure with opt-in LAN/tailnet access;
  allow containers to reach host-agent under UFW.
- Expected benefit: loopback default is compatible with local-only security;
  scoped UFW rule fixes container-to-host-agent connectivity.
- Security implication: global `BIND_ADDRESS=0.0.0.0` exposes all mapped ODS
  service ports to LAN/tailnet interfaces subject to firewall policy. Tailscale
  container uses host networking and `NET_ADMIN`/`NET_RAW`.
- Operational implication: UFW rules may change; Tailscale reachability may
  fail if services stay loopback.
- Compatibility risk: high if global bind is widened; low for loopback default.
- Reboot required? No.
- Rollback:

```bash
# Keep or restore loopback:
sed -i 's/^BIND_ADDRESS=.*/BIND_ADDRESS=127.0.0.1/' .env
docker compose up -d

# Remove scoped UFW rule only after confirming the exact numbered rule:
sudo ufw status numbered
sudo ufw delete <rule-number>
```

- Before verification commands:

```bash
grep '^BIND_ADDRESS=' .env 2>/dev/null || true
sudo ufw status verbose
tailscale status 2>/dev/null || true
ss -ltnp | grep -E ':80|:3000|:3001|:3002|:11434|:4000|:7710' || true
```

- After verification commands:

```bash
grep '^BIND_ADDRESS=' .env
sudo ufw status verbose
tailscale status 2>/dev/null || true
ss -ltnp | grep -E ':80|:3000|:3001|:3002|:11434|:4000|:7710' || true
curl -fsS http://127.0.0.1:3002/api/status || true
```

- Classification: KEEP for loopback default and scoped Docker-subnet host-agent
  rule after review; REJECT for global `BIND_ADDRESS=0.0.0.0` on EVO-X3
  without separate Tailscale/UFW approval.

### 17. Tailscale Extension Host Networking

- Source file: `ods/extensions/services/tailscale/compose.yaml`;
  `ods/docs/TAILSCALE.md`;
  `ods/config/network-exposure-policy.json`
- Current host state: UFW + Tailscale restriction already qualified; exact ODS
  Tailscale extension state not supplied.
- ODS proposed state: optional `ods-tailscale` container with
  `network_mode: host`, `NET_ADMIN`, `NET_RAW`, and `/dev/net/tun`.
- Purpose: join the host network namespace to a tailnet.
- Expected benefit: remote private access through Tailscale when explicitly
  enabled.
- Security implication: privileged network capabilities in a host-networked
  container; auth key and node state custody matter.
- Operational implication: can change host routing and tailnet identity; still
  does not make loopback-bound services reachable.
- Compatibility risk: medium/high. The host already has Tailscale restriction;
  running a second Tailscale topology may conflict with existing policy.
- Reboot required? No.
- Rollback:

```bash
ods disable tailscale
docker rm -f ods-tailscale 2>/dev/null || true
```

- Before verification commands:

```bash
tailscale status
ip addr show tailscale0 2>/dev/null || true
docker ps --filter name=ods-tailscale
```

- After verification commands:

```bash
docker exec ods-tailscale tailscale status
ip route
tailscale status
```

- Classification: REJECT for this AMD host qualification unless remote-access
  topology is separately approved.

### 18. Kernel Baseline Compatibility

- Source file: `ods/docs/KNOWN-GOOD-VERSIONS.md`;
  `ods/docs/SUPPORT-MATRIX.md`;
  `ods/installers/phases/10-amd-tuning.sh`
- Current host state: `7.0.0-28-generic`.
- ODS proposed state: no explicit Linux kernel pin; docs say Linux AMD unified
  memory path requires a current amdgpu/ROCm-compatible kernel stack.
- Purpose: rely on current kernel driver support for Strix Halo.
- Expected benefit: ODS AMD path can work on supported kernels.
- Security implication: kernel choice affects all host security posture.
- Operational implication: ODS tuning assumes module parameters and initramfs
  behavior compatible with the running kernel.
- Compatibility risk: medium. ODS docs do not explicitly qualify
  `7.0.0-28-generic`; EVO-X3 does.
- Reboot required? No for verification; yes for kernel changes.
- Rollback: boot the known-good `7.0.0-28-generic` kernel from GRUB if any
  experiment changes kernel selection.
- Before verification commands:

```bash
uname -r
apt-cache policy linux-image-$(uname -r) 2>/dev/null || true
dkms status 2>/dev/null || true
dmesg -T | grep -Ei 'amdgpu|kfd|rocm|iommu|ttm' | tail -200
```

- After verification commands:

```bash
uname -r
dmesg -T | grep -Ei 'amdgpu|kfd|rocm|iommu|ttm|error|fail' | tail -300
```

- Classification: KEEP current kernel for all experiments.

## Recommended Experiment Order

All experiments should be performed on a disposable clone or during an approved
maintenance window with the current EVO-X3 baseline captured first. Do not run
the ODS installer's AMD tuning phase as a bundle.

1. Baseline capture only: collect kernel, BIOS-visible memory/GTT, device
   nodes, groups, UFW/Tailscale, Ollama state, and repeat one short known-good
   Ollama run.
2. Runtime dry-run/compose inspection: render ODS AMD compose and inspect port,
   device, group, and environment deltas without starting containers.
3. Container passthrough smoke test: test `/dev/kfd` and `/dev/dri` access in a
   throwaway container without stopping Ollama.
4. ODS Lemonade runtime isolation test: run ODS AMD on non-conflicting ports and
   do not change BIOS, GRUB, sysctl, tuned, or modprobe settings.
5. Sysctl-only test: apply `vm.swappiness=10` and `vm.vfs_cache_pressure=50`,
   then repeat the existing qualification workload.
6. `tuned`-only test: enable `accelerator-performance`, then repeat benchmark
   and thermal/stability checks.
7. `amdgpu` `ppfeaturemask`/`gpu_recovery` test: apply only these module
   options with initramfs rebuild and reboot, then repeat the full
   qualification.
8. GTT test: apply generated GTT/TTM settings, rebuild initramfs, reboot, and
   repeat the full qualification.
9. `amd_iommu=off` test: test only if previous steps fail to meet target and
   the security tradeoff is explicitly approved.
10. BIOS UMA change: do not test on the qualified EVO-X3 host. If needed, test
    only on separate hardware or after accepting that the 64 GB UMA baseline is
    invalidated.

## Minimum Baseline Capture Command Set

```bash
date -Is
hostnamectl
uname -a
cat /proc/cmdline
grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub
free -h
sysctl vm.swappiness vm.vfs_cache_pressure
id "$USER"
getent group render video docker
ls -la /dev/kfd /dev/dri 2>/dev/null
stat -c '%n %a %U:%G %t:%T' /dev/kfd /dev/dri/* 2>/dev/null
grep -H . /sys/class/drm/card*/device/mem_info_vram_total /sys/class/drm/card*/device/mem_info_gtt_total 2>/dev/null
modprobe -c | grep -E '^(options (amdgpu|ttm) .*)'
systemctl is-active tuned || true
command -v tuned-adm && tuned-adm active || true
loginctl show-user "$USER" -p Linger
systemctl --user list-timers --all | grep -E 'openclaw|memory-shepherd' || true
docker version
docker compose version
docker ps --format 'table {{.Names}}\t{{.Ports}}\t{{.Status}}'
ollama ps || true
sudo ufw status verbose
tailscale status 2>/dev/null || true
ss -ltnp | grep -E ':80|:3000|:3001|:3002|:11434|:4000|:7710' || true
dmesg -T | grep -Ei 'amdgpu|kfd|ttm|gtt|iommu|amd-vi|drm|oom|error|fail' | tail -300
```
