# Automating NetScaler VPX Firmware Regression Testing with Azure DevOps, KVM, and Terraform

Firmware upgrades on network appliances are high-stakes operations. A single regression — a changed default, a broken cipher binding, a missing security header — can take down production traffic or silently weaken your security posture. The traditional approach is manual: deploy the new firmware, click through the GUI, spot-check a few settings, hope for the best.

This tutorial walks through a fully automated regression testing pipeline that eliminates hope from the equation. It deploys two NetScaler VPX instances side-by-side on KVM — one running the current firmware (baseline), one running the candidate upgrade — applies an identical 195-resource Terraform configuration to both, then runs 375 NITRO API assertions and 35 CLI comparisons to surface every difference. The result is an interactive HTML report that tells you exactly what changed.

```
┌─────────────────────────────────────────────────────────────────────┐
│                      Azure DevOps Pipeline                         │
│                                                                    │
│  ┌──────────┐   ┌─────────────────────┐   ┌──────────┐   ┌─────┐ │
│  │  Setup   │──▶│  Deploy (parallel)  │──▶│  Test    │──▶│Clean│ │
│  │  Stage   │   │                     │   │  Stage   │   │ up  │ │
│  └──────────┘   │ ┌───────────────┐   │   └──────────┘   └─────┘ │
│                  │ │   Baseline    │   │                           │
│  • Validate     │ │  14.1-60.57   │   │   • 375 NITRO tests      │
│    prereqs      │ │  (KVM+TF)     │   │   • 35 CLI diffs         │
│  • Decode       │ ├───────────────┤   │   • System metrics        │
│    certs        │ │   Candidate   │   │   • HTML report           │
│  • Clean VMs    │ │  14.1-66.54   │   │                           │
│                  │ │  (KVM+TF)     │   │                           │
│                  │ └───────────────┘   │                           │
│                  └─────────────────────┘                           │
└─────────────────────────────────────────────────────────────────────┘
```

## Repository Structure

```
azure-devops-kvm-ns-blog/
├── azure-pipelines.yml              # 4-stage pipeline definition
├── scripts/
│   ├── deploy-vpx.sh                # Master orchestrator (8 steps)
│   ├── create-vpx-vm.sh             # KVM VM provisioning
│   ├── change-default-password.sh   # SSH forced-change + NITRO fallback
│   ├── change-password-ssh.exp      # Expect script for SSH auth
│   ├── wait-for-boot.sh             # SSH port polling
│   ├── wait-for-nitro.sh            # NITRO API readiness check
│   ├── reboot-vpx.sh               # Warm reboot (SSH graceful + force)
│   ├── ssh-vpx.sh / ssh-vpx.exp    # SSH command execution via expect
│   ├── run-comprehensive-tests.sh   # 375 NITRO API tests (16 categories)
│   ├── run-regression-tests.sh      # Full regression pipeline orchestrator
│   ├── collect-metrics.sh           # Background CPU/RAM/disk/net monitor
│   ├── generate-html-report.py      # Interactive HTML report generator
│   └── cleanup-vm.sh               # Graceful shutdown → force → undefine
├── templates/
│   ├── userdata.tpl                 # NS-PRE-BOOT-CONFIG XML
│   └── vpx-domain.tpl              # Libvirt domain XML
├── terraform/
│   ├── main.tf                      # Root module (4 submodules)
│   ├── baseline.tfvars              # Baseline IPs and hostname
│   ├── candidate.tfvars             # Candidate IPs and hostname
│   └── modules/
│       ├── system/main.tf           # Identity, security, features, profiles
│       ├── ssl/main.tf              # SSL profiles + AEAD cipher bindings
│       ├── certificates/main.tf     # Cert upload + certkey chain
│       └── traffic/
│           ├── main.tf              # SNIP, profiles, servers, SGs, LB/CS
│           ├── cs.tf                # Content switching vservers + policies
│           ├── security.tf          # Security headers, CORS, bot blocking
│           └── extras.tf            # Maintenance mode, compression, audit
└── certs/
    ├── lab-ca.crt                   # Lab CA certificate
    └── wildcard.lab.local.crt       # Wildcard certificate
```

## The Pipeline: 4 Stages

The pipeline is defined in `azure-pipelines.yml`. It takes two parameters — the paths to the baseline and candidate firmware tarballs — and orchestrates everything from VM provisioning to cleanup.

```yaml
# azure-pipelines.yml
trigger: none

parameters:
  - name: baselineTarball
    displayName: "Baseline firmware tarball path"
    type: string
    default: "/home/aeonadmin/vpx/NSVPX-KVM-14.1-60.57_nc_64.tgz"
  - name: candidateTarball
    displayName: "Candidate firmware tarball path"
    type: string
    default: "/home/aeonadmin/vpx/NSVPX-KVM-14.1-66.54_nc_64.tgz"

variables:
  VM_STORAGE_DIR: /home/vm-data
  BASELINE_NAME: vpx-baseline
  CANDIDATE_NAME: vpx-candidate
  BASELINE_IP: 10.0.1.5
  CANDIDATE_IP: 10.0.1.6
  BOOT_TIMEOUT: "180"
  CERT_DIR: /tmp/vpx-pipeline-certs
```

The key design decision is that Stage 2 runs in **parallel** — both VPX instances deploy simultaneously, cutting total pipeline time nearly in half:

```yaml
stages:
  - stage: Setup          # Phase 1: Validate, decode certs, clean leftovers
  - stage: DeployBaseline # Phase 2a: Deploy baseline VPX
    dependsOn: Setup
  - stage: DeployCandidate # Phase 2b: Deploy candidate VPX (parallel with 2a)
    dependsOn: Setup
  - stage: RegressionTest  # Phase 3: Run all tests
    dependsOn:
      - DeployBaseline
      - DeployCandidate
  - stage: Cleanup         # Phase 4: Always runs
    dependsOn:
      - DeployBaseline
      - DeployCandidate
      - RegressionTest
    condition: always()
```

### Stage 1: Setup

The setup stage validates that the KVM host has all required tools, cleans up any VMs from failed previous runs, and decodes SSL certificates from pipeline secrets:

```yaml
- task: Bash@3
  displayName: "Validate prerequisites"
  inputs:
    targetType: inline
    script: |
      for TOOL in virsh mkisofs expect qemu-img terraform curl; do
        if command -v "$TOOL" &>/dev/null; then
          echo "  [OK] $TOOL"
        else
          echo "  [FAIL] $TOOL not found"
          exit 1
        fi
      done

- task: Bash@3
  displayName: "Decode SSL certificates"
  inputs:
    targetType: inline
    script: |
      mkdir -p "$(CERT_DIR)"
      echo "$LAB_CA_CRT" | base64 -d > "$(CERT_DIR)/lab-ca.crt"
      echo "$WILDCARD_CRT" | base64 -d > "$(CERT_DIR)/wildcard.lab.local.crt"
      echo "$WILDCARD_KEY" | base64 -d > "$(CERT_DIR)/wildcard.lab.local.key"
  env:
    LAB_CA_CRT: $(LAB_CA_CRT)
    WILDCARD_CRT: $(WILDCARD_CRT)
    WILDCARD_KEY: $(WILDCARD_KEY)
```

Certificates are stored as base64-encoded pipeline secrets — never committed to the repository.

## Stage 2: Deploying Two VPX Instances

Each deployment runs through an 8-step orchestration handled by `deploy-vpx.sh`. This is the most complex part of the pipeline.

### The Deployment Orchestrator

```bash
# deploy-vpx.sh invocation from the pipeline
scripts/deploy-vpx.sh \
  --name "$(BASELINE_NAME)" \
  --tarball "${{ parameters.baselineTarball }}" \
  --ip "$(BASELINE_IP)" \
  --password "$NSROOT_PASSWORD" \
  --rpc-password "$RPC_PASSWORD" \
  --cert-dir "$(CERT_DIR)" \
  --tfvars baseline.tfvars \
  --state baseline.tfstate \
  --storage-dir "$(VM_STORAGE_DIR)" \
  --boot-timeout "$(BOOT_TIMEOUT)" \
  --deploy-timeout 1200
```

The 8 steps:

```
Step 1 → Provision KVM VM (create-vpx-vm.sh)
Step 2 → Wait for SSH port (wait-for-boot.sh)
Step 3 → Change default nsroot password (change-default-password.sh)
Step 4 → Terraform init
Step 5 → Terraform Phase A: system module only
Step 6 → Warm reboot (SSL default profile requires this)
Step 7 → Wait for NITRO API (post-reboot)
Step 8 → Terraform Phase B: all modules
```

### Step 1: KVM VM Provisioning

The `create-vpx-vm.sh` script provisions a VPX VM from a firmware tarball in 6 sub-steps:

```bash
# Extract tarball → find QCOW2 → copy to VM storage
tar xzf "$TARBALL_PATH" -C "$WORK_DIR"
QCOW2_FILE=$(find "$WORK_DIR" -name '*.qcow2' -type f | head -1)
sudo cp "$QCOW2_FILE" "$VM_STORAGE_DIR/${VM_NAME}.qcow2"
```

The script then creates a **preboot userdata ISO** — this is how VPX accepts its initial configuration before first boot. The template uses NetScaler's `NS-PRE-BOOT-CONFIG` XML format:

```xml
<!-- templates/userdata.tpl -->
<NS-PRE-BOOT-CONFIG>
    <NS-CONFIG>
        add route 0.0.0.0 0.0.0.0 __GATEWAY__
    </NS-CONFIG>
    <NS-BOOTSTRAP>
        <SKIP-DEFAULT-BOOTSTRAP>YES</SKIP-DEFAULT-BOOTSTRAP>
        <NEW-BOOTSTRAP-SEQUENCE>YES</NEW-BOOTSTRAP-SEQUENCE>
        <MGMT-INTERFACE-CONFIG>
            <INTERFACE-NUM>eth0</INTERFACE-NUM>
            <IP>__NSIP__</IP>
            <SUBNET-MASK>255.255.255.0</SUBNET-MASK>
        </MGMT-INTERFACE-CONFIG>
    </NS-BOOTSTRAP>
</NS-PRE-BOOT-CONFIG>
```

The `SKIP-DEFAULT-BOOTSTRAP` flag is critical — without it, VPX runs an interactive wizard on first boot that blocks automation.

The ISO is created with `mkisofs` and attached as a CDROM in the libvirt domain XML:

```xml
<!-- templates/vpx-domain.tpl -->
<domain type='kvm'>
  <name>__NAME__</name>
  <memory>2097152</memory>
  <vcpu>2</vcpu>
  <cpu mode='host-passthrough'/>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='__DISK__'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='file' device='cdrom'>
      <source file='__ISO__'/>
      <target dev='hdc' bus='ide'/>
      <readonly/>
    </disk>
    <interface type='network'>
      <source network='opn_wan'/>
      <model type='virtio'/>
    </interface>
  </devices>
</domain>
```

### Step 3: Password Change — The Tricky Part

Newer VPX firmware (14.1+) forces a password change on first login. The NITRO API rejects the default password entirely (error 1047). The only way to change it programmatically is through SSH — but VPX uses keyboard-interactive authentication, which means standard `sshpass` doesn't work. You need `expect`:

```bash
# change-default-password.sh validates the new password meets VPX requirements
# before attempting the change:
if [[ ${#NEW_PASSWORD} -lt 8 ]]; then
    echo "ERROR: Password must be at least 8 characters"
    exit 1
fi
# ... checks for uppercase, lowercase, digit, special character

# Then uses an expect script for the SSH forced-change flow
expect "$SCRIPT_DIR/change-password-ssh.exp"

# Finally verifies NITRO accepts the new password
VERIFY_CODE=$(curl -sk -o /dev/null -w '%{http_code}' \
    -H "X-NITRO-USER: nsroot" \
    -H "X-NITRO-PASS: $NEW_PASSWORD" \
    "https://${NSIP}/nitro/v1/config/nsversion")
```

If the SSH method fails (some firmware versions handle it differently), the script falls back to a NITRO API password change using the old password. This defense-in-depth approach handles firmware behavior variations across versions.

### Steps 5–8: Two-Phase Terraform

This is the most important architectural decision in the pipeline. NetScaler's SSL default profile (`sslparameter.defaultprofile = ENABLED`) requires a **warm reboot** before it takes effect. Any SSL profile bindings applied before the reboot will fail silently or produce inconsistent state.

The solution: split Terraform into two phases.

**Phase A** applies only the `system` module using `-target`:

```bash
# Step 5: Phase A — system hardening only
terraform -chdir="$REPO_DIR/terraform" apply \
    -target=module.system \
    -var-file="$TFVARS" \
    -state="$TF_STATE" \
    -auto-approve \
    -input=false \
    -parallelism=2
```

The system module enables the SSL default profile, sets security parameters, configures features/modes, and hardens the default HTTP/TCP profiles:

```hcl
# terraform/modules/system/main.tf
resource "citrixadc_sslparameter" "this" {
  defaultprofile = "ENABLED"  # ← This requires a warm reboot
}

resource "citrixadc_nsfeature" "this" {
  lb        = true
  cs        = true
  ssl       = true
  rewrite   = true
  responder = true
  appflow   = true
  cmp       = true
  sslvpn    = true
  ch        = false  # Call Home disabled
}

resource "citrixadc_systemparameter" "this" {
  strongpassword    = "enableall"
  minpasswordlen    = 8
  maxclient         = 10
  timeout           = 600
  restrictedtimeout = "ENABLED"
}
```

**Steps 6–7** reboot the VPX and wait for the NITRO API to come back:

```bash
# Step 6: Warm reboot
"$SCRIPT_DIR/reboot-vpx.sh" "$NSIP" "$PASSWORD"

# Step 7: Wait for NITRO API
"$SCRIPT_DIR/wait-for-nitro.sh" "$NSIP" "$PASSWORD" "$BOOT_TIMEOUT"
```

**Phase B** applies the full configuration — now that the SSL default profile is active:

```bash
# Step 8: Phase B — everything
terraform -chdir="$REPO_DIR/terraform" apply \
    -var-file="$TFVARS" \
    -state="$TF_STATE" \
    -auto-approve \
    -input=false
```

Each VPX gets its own `.tfvars` file with unique IPs:

```hcl
# baseline.tfvars
nsip     = "10.0.1.5"
hostname = "vpx-baseline"
snip     = "10.0.1.254"
vip_cs   = "10.0.1.105"
vip_tcp  = "10.0.1.115"
vip_dns  = "10.0.1.125"

# candidate.tfvars
nsip     = "10.0.1.6"
hostname = "vpx-candidate"
snip     = "10.0.1.253"
vip_cs   = "10.0.1.106"
vip_tcp  = "10.0.1.116"
vip_dns  = "10.0.1.126"
```

## Terraform Configuration: 195 Resources

The Terraform root module composes four submodules:

```hcl
# terraform/main.tf
provider "citrixadc" {
  endpoint = "https://${var.nsip}"
  username = "nsroot"
  password = var.password
  insecure_skip_verify = true
}

module "system"       { source = "./modules/system" ... }
module "ssl"          { source = "./modules/ssl" }
module "certificates" { source = "./modules/certificates" ... }
module "traffic" {
  source = "./modules/traffic"
  depends_on = [module.ssl, module.certificates]
}
```

### SSL Module: AEAD Ciphers Only

The SSL module configures both frontend and backend profiles with TLS 1.2+ only, and binds a curated set of AEAD ciphers:

```hcl
# terraform/modules/ssl/main.tf
resource "citrixadc_sslprofile" "frontend" {
  name = "ns_default_ssl_profile_frontend"

  ssl3    = "DISABLED"
  tls1    = "DISABLED"
  tls11   = "DISABLED"
  tls12   = "ENABLED"
  tls13   = "ENABLED"

  denysslreneg = "NONSECURE"
  hsts         = "ENABLED"
  maxage       = 31536000  # 1 year HSTS
}

resource "citrixadc_sslprofile_sslcipher_binding" "frontend_aes256_gcm" {
  name           = citrixadc_sslprofile.frontend.name
  ciphername     = "TLS1.2-AES256-GCM-SHA384"
  cipherpriority = 1
}

resource "citrixadc_sslprofile_sslcipher_binding" "frontend_tls13_chacha" {
  name           = citrixadc_sslprofile.frontend.name
  ciphername     = "TLS1.3-CHACHA20-POLY1305-SHA256"
  cipherpriority = 4
}
```

Only four ciphers are bound — all GCM or ChaCha20-Poly1305. No CBC, no RC4, no 3DES. This is an explicit, auditable cipher policy.

### Certificates Module: Upload + Chain

```hcl
# terraform/modules/certificates/main.tf
resource "citrixadc_systemfile" "wildcard_crt" {
  filename     = "wildcard.lab.local.crt"
  filelocation = "/nsconfig/ssl/"
  filecontent  = var.wildcard_crt  # Passed via TF_VAR from pipeline
}

resource "citrixadc_sslcertkey" "wildcard" {
  certkey         = "wildcard.lab.local"
  cert            = "/nsconfig/ssl/wildcard.lab.local.crt"
  key             = "/nsconfig/ssl/wildcard.lab.local.key"
  linkcertkeyname = citrixadc_sslcertkey.lab_ca.certkey  # Chain to CA
}
```

Certificate file contents are passed as Terraform variables from the pipeline's decoded secrets — never stored in the state file as file paths.

### Traffic Module: The Enterprise Configuration

The traffic module is the largest, split across four files. Here are the key patterns:

**Custom profiles with hardened defaults:**

```hcl
# terraform/modules/traffic/main.tf
resource "citrixadc_nstcpprofile" "web" {
  name               = "tcp_prof_web"
  flavor             = "CUBIC"
  ws                 = "ENABLED"
  sack               = "ENABLED"
  nagle              = "DISABLED"
  ecn                = "ENABLED"
  initialcwnd        = 16
  oooqsize           = 300
  ka                 = "ENABLED"
  kaconnidletime     = 300
  rstwindowattenuate = "ENABLED"
  spoofsyndrop       = "ENABLED"
}

resource "citrixadc_nshttpprofile" "web" {
  name                         = "http_prof_web"
  http2                        = "ENABLED"
  http2maxconcurrentstreams    = 128
  websocket                    = "ENABLED"
  dropinvalreqs                = "ENABLED"
  markrfc7230noncompliantinval = "ENABLED"
  conmultiplex                 = "ENABLED"
}
```

**Content switching for hostname-based routing:**

```hcl
# terraform/modules/traffic/cs.tf
resource "citrixadc_csvserver" "https" {
  name            = "cs_vsrv_https"
  servicetype     = "SSL"
  ipv46           = var.vip_cs
  port            = 443
  clttimeout      = 180
  httpprofilename = citrixadc_nshttpprofile.web.name
  tcpprofilename  = citrixadc_nstcpprofile.web.name
  sslprofile      = "ns_default_ssl_profile_frontend"
}

resource "citrixadc_cspolicy" "api" {
  policyname = "cs_pol_api"
  rule       = "HTTP.REQ.HOSTNAME.EQ(\"api.lab.local\")"
  action     = citrixadc_csaction.api.name
}
```

**Security headers — 23 rewrite policies:**

```hcl
# terraform/modules/traffic/security.tf
resource "citrixadc_rewriteaction" "csp" {
  name              = "rw_act_csp"
  type              = "insert_http_header"
  target            = "Content-Security-Policy"
  stringbuilderexpr = "\"default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'\""
}

# Strip server fingerprints
resource "citrixadc_rewriteaction" "del_server" {
  name   = "rw_act_del_server"
  type   = "delete_http_header"
  target = "Server"
}

resource "citrixadc_rewriteaction" "del_powered" {
  name   = "rw_act_del_powered"
  type   = "delete_http_header"
  target = "X-Powered-By"
}
```

**Bot blocking with pattern sets:**

```hcl
resource "citrixadc_policypatset" "bad_useragents" {
  name = "ps_bad_useragents"
}

resource "citrixadc_policypatset_pattern_binding" "ua_sqlmap" {
  name   = citrixadc_policypatset.bad_useragents.name
  string = "sqlmap"
  index  = 1
}
# ... nikto, nmap, nuclei, masscan, dirbuster, gobuster, wpscan, ZmEu, python-requests

resource "citrixadc_responderpolicy" "block_bot" {
  name   = "rs_pol_block_bot"
  rule   = "HTTP.REQ.HEADER(\"User-Agent\").CONTAINS_ANY(\"ps_bad_useragents\")"
  action = citrixadc_responderaction.block_bot.name
}
```

**Maintenance mode with runtime variables:**

```hcl
# terraform/modules/traffic/extras.tf
resource "citrixadc_nsvariable" "maintenance" {
  name  = "v_maintenance"
  type  = "ulong"
  scope = "global"
}

resource "citrixadc_responderpolicy" "maintenance" {
  name   = "rs_pol_maint1"
  rule   = "$v_maintenance.EQ(1)"
  action = citrixadc_responderaction.maintenance.name
}
```

This allows enabling/disabling maintenance mode at runtime without redeploying — just change the variable value via NITRO API.

## Stage 3: Regression Testing

The test stage runs after both VPX instances are deployed. It has three layers.

### Layer 1: NITRO API Tests (375 Assertions, 16 Categories)

The `run-comprehensive-tests.sh` script validates every Terraform-managed object via the NITRO REST API. It uses three core test functions:

```bash
# Check a resource exists and optionally verify a field value
check_resource() {
    local category="$1" resource_path="$2"
    local field="${3:-}" expected_value="${4:-}"

    response=$(nitro_get "$resource_path")
    http_code=$(echo "$response" | tail -1)

    if [[ "$http_code" != "200" ]]; then
        record_result "$category" "${resource_path} exists" "FAIL" "HTTP 200" "HTTP $http_code"
        return 0
    fi

    record_result "$category" "${resource_path} exists" "PASS" "exists" "exists"

    if [[ -n "$field" ]] && [[ -n "$expected_value" ]]; then
        actual_value=$(extract_field "$body" "$field")
        if [[ "${actual_value,,}" == "${expected_value,,}" ]]; then
            record_result "$category" "${resource_path} ${field}" "PASS" "$expected_value" "$actual_value"
        else
            record_result "$category" "${resource_path} ${field}" "FAIL" "$expected_value" "$actual_value"
        fi
    fi
}

# Check a binding exists in a NITRO binding list
check_binding() {
    local category="$1" binding_path="$2" match_field="$3" match_value="$4"
    # ... validates binding exists and optionally checks a property
}

# Check feature/mode status via SSH show commands
check_feature() {
    local category="$1" name="$2" expected="$3" show_output="$4"
    # Maps ENABLED/DISABLED → ON/OFF for VPX output format
}
```

The 16 test categories cover the full configuration surface:

| Category | Tests | What It Checks |
|----------|-------|----------------|
| System | 4 | Hostname, DNS servers, NTP |
| Security | 7 | Strong password, timeout, RPC node |
| Features | 9 | LB, CS, SSL, Rewrite, Responder, AppFlow, CMP |
| Modes | 5 | FR, TCPB, Edge, L3, ULFD |
| Profiles | 16 | HTTP/TCP default + custom profiles |
| SSL | 8 | Frontend/backend profiles, protocol versions |
| Certificates | 6 | CertKey objects, file uploads, chain |
| Servers | 2 | Server objects and IP addresses |
| Monitors | 5 | HTTP, TCP, HTTPS monitors |
| ServiceGroups | 6 | Service types and group settings |
| LBVservers | 7 | LB methods, persistence, service types |
| CSVservers | 4 | CS vservers, ports, service types |
| CSPolicies | 5 | Policy rules and action targets |
| Bindings | 50+ | SG→member, SG→monitor, LB→SG, CS→policy, CS→SSL, rewrite, responder, compression |
| Deep Values | 30+ | TCP profile tuning values, HTTP2 settings, monitor intervals |
| Network | 10+ | SNIP, VIP addresses, patset patterns |

Example test calls:

```bash
# SSL profile validation
check_resource "SSL" "sslprofile/ns_default_ssl_profile_frontend" "tls13" "ENABLED"
check_resource "SSL" "sslprofile/ns_default_ssl_profile_frontend" "denysslreneg" "NONSECURE"

# Binding validation
check_binding "CSBindings" "csvserver_cspolicy_binding/cs_vsrv_https" \
    "policyname" "cs_pol_api" "priority" "100"

# Bot blocking patset patterns
for ua_pattern in sqlmap nikto nmap nuclei masscan dirbuster gobuster python-requests; do
    check_binding "BotPatterns" \
        "policypatset_pattern_binding/ps_bad_useragents" "String" "$ua_pattern"
done
```

### Layer 2: CLI Output Comparison (35 Commands)

NITRO tests catch per-object regressions. CLI diffs catch everything else — output format changes, hidden defaults, reorder bugs. The script collects output from 35 `show` commands on both VPXs:

```bash
COMMANDS=(
    "show ns version"
    "show ns feature"
    "show ns mode"
    "show ssl parameter"
    "show ssl profile ns_default_ssl_profile_frontend"
    "show lb vserver"
    "show cs vserver"
    "show serviceGroup sg_web_http"
    "show rewrite policy"
    "show responder policy"
    "show ssl certKey"
    "show ns ip"
    # ... 35 total
)
```

The critical step is **normalization** — without it, every diff would show the IP addresses and hostname as false positives:

```bash
normalize() {
    local FILE="$1"
    sed -i \
        -e "s/$BASELINE_IP/NSIP/g" \
        -e "s/$CANDIDATE_IP/NSIP/g" \
        -e 's/10\.0\.1\.254/SNIP/g' \
        -e 's/10\.0\.1\.253/SNIP/g' \
        -e 's/10\.0\.1\.105/VIP_CS/g' \
        -e 's/10\.0\.1\.106/VIP_CS/g' \
        -e 's/vpx-baseline/VPX_HOSTNAME/g' \
        -e 's/vpx-candidate/VPX_HOSTNAME/g' \
        -e '/uptime/Id' \
        -e '/since/Id' \
        -e '/^[[:space:]]*$/d' \
        "$FILE"
}
```

Instance-specific values (IPs, hostnames, uptime) are replaced with placeholders. Both files are sorted before diffing to eliminate ordering differences across firmware versions.

The diff classification is intentional:

```bash
if diff -u "$SORTED_B" "$SORTED_C" > "$DIFF_FILE" 2>&1; then
    DIFF_PASSED=$((DIFF_PASSED + 1))
else
    case "$CMD" in
        "show ns version"|"show ns hardware")
            DIFF_EXPECTED=$((DIFF_EXPECTED + 1))  # Expected to differ
            ;;
        *)
            DIFF_FAILED=$((DIFF_FAILED + 1))      # Unexpected regression
            ;;
    esac
fi
```

Version and hardware diffs are expected (the whole point is different firmware). Everything else is flagged as a potential regression.

### Layer 3: Background System Metrics

During the entire test run, `collect-metrics.sh` samples host resources every 10 seconds:

```bash
# CSV output: timestamp,cpu_pct,mem_used_mb,mem_total_mb,mem_pct,
#             disk_used_gb,disk_total_gb,disk_pct,net_rx_mbps,net_tx_mbps

# CPU via /proc/stat delta
read -r CURR_TOTAL CURR_IDLE <<< "$(read_cpu)"
CPU_PCT=$(awk "BEGIN {printf \"%.1f\", 100 * (1 - $IDLE_DIFF / $TOTAL_DIFF)}")

# Network via /proc/net/dev delta
RX_MBPS=$(awk "BEGIN {printf \"%.2f\", $RX_BYTES / ($ELAPSED_NS / 1000000000) / 1048576}")
```

This data feeds into the HTML report's resource usage charts — useful for verifying that the test host wasn't resource-starved during testing.

## The HTML Report

The `generate-html-report.py` script produces a self-contained HTML file with:

- **Executive summary** — SVG donut charts showing pass rates for both VPXs, plus a regression comparison card
- **Category breakdown** — Bar charts showing per-category pass/fail counts with tabs for baseline vs. candidate
- **Failures & warnings** — Prominently displayed with full details (expected value, actual value)
- **CLI differences** — Auto-expanded diffs with color-coded additions/removals
- **Resource usage** — SVG line charts for CPU, memory, network, and disk over time
- **Passed tests** — Collapsible by category with search
- **System logs** — VPX system logs from both instances (messages, ns.log, events, running config)
- **CSV export** — One-click download of all test results

The report is completely self-contained — no external dependencies, no CDN references. It can be opened in any browser, shared as an email attachment, or archived as a pipeline artifact.

```python
# SVG donut chart generator
def svg_pie(passed, failed, warnings=0, size=140):
    total = passed + failed + warnings
    cx, cy, r = size/2, size/2, size/2 - 10
    r2 = r - 15  # Inner radius for donut shape
    # ... generates SVG path arcs for each segment
    pct = round(passed / total * 100)
    return f'''<svg width="{size}" height="{size}">
        {paths}
        <text x="{cx}" y="{cy}" text-anchor="middle">{pct}%</text>
    </svg>'''
```

## Stage 4: Cleanup

The cleanup stage always runs — even if deployment or testing failed. It follows a graceful shutdown → force destroy → undefine → remove storage pattern:

```bash
# cleanup-vm.sh
if [[ "$STATE" == "running" ]]; then
    sudo virsh shutdown "$VM_NAME" || true
    # Wait up to 30s for graceful shutdown
    for i in $(seq 1 6); do
        sleep 5
        STATE=$(sudo virsh domstate "$VM_NAME" 2>/dev/null || echo "unknown")
        [[ "$STATE" != "running" ]] && break
    done
fi

# Force destroy if still running
if [[ "$STATE" == "running" ]]; then
    sudo virsh destroy "$VM_NAME" || true
fi

# Undefine and remove storage
sudo virsh undefine "$VM_NAME" || true
sudo rm -f "$VM_STORAGE_DIR/${VM_NAME}.qcow2"
sudo rm -f "$VM_STORAGE_DIR/${VM_NAME}-userdata.iso"
```

The pipeline verifies cleanup with a final check:

```yaml
- task: Bash@3
  displayName: "Verify no VMs left behind"
  inputs:
    targetType: inline
    script: |
      echo "Current VM list:"
      sudo virsh list --all
      echo "VM storage contents:"
      ls -lh "$(VM_STORAGE_DIR)/"
```

## Running the Pipeline

### Prerequisites

1. **KVM host** — Linux with libvirt, QEMU, and a `opn_wan` network configured
2. **Azure DevOps agent** — Self-hosted agent on the KVM host with `sudo` access to `virsh`
3. **VPX firmware tarballs** — Downloaded from Citrix (requires a valid license/account)
4. **Terraform** — With the `citrixadc` provider
5. **Tools** — `virsh`, `mkisofs`, `expect`, `qemu-img`, `terraform`, `curl`

### Pipeline Variables (Secrets)

| Variable | Purpose |
|----------|---------|
| `NSROOT_PASSWORD` | Password to set on both VPX instances |
| `RPC_PASSWORD` | Password for the RPC node (inter-VPX communication) |
| `LAB_CA_CRT` | Base64-encoded CA certificate |
| `WILDCARD_CRT` | Base64-encoded wildcard certificate |
| `WILDCARD_KEY` | Base64-encoded wildcard private key |

### Triggering a Run

The pipeline uses `trigger: none` — it's always triggered manually with the firmware tarball paths as parameters. In Azure DevOps, click "Run pipeline" and specify the baseline and candidate tarball paths.

### Interpreting Results

The pipeline publishes the HTML report as a build artifact. Download it and open in a browser. Look for:

1. **Overall badge** — PASS (green) means all NITRO tests passed on both VPXs. FAIL (red) means at least one assertion failed.
2. **CLI diffs** — Any diff that isn't `show ns version` or `show ns hardware` is worth investigating.
3. **Category breakdown** — If a category has failures on the candidate but not the baseline, that's a firmware regression.

## Key Takeaways

**Two-phase Terraform for appliances that need reboots.** Network appliances often require reboots between configuration phases. The `-target` flag lets you apply partial state, reboot, then apply the rest. This pattern works for any appliance with reboot-dependent features.

**Normalization makes diffs meaningful.** Without replacing instance-specific values (IPs, hostnames, timestamps), every diff would be a false positive. The normalization step is what makes CLI comparison actually useful for regression detection.

**375 per-object tests catch what CLI diffs miss (and vice versa).** NITRO tests validate individual object properties — "is this cipher bound with priority 1?" CLI diffs catch aggregate changes — "did the output format of `show ssl profile` change?" Together, they cover the full regression surface.

**Always-run cleanup prevents resource leaks.** Azure DevOps's `condition: always()` ensures VMs are destroyed even if the pipeline fails mid-deployment. Without this, failed runs would accumulate orphaned VMs and fill the disk.

**This pattern applies to any network appliance.** Replace the `citrixadc` Terraform provider with `bigip` (F5), `panos` (Palo Alto), or `fortios` (Fortinet) and the same architecture works: deploy two instances, apply identical configs, diff the results. The test framework is bash and curl — it works against any REST API.
