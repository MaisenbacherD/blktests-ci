# blktests-ci — Codebase Review

A review of the repository looking for things that can be optimized, hardened, or
cleaned up. Findings are grouped by theme and tagged with a severity that
reflects real-world impact **for this project's context**: self-hosted CI on a
trusted LAN that builds and boots untrusted kernels inside KubeVirt VMs, where
the VM is the security boundary and several "insecure" choices (HTTP registry,
passwordless sudo in the guest, privileged DinD) are intentional, documented
tradeoffs rather than bugs.

This document is for discussion. Nothing here has been changed in the codebase.

## How severity is assigned

- **High** — can break or hang CI, cause silent wrong results, or split-brain a
  control loop. Worth fixing soon.
- **Medium** — correctness/robustness/maintainability issues that bite on
  re-runs, upgrades, or edge cases.
- **Low** — polish, reproducibility, defense-in-depth, cosmetics.

A couple of points raised during the investigation were checked and
**dismissed/down-rated** so they don't distract:

- The mitmproxy CA *certificate* living in a ConfigMap is **correct**, not a
  vulnerability: the CA *private key* is properly kept in the `mitmproxy-ca`
  Secret (<ref_snippet file="/home/dennis/src/blktests-ci/playbooks/roles/k8s-install-mitmproxy/tasks/main.yaml" lines="68-93" />). Distributing the public cert via ConfigMap is the
  intended pattern.
- `prepare-nvme-devices.sh` using `sudo` is **fine**: it runs *inside the Fedora
  VM* (where `fedora` has passwordless sudo), not in a pod.
- `vars.sh` "missing `set -euo pipefail`" is a non-issue in practice: its only
  caller, `entrypoint.sh`, enables `set -euxo pipefail` before sourcing it
  (<ref_snippet file="/home/dennis/src/blktests-ci/.github/actions/kubevirt-action/entrypoint.sh" lines="218-219" />).

---

## Top priorities (TL;DR)

| # | Finding | Severity | Theme |
|---|---------|----------|-------|
| 1 | Unbounded VM-readiness SSH loop can hang a job until the CI timeout | High | Robustness |
| 2 | kpd split-brain window during a prolonged GitHub API outage | High | Correctness |
| 3 | Many shell tasks are non-idempotent (always "changed", re-download, rebuild) | Medium | Ansible quality |
| 4 | `get-base-kernel-artifacts.sh` can `copy-out` the whole rootfs on empty grep | Medium | Robustness |
| 5 | Mutable image tags (`:latest`, `docker:dind`, base images) + narrow Dependabot | Medium | Supply chain |
| 6 | Duplicated `prepare-nvme-devices.sh` and runner RBAC across GH/GL roles | Medium | Maintainability |
| 7 | Missing `pipefail`/`-u`; masked pipeline failures in device + version parsing | Medium | Robustness |
| 8 | No ResourceQuota/LimitRange on runner namespaces (untrusted jobs can exhaust the cluster) | Medium | Security (defense-in-depth) |
| 9 | `bitnami/kubectl:latest` for registry cleanup is fragile (Bitnami catalog changes) | Medium | Maintainability |
| 10 | Hardcoded 4 CPU / 8 Gi everywhere; not configurable | Low/Medium | Resource utilization |

---

## 1. Correctness & robustness

### 1.1 Unbounded wait for the VM to become reachable — High
<ref_snippet file="/home/dennis/src/blktests-ci/.github/actions/kubevirt-action/entrypoint.sh" lines="144-149" />

`kubectl wait ... --timeout=300s` bounds the *Running* phase, but the subsequent
`while true` SSH-readiness loop has no timeout. If the guest never writes
`/vm-ready` (bad kernel, panic, cloud-init failure, missing device), the job
spins on `virtctl ssh` + `sleep 10` until the GitHub/GitLab job timeout, wasting
a runner slot and producing no useful signal.

**Recommendation:** bound the loop (e.g. ~30 iterations / 5 min), and on timeout
dump `kubectl describe vmi` + console log and exit non-zero so the failure is
attributable.

### 1.2 kpd leader election: split-brain on a prolonged GitHub API outage — High
<ref_snippet file="/home/dennis/src/blktests-ci/playbooks/roles/k8s-install-kernel-patches-daemon/templates/kpd-leader-election.py.j2" lines="259-287" />

In `heartbeat_loop()`, a failed `read_lock()` (`RuntimeError`, any non-200/404)
is swallowed with `continue` (lines 266-267) and a failed CAS write only logs
"Heartbeat update failed" (lines 278-279). In both cases the active instance
keeps `kpd` running but stops refreshing the lock. If the GitHub API is
unavailable for longer than `kpd_lock_ttl_seconds` (1200 s), a standby cluster's
`try_acquire()` sees the lock as stale and takes over — while the original is
still running. Result: two active kpd instances (duplicate PRs / patch
application).

**Nuance:** this needs a sustained (>20 min) outage, and same-cluster pod
restarts recover quickly (the restarted pod re-acquires its own lock via the
`holder == CLUSTER_NAME` refresh path, lines 224-228). So it is a real but
narrow window.

**Recommendation:** count consecutive heartbeat failures and, once they exceed
the TTL budget, proactively `_stop_kpd()` (fence yourself) rather than relying on
the standby's takeover being mutually exclusive.

### 1.3 `get-base-kernel-artifacts.sh`: empty grep → `copy-out` of `/` — Medium
<ref_snippet file="/home/dennis/src/blktests-ci/playbooks/roles/kernel-builder-k8s-job/templates/get-base-kernel-artifacts.sh" lines="22-30" />

`CONFIG_FILE=$(echo "$FILES" | grep 'config-' | xargs)` — if `grep` matches
nothing, `CONFIG_FILE` is empty and the guestfish step becomes
`copy-out / /` (copies the entire guest filesystem). `set -e` does not catch
this because the failing `grep` is mid-pipeline (exit status is `xargs`'). The
later `mv /config-*` would then fail confusingly.

**Recommendation:** validate both variables are non-empty (and single-valued)
before the guestfish `copy-out`; exit with a clear error otherwise.

### 1.4 Masked pipeline failures in NVMe format detection — Medium
<ref_snippet file="/home/dennis/src/blktests-ci/playbooks/roles/k8s-install-kubevirt-actions-runner-controller/tasks/main.yaml" lines="206-231" />
(duplicated in <ref_file file="/home/dennis/src/blktests-ci/playbooks/roles/k8s-install-gitlab-runner/tasks/main.yaml" />)

The inline `prepare-nvme-devices.sh` uses `set -e -x` but no `pipefail`. The
`FORMAT=$(... | grep | grep | grep | awk ...)` and `SIZE=$(...)` pipelines can
silently yield empty strings if any `grep` misses, after which `nvme create-ns
-f ''` fails with a cryptic error. The same applies to the kernel-version
extraction in `build-fedora-kernel.sh`.

**Recommendation:** add `set -o pipefail` and assert the parsed values are
non-empty before using them.

### 1.5 Other shell robustness items — Low
- **No `pipefail`/`-u` in several scripts:** `build-kernel.sh`, `build-fedora-kernel.sh`,
  `get-base-kernel-artifacts.sh`, `update.sh`, `fedora-vm-init.sh.j2`,
  `longhorn-webhook-unblock.sh` use `set -e`/`set -eu` only. Standardize on
  `set -euo pipefail`.
- **Unbounded `until docker info` loop** in `build-fedora-kernel.sh` (same hang
  class as 1.1).
- **Unquoted expansions** in `entrypoint.sh` (`ls ${dir}/boot | grep ${kernel_version}`
  line 178, `mkdir $dir` line 183, `docker pull ...:${kernel_version}` line 191,
  `--since=${since_time}` line 210). Values are controlled so impact is low, but
  quoting is cheap defense.
- **`since_time` is the `AGE` column** of `kubectl get pods` (<ref_snippet file="/home/dennis/src/blktests-ci/.github/actions/kubevirt-action/entrypoint.sh" lines="209-210" />), passed to `logcli --since`. It mostly works but is a fragile way to derive a time window; prefer the pod's `.status.startTime`.
- **Verify remote exit-code propagation:** the actual test runs via
  `virtctl ssh ... --command="${run_cmds}"` (<ref_snippet file="/home/dennis/src/blktests-ci/.github/actions/kubevirt-action/entrypoint.sh" lines="151-152" />). Worth confirming a non-zero exit inside the
  VM reliably fails the job across the virtctl versions in use; otherwise a
  failing test could be reported as green.

---

## 2. Idempotency & Ansible quality

`install-k8s-requirements.yaml` is meant to be re-runnable, but several roles
lean on `shell:` in ways that always report `changed` or repeat expensive work.

### 2.1 Non-idempotent downloads and waits — Medium
<ref_snippet file="/home/dennis/src/blktests-ci/playbooks/roles/k8s-install-kubevirt/tasks/main.yaml" lines="19-22" />
- `wget` the KubeVirt/CDI manifests and virtctl (lines 19-22, 36-38, 66-69):
  re-download every run. Use `ansible.builtin.get_url` (idempotent, has retries)
  or add `creates:`.
- `kubectl wait` via `shell:` (lines 40-42, 59-60, 62-63) always reports
  `changed`. Add `changed_when: false`, or use `kubernetes.core.k8s_info` with
  `until:` (as the mitmproxy role already does well).

### 2.2 Docker build/push always runs — Medium
The GitLab runner image build/push, the kpd image build, and the kernel-builder
image build run unconditionally on every playbook run (e.g. GitLab role
build/push at lines ~172-176; kpd build in
<ref_file file="/home/dennis/src/blktests-ci/playbooks/roles/k8s-install-kernel-patches-daemon/tasks/main.yaml" />).
Rebuilding/repushing on every run wastes time/bandwidth and can race a runner
pulling mid-push. Gate on a content hash or a registry-existence check.

### 2.3 CRD update and helm checks — Low
<ref_snippet file="/home/dennis/src/blktests-ci/playbooks/roles/k8s-install-kubevirt-actions-runner-controller/tasks/main.yaml" lines="120-138" />
The `helm list | grep` check (line 121) and the `kubectl apply --server-side`
CRD update (lines 132-138) are intentional (Helm does not upgrade existing
CRDs), but both always report `changed`. Add `changed_when:` and consider the
`kubernetes.core.k8s` module with `apply: yes`/`server_side_apply` for the CRDs.
Also: if the `helm list` probe fails transiently, `arc_installed.rc != 0` skips
the CRD update even when an old version is installed.

### 2.4 Firewall rules via raw shell — Low
<ref_snippet file="/home/dennis/src/blktests-ci/playbooks/roles/configure-physical-k8s-cluster-node/tasks/main.yaml" lines="303-318" />
`firewall-cmd`/`ufw` are driven through `shell:` with `sudo` inside
(`become: yes` already applies). Prefer `ansible.posix.firewalld` /
`community.general.ufw` for idempotency, and drop the redundant inner `sudo`.

### 2.5 Fragile structural patterns — Low
- Roles re-`include_vars: ../../../../variables.yaml` with deep relative paths
  (e.g. runner controller line 7, kubevirt role line 7) even though the playbook
  already loads it. This couples correctness to the working directory.
- `~/tmp-ansible` is created in multiple roles, used for downloads and rendered
  manifests, and never cleaned up. Standardize (a `tempfile`-created dir, or one
  documented variable) and clean up afterwards.

---

## 3. Security

The threat model (untrusted CI code, real hardware) is acknowledged in the
README warning, and the design deliberately trades isolation for capability.
The items below separate **inherent/documented tradeoffs** (note + monitor) from
**fixable gaps**.

### 3.1 Inherent, documented tradeoffs (note, don't "fix")
- **Privileged DinD** running CI workloads:
  <ref_snippet file="/home/dennis/src/blktests-ci/playbooks/roles/k8s-install-kubevirt-actions-runner-controller/templates/arc-vm-scale-set-values.yaml.j2" lines="103-104" /> and
  <ref_snippet file="/home/dennis/src/blktests-ci/playbooks/roles/kernel-builder-k8s-job/templates/kernel-builder-cronjob.yaml.j2" lines="45-46" />.
  Required for image build/extraction. (Good: only the `dind` sidecar is
  privileged, not the runner container.)
- **HTTP-only registry** on NodePort 32000 with deletes enabled and no auth
  (<ref_snippet file="/home/dennis/src/blktests-ci/playbooks/roles/k8s-install-private-container-registry/tasks/main.yaml" lines="105-128" />). Documented LAN tradeoff.
- **Passwordless sudo in the guest** (<ref_snippet file="/home/dennis/src/blktests-ci/playbooks/roles/k8s-install-kubevirt-actions-runner-controller/templates/fedora-var-kernel-vm.yaml.j2" lines="100-102" />) and **`StrictHostKeyChecking=no`** to ephemeral VMs (<ref_snippet file="/home/dennis/src/blktests-ci/.github/actions/kubevirt-action/vars.sh" lines="34-34" />). Reasonable for throwaway VMs.

For these, the useful action is **defense-in-depth**, not removal — see 3.3.

### 3.2 Fixable gaps — Low/Medium
- **No `ResourceQuota`/`LimitRange` on runner namespaces** (Medium). The runner
  service account can create VMs/ConfigMaps (<ref_snippet file="/home/dennis/src/blktests-ci/playbooks/roles/k8s-install-kubevirt-actions-runner-controller/templates/kubevirt-actions-runner-rbac.yaml.j2" lines="18-33" />); a misbehaving or hostile job could spin up
  many VMs and exhaust the cluster. A per-namespace quota is cheap insurance.
- **Registry `https` port is fake TLS** (Low): the Service maps port 443 →
  targetPort 5000, but 5000 is plain HTTP (<ref_snippet file="/home/dennis/src/blktests-ci/playbooks/roles/k8s-install-private-container-registry/tasks/main.yaml" lines="124-127" />). Either terminate real TLS or drop the
  misleading port.
- **Dead credential references** in the registry-cleanup CronJob (Low):
  `curl -u $USER:$PASS` with `$USER`/`$PASS` never set (<ref_snippet file="/home/dennis/src/blktests-ci/playbooks/roles/k8s-install-private-container-registry/tasks/main.yaml" lines="165-183" />). Harmless today (the registry has no auth, so empty
  creds work), but it implies an auth model that doesn't exist — remove it or
  wire real creds from a Secret.
- **`ansible_host_key_checking: false`** in `k8s-inventory-template.yaml` (Low):
  fine for first bring-up, but document the implication since Ansible runs with
  `become` on the nodes.

### 3.3 Suggested defense-in-depth (Low, optional)
Given the accepted tradeoffs, these would meaningfully raise the floor without
changing the design:
- Per-namespace `ResourceQuota` + `LimitRange` for runner namespaces.
- `NetworkPolicy` to keep runner namespaces from reaching infra namespaces
  (`mitmproxy`, `docker-registry`, `kubevirt`, `logging`) except where needed.
- Pod Security Admission labels (`privileged` on runner/builder namespaces,
  `baseline`/`restricted` on infra namespaces) to make the posture explicit.
- Consider taints/tolerations to pin privileged DinD to dedicated nodes.

### 3.4 Secrets handling — generally good
Credentials use Kubernetes `Secret`s (GitHub App key, PAT, GitLab token, kpd
key), `secrets.enc` is vault-encrypted and git-ignored, and the mitmproxy
private key is in a Secret. Minor: the kpd Secret bundles several sensitive
values; splitting the GitHub App key into its own Secret would narrow blast
radius (low priority).

---

## 4. Maintainability & DRY

### 4.1 Duplicated runner plumbing across GH and GL roles — Medium
The ~75-line `prepare-nvme-devices.sh` is duplicated verbatim in
<ref_snippet file="/home/dennis/src/blktests-ci/playbooks/roles/k8s-install-kubevirt-actions-runner-controller/tasks/main.yaml" lines="196-269" />
and the GitLab role, and `kubevirt-actions-runner-rbac.yaml.j2` exists as two
near-identical copies (only the `gh-runner-`/`gl-runner-` prefix differs). Bug
fixes must be applied twice.

**Recommendation:** extract a shared role (or shared `files/` + templated
namespace) for (a) the NVMe/ZBD prep ConfigMap and (b) the runner RBAC. The
mitmproxy-CA-propagation block is likewise repeated in three roles and is a good
candidate for a shared task file.

### 4.2 Inline scripts in ConfigMaps — Low
Large bash scripts are embedded inside `kubernetes.core.k8s` `data:` blocks.
Moving them to `files/` and loading via `lookup('file', ...)` (or templating)
makes them lintable with shellcheck and easier to diff.

### 4.3 Cosmetic — Low
- Typo `lognhorn_dependency_packages` (<ref_snippet file="/home/dennis/src/blktests-ci/playbooks/roles/configure-physical-k8s-cluster-node/vars/Debian.yaml" lines="1-1" /> and `tasks/main.yaml:17`). Harmless (both sides match) but
  worth renaming to `longhorn_...`.
- Inconsistent task-name quoting/casing across roles.

---

## 5. Dependency & version hygiene

### 5.1 Mutable image tags — Medium
Several images use mutable tags, so a rebuild can silently change behavior:
- `ghcr.io/actions/actions-runner:latest` (<ref_snippet file="/home/dennis/src/blktests-ci/playbooks/roles/k8s-install-kubevirt-actions-runner-controller/templates/arc-vm-scale-set-values.yaml.j2" lines="30-37" />)
- `docker:dind` (line 81, no version), `docker:cli` and `ubuntu:22.04` in the Dockerfiles
- `container-registry.local:5000/kernel-builder-k8s-job:latest` (<ref_snippet file="/home/dennis/src/blktests-ci/playbooks/roles/kernel-builder-k8s-job/templates/kernel-builder-cronjob.yaml.j2" lines="20-20" />)
- `quay.io/containerdisks/fedora:42` VM root image default (<ref_snippet file="/home/dennis/src/blktests-ci/playbooks/roles/k8s-install-kubevirt-actions-runner-controller/templates/fedora-var-kernel-vm.yaml.j2" lines="82-82" />)

**Recommendation:** pin to a version and/or `@sha256:` digest. Most other
components are already nicely pinned in `variables.yaml`, so this is the gap.

### 5.2 `bitnami/kubectl:latest` for registry cleanup — Medium
<ref_snippet file="/home/dennis/src/blktests-ci/playbooks/roles/k8s-install-private-container-registry/tasks/main.yaml" lines="151-153" />
Beyond being unpinned, the Bitnami Docker Hub catalog has been changing (free
images are being moved/retired), so `bitnami/kubectl:latest` is a future
breakage risk. Switch to a pinned, durable image (e.g. a pinned
`rancher/kubectl`, or reuse the in-cluster cached `kubectl`).

### 5.3 Dependabot coverage is narrow — Low
<ref_snippet file="/home/dennis/src/blktests-ci/.github/dependabot.yml" lines="7-12" />
Only `github-actions` under one directory is watched. Add `docker` ecosystem
entries for the Dockerfiles and a broader `github-actions` scope. (Most chart
versions are hand-pinned in `variables.yaml`, which Dependabot won't track —
acceptable, but worth a note.)

### 5.4 Floating Ansible collection — Low
<ref_snippet file="/home/dennis/src/blktests-ci/requirements.yaml" lines="10-12" />
`kubernetes.core >= 6.4.0` is unbounded. Pin or cap (`>=6.4.0,<7.0.0`) for
reproducible runs.

---

## 6. Resource utilization & performance

### 6.1 Hardcoded sizing, not configurable — Low/Medium
4 CPU / 8 Gi is hardcoded in at least three places: the test VM
(<ref_snippet file="/home/dennis/src/blktests-ci/playbooks/roles/k8s-install-kubevirt-actions-runner-controller/templates/fedora-var-kernel-vm.yaml.j2" lines="71-75" />), the runner container
(<ref_snippet file="/home/dennis/src/blktests-ci/playbooks/roles/k8s-install-kubevirt-actions-runner-controller/templates/arc-vm-scale-set-values.yaml.j2" lines="73-79" />), and the kernel-builder
(<ref_snippet file="/home/dennis/src/blktests-ci/playbooks/roles/kernel-builder-k8s-job/templates/kernel-builder-cronjob.yaml.j2" lines="38-44" />). `maxRunners: 3` is also fixed. This is
already on the README roadmap; surfacing these as `variables.yaml` knobs (with
profiles like small/large) would let light jobs pack more densely and heavy
builds scale up. Note the test VM sets memory *requests* but no *limits*.

### 6.2 Tuning opportunities — Low
- kpd heartbeat:TTL is 300 s : 1200 s (4 refreshes before expiry). A tighter
  ratio (e.g. 120 s heartbeat) detects failure faster and tolerates a missed
  beat; add jitter/backoff on retries.
- CI binary-cache reconcile runs hourly; for a stable cluster a longer interval
  (or event-driven on KubeVirt-version change) is cheaper.
- Consider BuildKit cache mounts for the kernel-builder image to speed rebuilds.

---

## 7. Project hygiene (testing/CI)

- **No linting**: adding `ansible-lint` + `shellcheck` (the latter is easier once
  inline scripts move to `files/`, see 4.2) would catch most of §1–§2
  automatically.
- **No syntax/CI validation**: a lightweight GitHub Actions workflow running
  `ansible-playbook --syntax-check`, `ansible-lint`, `shellcheck`, and
  `hadolint` on PRs would prevent regressions in this repo itself.
- **No role tests**: Molecule is likely overkill here, but a smoke test for the
  pure-logic pieces (e.g. `vars.sh` name sanitization/truncation, the kpd
  leader-election state machine) would be high-value-per-effort.

---

## What's already done well

Worth preserving as patterns:

- **`configure-physical-k8s-cluster-node`** vfio handling is genuinely careful:
  it derives `vfio-pci.ids` from the single-source-of-truth manifest, merges
  rather than overwrites existing IDs, adds a `softdep mpt3sas pre: vfio-pci`
  and forces vfio into the initramfs to win the boot race, and computes whether
  a reboot is actually required.
- **mitmproxy role** is idempotent (existence checks, `tempfile`,
  `changed_when: false`) and splits the private key (Secret) from the public
  cert (ConfigMap) correctly.
- **CI binary cache** keeps `kubectl`/`virtctl` version-matched to the live
  cluster and bypasses the proxy via `NO_PROXY` — a thoughtful design.
- **`vars.sh`** produces DNS-1123-safe, unique, 63-char-bounded VM names across
  both GitHub and GitLab.
- **Generic zoned-device discovery** surfaces NVMe ZNS and SCSI/SATA host-managed
  disks uniformly via `/sys/block/*/queue/zoned`.
- **Secrets**: vault-encrypted, git-ignored, and delivered as Kubernetes Secrets.

---

## Suggested order of work

1. Bound the two unbounded wait loops (§1.1, §1.5) and fence kpd on heartbeat
   failure (§1.2) — these affect live CI behavior.
2. Add `set -o pipefail` + value assertions to the device/version parsing
   scripts (§1.3, §1.4).
3. De-duplicate the runner ConfigMap/RBAC (§4.1) — do this before more
   idempotency fixes so they're only made once.
4. Make shell tasks idempotent and pin image tags (§2, §5).
5. Add ResourceQuota/LimitRange + a lint/CI workflow (§3.3, §7).
6. Make resource sizing configurable (§6.1).
