[![Build Status](https://dev.azure.com/meyuy43h2/netscaler-vpx-regression/_apis/build/status/VPX%20Firmware%20Regression?branchName=main)](https://dev.azure.com/meyuy43h2/netscaler-vpx-regression/_build/latest?definitionId=2&branchName=main)

# NetScaler VPX Firmware Regression Testing

Automated pipeline that deploys two NetScaler VPX instances on KVM, applies identical enterprise configurations via Terraform (~195 resources), runs **375 NITRO API tests**, **35 CLI comparisons**, and **50 HTTP probe requests** per appliance, then produces a self-contained interactive HTML report showing exactly what changed between firmware versions.

```
                          Azure DevOps Pipeline
                                  │
           ┌──────────────────────┼──────────────────────┐
           │                      │                      │
     ┌─────▼─────┐         ┌─────▼─────┐         ┌──────▼──────┐
     │   Setup    │         │  Baseline │         │  Candidate  │
     │ prereqs,   │────────▶│  VPX VM   │────────▶│   VPX VM    │
     │ certs, VM  │    ┌───▶│ (KVM/QCOW)│    ┌───▶│  (KVM/QCOW) │
     │ cleanup    │    │    └─────┬─────┘    │    └──────┬──────┘
     └────────────┘    │          │           │           │
                       │    Terraform        │     Terraform
                       │    Phase A          │     Phase A
                       │    (system) ──▶     │     (system) ──▶
                       │    reboot ──▶       │     reboot ──▶
                       │    Phase B          │     Phase B
                       │    (all modules)    │     (all modules)
                       │          │           │           │
                       │          └───────────┼───────────┘
                       │                      │
                       │              ┌───────▼────────┐
                       │              │  Regression    │
                       │              │  Tests         │
                       │              │                │
                       │              │ • 375 NITRO    │
                       │              │ • 35 CLI diffs │
                       │              │ • 50 HTTP      │
                       │              │   probes       │
                       │              │ • Host metrics  │
                       │              └───────┬────────┘
                       │                      │
                       │              ┌───────▼────────┐
                       │              │  HTML Report   │
                       │              │  (artifact)    │
                       │              └────────────────┘
                       │
                       └── Cleanup (always runs): destroy VMs, remove temp files
```

## Quick Start

```bash
# Prerequisites
# - Linux KVM host with libvirt, virsh, qemu-img, mkisofs, expect
# - terraform >= 1.3 with citrix/citrixadc provider ~> 1.45
# - python3, curl
# - Azure DevOps self-hosted agent on the KVM host
# - libvirt network: opn_wan (10.0.1.0/24)

# Trigger from Azure DevOps UI or CLI:
az pipelines run --name "VPX Firmware Regression" \
    --parameters skipDeploy=false demoMode=false

# Demo mode (no VPX hardware needed — generates sample data):
az pipelines run --name "VPX Firmware Regression" \
    --parameters demoMode=true
```

**Pipeline parameters:**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `demoMode` | `true` | Generate sample report without VPX deployment |
| `skipDeploy` | `false` | Reuse already-running VMs (skip KVM provisioning) |
| `baselineTarball` | `NSVPX-KVM-14.1-56.74_nc_64.tgz` | Baseline firmware path |
| `candidateTarball` | `NSVPX-KVM-14.1-60.57_nc_64.tgz` | Candidate firmware path |

## How It Works

### Stage 1: Setup

Validates 6 prerequisites (`virsh`, `terraform`, `expect`, `mkisofs`, `qemu-img`, `curl`), cleans leftover VMs from previous runs, and decodes base64-encoded SSL certificates from pipeline secrets to the filesystem.

### Stage 2: Deploy (Parallel)

Both VPX instances deploy simultaneously with identical steps:

1. **Extract** QCOW2 disk from firmware tarball
2. **Generate** preboot ISO with `NS-PRE-BOOT-CONFIG` XML (management IP, default route)
3. **Boot** libvirt KVM domain (2 vCPU, 2GB RAM, virtio networking)
4. **Wait** for SSH (poll port 22 every 3s, 180s timeout)
5. **Change password** via expect-based SSH session (handles `ForcePasswordChange`)
6. **Terraform Phase A** — system hardening only (`-target module.system`), enables SSL default profile
7. **Warm reboot** — required for SSL default profile activation
8. **Terraform Phase B** — all 4 modules (system, ssl, certificates, traffic)

### Stage 3: Regression Tests

Three layers of validation run against each VPX:

**Layer 1: NITRO API Tests (375 assertions, 16 categories)**

Each Terraform-managed resource is queried via NITRO REST API and validated for existence and field-level correctness:

| Category | Tests | What's Validated |
|----------|-------|-----------------|
| System | 4 | Hostname, DNS servers, NTP |
| Security | 7 | Strong password, session timeout, RPC encryption, audit |
| Features | 9 | LB, CS, SSL, Rewrite, Responder, AAA, AppFlow, CMP, SSLVPN |
| Modes | 5 | FR, TCPB, Edge, L3, ULFD |
| HTTP Profiles | 8 | Default hardened + custom (HTTP/2, WebSocket, invalid request handling) |
| TCP Profiles | 8 | RST attenuation, SYN spoof, ECN, timestamps, DSACK, F-RTO |
| SSL Profiles | 8 | TLS 1.2+, HSTS, cipher priorities, deny renegotiation |
| Certificates | 6 | CertKey objects, file paths, chain validation |
| Servers | 2 | Backend server objects and IPs |
| Monitors | 5 | Health check types, intervals, retries |
| Service Groups | 6 | Service types, member bindings, monitor bindings |
| LB VServers | 7 | LB method, persistence, profile bindings |
| CS VServers | 4 | Content-switching config, SSL bindings |
| CS Policies | 5 | Hostname-based routing rules and actions |
| Bindings | 50+ | All SG→member, SG→monitor, LB→SG, CS→policy, rewrite/responder bindings |
| Deep Values | 30+ | TCP window sizes, SACK, HTTP/2 streams, monitor intervals |

**Layer 2: CLI Output Comparison (35 commands)**

Collects `show` command output from both VPXs, normalizes instance-specific values (IPs → `NSIP`/`SNIP`/`VIP_*`, hostnames → `VPX_HOSTNAME`, timestamps stripped), and diffs the results. Expected differences (version, hardware) are flagged; everything else is PASS or FAIL.

**Layer 3: HTTP Probe Requests (50 per VPX)**

Fires 50 real HTTP requests through each VPX's content-switching VIP across 8 scenarios:

| Requests | Scenario | What's Tested |
|----------|----------|--------------|
| 1–10 | Normal | Standard browsing through `app.lab.local` |
| 11–15 | API | API endpoint routing via `api.lab.local` |
| 16–20 | Static | Static content routing via `static.lab.local` |
| 21–25 | Redirect | HTTP→HTTPS redirect (port 80) |
| 26–35 | Bot | 10 attack tool user-agents (should return 403) |
| 36–38 | CORS | OPTIONS preflight requests |
| 39–42 | Methods | POST, PUT, DELETE, PATCH |
| 43–50 | Burst | Rapid back-to-back requests |

Each probe captures: HTTP status, TCP connect time, TLS handshake time, TTFB, total time, and full response headers (via `curl -D`).

### Stage 4: Cleanup

Runs unconditionally (`always()`) — gracefully shuts down both VMs, undefines them from libvirt, and removes all disk images, ISOs, and decoded certificates.

## HTML Report

The report is a single self-contained HTML file published as an Azure DevOps build artifact. It features a dark-themed UI with:

- **Executive summary** — SVG donut charts (pass/fail/warning per VPX), overall regression delta
- **Category breakdown** — Stacked bar chart per test category, tabbed baseline/candidate views
- **Failures & warnings** — Prominent section with full test details, color-coded badges
- **CLI diffs** — Color-coded unified diffs with syntax highlighting
- **HTTP load profile** — Side-by-side SVG bar chart (baseline cyan, candidate violet, blocked red)
- **Clickable probe detail modal** — Click any bar to see full request metadata, timing breakdown (Connect/TLS/Server/Transfer visual bar), and response headers
- **Security headers checklist** — Baseline vs candidate header comparison table
- **SSL connection details** — Protocol, cipher, certificate chain, key size
- **Resource usage charts** — CPU, memory, disk, network over time (SVG line charts)
- **System logs** — Collapsible tabs for VPX logs from both instances
- **Passed tests** — Collapsible section with full-text search filter
- **CSV export** — One-click download of all results

## Terraform Configuration (~195 Resources)

Four modules organized by dependency and reboot requirements:

```
terraform/
├── main.tf                          Root module (provider + 4 module calls)
├── variables.tf                     11 variables (IPs, hostnames, secrets)
├── baseline.tfvars                  Baseline: 10.0.1.5, SNIP .254, VIP .105
├── candidate.tfvars                 Candidate: 10.0.1.6, SNIP .253, VIP .106
└── modules/
    ├── system/       (~20 resources)  Hostname, DNS, NTP, security, features, modes,
    │                                  HTTP/TCP profile hardening, management lockdown
    ├── ssl/          (~10 resources)  TLS 1.2+ only, 4 AEAD ciphers, HSTS, frontend/
    │                                  backend profiles, deny renegotiation
    ├── certificates/ (~5 resources)   Lab CA + wildcard cert upload, chain linking
    └── traffic/      (~160 resources) Full ADC stack:
        ├── main.tf                    SNIP, profiles, servers, monitors, SGs, LB vservers
        ├── cs.tf                      2 CS vservers, 6 policies (hostname routing)
        ├── security.tf                13 rewrite policies (security headers), bot blocking
        │                              (10 attack tools), rate limiting (100 req/s/IP),
        │                              maintenance mode toggle
        └── extras.tf                  Compression, audit logging, integrated caching
```

**Two-phase apply**: Phase A targets `module.system` only (enables SSL default profile → requires warm reboot). Phase B applies all modules after the reboot.

## Security

- All credentials stored as Azure DevOps secret pipeline variables — never committed
- SSL private keys decoded at runtime to a temp path, cleaned up unconditionally
- SSH automation uses `expect` (VPX keyboard-interactive auth is incompatible with `sshpass`)
- Per-VPX Terraform state files prevent conflicts during parallel deployment
- Bot blocking validates 10 known attack tool signatures (sqlmap, nikto, nmap, nuclei, etc.)
- Security headers validated: X-Frame-Options, CSP, HSTS, X-Content-Type-Options, Referrer-Policy, Permissions-Policy

## Extending the Pipeline

| To add... | Edit... |
|-----------|---------|
| NITRO API test | Append `check_resource`/`check_binding` in `run-comprehensive-tests.sh` |
| CLI comparison | Add to `COMMANDS` array in `run-regression-tests.sh` |
| Expected diff exclusion | Extend `case` statement in diff loop |
| Terraform resource | Add to appropriate module (`system/` if reboot needed, else `traffic/`) |
| IP range change | Update `*.tfvars`, pipeline variables, and normalization patterns |
| New firmware version | Trigger pipeline with different tarball paths |

## Project Structure

```
azure-pipelines.yml                  4-stage pipeline (Setup → Deploy×2 → Test → Cleanup)
blog-post.md                        Technical deep-dive article
tree-table.md                       Full resource inventory and test coverage map

scripts/
  deploy-vpx.sh                     8-step orchestrator (provision → password → terraform)
  provision-vpx.sh                  3-step: create VM → boot → password
  configure-vpx.sh                  3-step: terraform Phase A → reboot → Phase B
  create-vpx-vm.sh                  Extract tarball → preboot ISO → define+start VM
  wait-for-boot.sh                  Poll SSH port until responsive
  wait-for-nitro.sh                 Poll NITRO API (HTTPS→HTTP fallback) until 200
  change-default-password.sh        Expect SSH + NITRO API fallback password change
  reboot-vpx.sh                     SSH warm reboot + force destroy fallback
  cleanup-vm.sh                     Shutdown → undefine → remove storage
  ssh-vpx.sh / ssh-vpx.exp          SSH wrappers for keyboard-interactive auth
  change-password-ssh.exp           Expect script for forced-change prompt
  run-regression-tests.sh           CLI collection, normalize, diff orchestration
  run-comprehensive-tests.sh        375 NITRO API tests (16 categories) + 50 HTTP probes
  generate-html-report.py           Interactive HTML report (charts, diffs, modals, export)
  generate-sample-data.py           Demo mode: realistic sample data without hardware
  generate-junit-report.py          Convert results to JUnit XML for Azure Tests tab
  collect-metrics.sh                Background CPU/RAM/disk/network sampler (10s intervals)

terraform/
  main.tf                           Root module (4 submodules)
  variables.tf / versions.tf        Variables and provider constraints
  baseline.tfvars / candidate.tfvars Per-VPX parameters
  modules/
    system/                         Enterprise hardening (~20 resources)
    ssl/                            TLS profile + cipher config (~10 resources)
    certificates/                   Cert import and chain linking (~5 resources)
    traffic/                        Full ADC stack (~160 resources)

templates/
  userdata.tpl                      NS-PRE-BOOT-CONFIG XML (management IP, gateway)
  vpx-domain.tpl                    Libvirt domain XML (vCPU, RAM, disk, network)

certs/
  lab-ca.crt                        Lab CA certificate
  wildcard.lab.local.crt            Wildcard cert (private key in pipeline secrets)
```
