[![Build Status](https://dev.azure.com/meyuy43h2/netscaler-vpx-regression/_apis/build/status/VPX%20Firmware%20Regression?branchName=main)](https://dev.azure.com/meyuy43h2/netscaler-vpx-regression/_build/latest?definitionId=2&branchName=main)

# Automated Regression Testing for NetScaler VPX Firmware Upgrades

Firmware upgrades on network appliances are high-stakes changes. A new build might alter TLS negotiation behavior, break a rewrite policy, silently reorder cipher suites, or change how a health monitor evaluates backend responses. In production, these differences surface as outages. The standard approach — upgrade a single device, run a few manual checks, and hope nothing broke — doesn't scale and doesn't inspire confidence. You need a way to know exactly what changed before a single production packet is affected.

This project is an automated regression testing pipeline that deploys two NetScaler VPX instances side by side on KVM, applies identical enterprise configurations via Terraform, runs 375 NITRO API tests and 35 CLI comparisons on each, monitors host resource usage throughout, and produces an interactive HTML report showing exactly what changed between firmware versions. One VPX runs the current firmware (baseline), the other runs the candidate build. If the outputs match, the upgrade is safe. If they don't, the report tells you precisely what diverged.

## Architecture and Deployment

The pipeline runs as an Azure DevOps multi-stage pipeline on a self-hosted Linux agent — the same KVM host that provisions the virtual appliances. A manual trigger lets you specify which two firmware tarballs to compare. From there, everything is automated across four stages.

Both VPX instances are deployed in parallel. Each follows the same sequence: extract the QCOW2 disk image from the firmware tarball, generate a preboot userdata ISO using NetScaler's `NS-PRE-BOOT-CONFIG` mechanism to inject the management IP and default route, build a libvirt domain XML defining the VM's CPU, memory, disk, and network bridge attachment, and boot the VM. The preboot configuration means the appliance comes up with networking already configured — no manual console interaction required.

Once SSH is reachable, the pipeline handles first-login password policy enforcement. Newer VPX firmware versions enforce `ForcePasswordChange`, rejecting the default credentials via the NITRO API entirely. The pipeline uses an expect-based SSH session to navigate the forced-change prompt, set the new password, disable `ForcePasswordChange`, and save the configuration — all in a single CLI session. Standard tools like `sshpass` are incompatible with VPX's keyboard-interactive authentication, so expect scripts handle all SSH automation throughout the pipeline.

## Infrastructure as Code with Terraform

All VPX configuration is managed through Terraform using the `citrix/citrixadc` provider (v1.45), which communicates with the NITRO REST API. The configuration is organized into four modules totaling approximately 195 managed resources per appliance:

**System** covers enterprise hardening: hostname, DNS (Cloudflare + Google), NTP, password policy enforcement, session timeout limits, RPC node encryption, feature enablement (LB, CS, SSL, Rewrite, Responder, AAA, AppFlow, CMP, SSLVPN), mode configuration, HTTP profile hardening (drop invalid requests, block HTTP/0.9, CONNECT, and TRACE methods), TCP profile hardening (RST attenuation, SYN spoof protection, ECN, timestamps), management lockdown (HTTPS-only GUI with restricted access), and audit logging.

**SSL** configures TLS default profile enablement and cipher group bindings. Only TLS 1.2 and 1.3 are permitted, with four AEAD ciphers (AES-256-GCM, AES-128-GCM, AES-256-GCM-SHA384 for TLS 1.3, and CHACHA20-POLY1305). HSTS is enforced with a one-year max-age, and non-secure renegotiation is denied.

**Certificates** handles lab CA and wildcard certificate import, upload via NITRO systemfile resources, and certificate-key linking.

**Traffic** contains the full application delivery stack: subnet IPs, custom TCP/HTTP profiles (CUBIC congestion control, HTTP/2, WebSocket support), backend server objects, health monitors, four service groups, five LB vservers, two content-switching vservers with hostname-based routing, HTTP-to-HTTPS redirect, 13 rewrite policies for security headers (X-Frame-Options, X-Content-Type-Options, CSP, Referrer-Policy, Permissions-Policy, HSTS, server header removal, X-Forwarded-For injection), rate limiting at 100 requests per second per client IP, bot blocking via pattern set matching against 10 known attack tools (sqlmap, nikto, nmap, nuclei, masscan, dirbuster, gobuster, and others), a maintenance mode toggle using global variables and responder policies, response compression for text, JSON, JavaScript, XML, and SVG, and audit message actions for request and response logging.

Deployment uses a two-phase Terraform apply strategy. Phase A targets only the system module — this enables the SSL default profile, which requires a warm reboot before SSL profile bindings take effect. After rebooting the VPX via SSH and waiting for the NITRO API to come back online, Phase B applies all four modules together. This two-phase approach is necessary because the `citrixadc` provider cannot apply SSL profile bindings until the default profile parameter has been activated and the appliance has restarted.

## Testing: Two Layers of Validation

Testing happens in two complementary layers that together provide both per-object correctness validation and holistic configuration parity checking.

**Layer 1: NITRO API Validation** runs 375 individual tests across 16 categories. Each Terraform-managed resource is queried directly through the NITRO API to verify existence and field-level correctness. The categories span system identity, security parameters, enabled features and modes, HTTP and TCP profiles (both default and custom), SSL profiles and cipher bindings, certificates, backend servers, health monitors, service groups with member bindings, LB vservers with profile and policy bindings, CS vservers with action and policy bindings, rewrite/responder/compression policies, all policy-to-vserver bindings, deep configuration values (pattern sets, string maps, rate limit identifiers), certificate expiry validation, and network IP allocation. Tests are parametrized per VPX so that expected values like virtual IP addresses and subnet IPs are correct for each instance.

**Layer 2: CLI Output Comparison** collects output from 35 `show` commands on each VPX — covering features, modes, SSL parameters, cipher bindings, HTTP and TCP profiles, vserver states, policy listings, service groups, pattern sets, string maps, certificate keys, and more. Outputs are normalized to strip instance-specific values: management IPs are replaced with `NSIP`, subnet IPs with `SNIP`, virtual IPs with `VIP_CS`/`VIP_TCP`/`VIP_DNS`, hostnames with `VPX_HOSTNAME`, and lines containing uptime or timestamp data are removed. Numbered list prefixes and cipher priority values are also stripped so that the same set of ciphers appearing at different priority positions doesn't produce a false-positive diff. After normalization, both files are sorted and compared with `diff`. Version and hardware strings are flagged as expected differences; everything else is PASS or FAIL.

## Resource Monitoring

A background metrics daemon runs throughout the regression test phase, sampling host resource utilization every 10 seconds. It tracks CPU usage (via `/proc/stat` delta calculation), memory consumption (using `MemAvailable` from `/proc/meminfo` for accuracy), root filesystem disk usage, and network throughput on the primary interface (byte counter deltas from `/proc/net/dev`). All samples are written to a CSV file and fed into the HTML report generator, which renders SVG line charts for each metric along with peak and average summary statistics. This gives visibility into whether the testing workload is approaching host capacity limits.

## Interactive HTML Report

Both test layers, CLI diffs, system logs, and resource metrics feed into a single self-contained HTML report. The report features a dark-themed UI with SVG donut charts showing pass/fail/warning breakdowns per VPX, horizontal bar charts for per-category results, tabbed views switching between baseline and candidate data, and a prominently displayed failures section. CLI differences are rendered as color-coded unified diffs with syntax highlighting for additions, deletions, and hunk headers. System logs (messages, ns.log, events, running config) are collected from both VPXs and displayed in collapsible, tabbed sections. Resource usage charts show CPU, memory, network throughput, and disk utilization over time. Full-text search filters passed tests in real time, and a CSV export button lets you download all results for offline analysis. The report is published as an Azure DevOps build artifact.

## Pipeline Structure

The Azure DevOps pipeline is organized into four stages:

- **Setup** validates prerequisites (virsh, terraform, expect, mkisofs, qemu-img, curl), checks disk space and network availability, cleans up leftover VMs from previous runs, and decodes SSL certificates from base64-encoded pipeline secrets to a shared filesystem path.
- **Deploy Baseline** and **Deploy Candidate** run in parallel after Setup, each executing the full deployment sequence against their respective firmware tarballs. With a single self-hosted agent they queue sequentially, but the dependency graph is correct for parallel execution if additional agents are added.
- **Regression Tests** runs after both deploys complete, executing the comprehensive NITRO API tests, CLI collection and comparison, resource monitoring, and HTML report generation.
- **Cleanup** depends on all prior stages with an unconditional `always()` condition, guaranteeing both VMs are destroyed and all temporary files (disk images, ISOs, decoded certificates) are removed even if any earlier stage fails.

## Enterprise Considerations

Credentials never touch the repository. The VPX admin password, RPC node password, and the full SSL certificate chain (CA cert, wildcard cert, wildcard key) are stored as Azure DevOps secret pipeline variables and decoded at runtime. Certificate decoding happens once during Setup and the files are shared via a temporary host path that is cleaned up unconditionally.

SSH automation uses expect throughout because VPX's keyboard-interactive authentication is incompatible with standard tools like `sshpass`. All SSH commands include retry logic with configurable attempts and backoff delays. Terraform state files are stored per-VPX (baseline.tfstate and candidate.tfstate) to prevent conflicts during parallel deployment.

## Extending the Pipeline

The pipeline is designed to be modular. Add NITRO API tests by appending `check_resource`, `check_flag`, or `check_binding` calls in `run-comprehensive-tests.sh`. Add CLI comparisons by appending to the `COMMANDS` array in `run-regression-tests.sh`. Add expected diff exclusions by extending the `case` statement in the diff loop. Add Terraform resources to the appropriate module — system-level resources that require a reboot go in `modules/system/`, everything else in the remaining modules. Change IP ranges by updating `baseline.tfvars`, `candidate.tfvars`, the pipeline variables block, and the normalization patterns. Test additional firmware versions by triggering multiple pipeline runs with different tarball paths.

## Prerequisites

- Linux KVM host with `libvirt`, `virsh`, `qemu-img`
- `mkisofs` (from `cdrtools` or `genisoimage`)
- `expect` for keyboard-interactive SSH
- `terraform` >= 1.3 with `citrix/citrixadc` provider ~> 1.45
- `python3` for HTML report generation
- libvirt network `opn_wan` (10.0.1.0/24)
- Azure DevOps self-hosted agent on the KVM host (pool: `Default`)
- Two NetScaler VPX KVM firmware tarballs (`.tgz` containing `.qcow2`)

## Project Structure

```
azure-pipelines.yml                  Azure DevOps pipeline (4 stages, parallel deploys)

scripts/
  deploy-vpx.sh                     Orchestrator: KVM provision + password + Terraform
  create-vpx-vm.sh                  Extract tarball, create preboot ISO, define+start VM
  wait-for-boot.sh                  Poll SSH until VPX responds
  change-default-password.sh         Expect-based password change + disable ForcePasswordChange
  change-password-ssh.exp            Expect script for interactive password change flow
  ssh-vpx.sh / ssh-vpx.exp          SSH wrappers for keyboard-interactive auth
  reboot-vpx.sh                     SSH warm reboot wrapper
  wait-for-nitro.sh                 Poll NITRO API (HTTPS first, HTTP fallback)
  run-regression-tests.sh           CLI collection, normalize, diff, metrics, report orchestration
  run-comprehensive-tests.sh         375 NITRO API tests across 16 categories
  generate-html-report.py           Interactive HTML report (SVG charts, search, CSV export)
  collect-metrics.sh                Background CPU/RAM/disk/network monitor (CSV output)
  cleanup-vm.sh                     Shutdown, undefine, remove VM storage

terraform/
  main.tf                           Root module calling 4 submodules
  variables.tf / versions.tf        Variables and provider constraints
  baseline.tfvars / candidate.tfvars Per-VPX IP and hostname parameters
  modules/
    system/                         Enterprise hardening (~20 resources)
    ssl/                            SSL/TLS profile + cipher configuration (~10 resources)
    certificates/                   Certificate import and linking (~5 resources)
    traffic/                        Full traffic management stack (~160 resources)

templates/
  userdata.tpl                      Preboot config XML (management IP, gateway)
  vpx-domain.tpl                    Libvirt domain XML (vCPU, RAM, disk, network)
```
