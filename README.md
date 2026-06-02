# Dynatrace Observability Demo

End-to-end observability demo built on [Dynatrace](https://dynatrace.com) and [EasyTravel](https://github.com/Dynatrace/easyTravel-Docker). Provisions a live AWS environment, installs OneAgent via Ansible, and runs k6 load tests that trigger real Davis AI problems — all from a single `make` command.

Designed as a hands-on interview/demo showcase for platform engineering and SRE roles.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Local machine                                              │
│  Terraform ──► AWS EC2 (t3.large, ap-southeast-2)          │
│  Ansible   ──► Docker Compose (EasyTravel) + OneAgent       │
│  k6        ──► Load tests (baseline / spike / soak)         │
│  deploy.sh ──► Dynatrace Grail tenant (dashboards, SLOs)    │
└─────────────────────────────────────────────────────────────┘
```

**EasyTravel** is a multi-tier Java travel booking app used here as a stand-in wealth platform. OneAgent auto-instruments all JVM services — no application code changes required.

| Port | Service |
|------|---------|
| 80   | Adviser Portal — Classic (JSP) |
| 8079 | Problem Patterns Admin UI (fault injection) |
| 8080 | Adviser Portal — Angular |
| 8091 | Platform API / Trade Engine (backend REST) |

---

## Prerequisites

| Tool | Min version | Install |
|------|-------------|---------|
| Terraform | 1.6 | [terraform.io](https://developer.hashicorp.com/terraform/install) |
| Ansible | 2.14 | `pip install ansible` |
| k6 | 0.49 | [k6.io](https://k6.io/docs/get-started/installation/) |
| AWS CLI | 2.x | [aws.amazon.com/cli](https://aws.amazon.com/cli/) |
| jq | 1.6 | `apt/brew install jq` |
| curl | any | pre-installed on most systems |

AWS profile `dt` must be configured (`~/.aws/credentials`).

---

## Quick Start

```bash
# 1. One-time: create Terraform state backend (S3 + DynamoDB)
make bootstrap

# 2. One-time: terraform init + ansible-galaxy collections
make init

# 3. Copy and fill in config
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit: set your public IP(s) in allowed_cidr

cp ansible/vault/secrets.yml.example ansible/vault/secrets.yml
# Edit: add your Dynatrace API token
ansible-vault encrypt ansible/vault/secrets.yml --vault-password-file .vault_pass

# 4. Deploy everything
make up

# 5. Run a load test
make baseline        # normal traffic
make spike           # triggers Davis AI problem (~2 min detection)
```

---

## Configuration

### Terraform (`terraform/terraform.tfvars`)

```hcl
aws_region    = "ap-southeast-2"
aws_profile   = "dt"
project_name  = "dt-demo"
instance_type = "t3.large"

# Your public IPs — run: curl checkip.amazonaws.com
allowed_cidr = [
  "1.2.3.4/32",   # home
  "5.6.7.8/32",   # work
]
```

### Environment variables (`.env`)

```bash
DT_API_TOKEN=dt0c01.xxxx   # Dynatrace API token
DT_ENV_ID=your-env-id      # Dynatrace environment ID (e.g. abc12345)
```

`.env` is gitignored. Copy `.env.example` as a starting point.

### Dynatrace API token scopes

The token needs the following scopes:

| Scope | Used for |
|-------|---------|
| `settings.read` + `settings.write` | Ownership teams, anomaly detection config |
| `slo.read` | Reading existing SLOs |

> **Note:** `slo.write` and the Document API (dashboards) require OAuth2 on Grail/Platform tenants and cannot use API tokens. See [Manual Steps](#manual-steps) below.

### Ansible vault (`ansible/vault/secrets.yml`)

```yaml
dt_api_token: "dt0c01.your_token_here"
```

Encrypt before committing:
```bash
make vault-encrypt
```

---

## Make Commands

```
make                 Show help
make bootstrap       [ONCE] Create S3 bucket + DynamoDB for Terraform state
make init            [ONCE] Initialise Terraform and install Ansible collections
make plan            Show Terraform execution plan
make up              FULL STACK: terraform apply + ansible provision + DT configs
make provision       Re-run Ansible only (instance must already exist)
make provision-app   Re-deploy EasyTravel only (fastest re-deploy)
make provision-agent Re-install Dynatrace OneAgent only
make restart         Restart EasyTravel containers in-place (~30s)
make dashboards      Push all Dynatrace configs (SLOs, anomaly detection)
make baseline        k6: 20 VUs, 5 min — normal trading day
make spike           k6: ramp to 150 VUs — triggers Davis AI problem
make stress          k6: ramp to 200 VUs — find breaking point
make soak            k6: 30 VUs for 30 min — expose memory leaks
make soak-short      k6: 30 VUs for 5 min — demo-friendly soak
make status          Print instance info + live connectivity check
make down            FULL TEARDOWN: destroy all AWS infrastructure
make vault-encrypt   Encrypt ansible/vault/secrets.yml
make vault-decrypt   Decrypt ansible/vault/secrets.yml for editing
make ansible-deps    Install Python deps (boto3 for dynamic inventory)
make check-deps      Verify all required tools are installed
```

---

## Demo Scenarios

### 1. Spike — Davis AI problem detection

```bash
make spike
```

Ramps to 150 VUs over 2 minutes. Davis AI automatically detects the traffic spike, correlates the root cause across service → process → host, and opens a Problem ticket — no alert rules required.

Watch: `https://<env-id>.live.dynatrace.com/ui/problems`

### 2. Soak — Memory leak & connection pool exhaustion

```bash
make soak-short   # 5 min (demo)
make soak         # 30 min (full)
```

Sustained load at 30 VUs. Watch for:

| Signal | Indicator | Meaning |
|--------|-----------|---------|
| JVM Heap climbing | SRE Dashboard → JVM Heap tile | Memory leak |
| GC Suspension rising | SRE Dashboard → GC Suspension tile | Heap pressure |
| DB Call Duration drifting up | SRE Dashboard → DB Call Duration tile | Connection pool exhaustion |
| p95 response time drifting | SRE/Business Dashboard | Latency degradation |

### 3. Fault injection — Problem Patterns UI

Open `http://<instance-ip>:8079/` (no auth required) to manually enable EasyTravel problem patterns:

- **LoginProblems** — high login error rate
- **SlowTransaction** — artificial response time degradation
- **CPULoad** — CPU spike simulation
- **DatabaseSlowdown** — DB call latency injection

Each pattern triggers a Davis AI problem within ~2 minutes.

---

## Dashboards

Two dashboards ship with this repo (Dynatrace Grail v21 format, DQL queries):

| Dashboard | Audience | Tiles |
|-----------|----------|-------|
| **Business Overview** | Management / stakeholders | Throughput, error rate, p50/p95 response time, CPU, SLO status |
| **SRE Operations** | Platform / SRE team | RED signals, p50/p95/p99, host CPU/memory, JVM heap, GC suspension, DB call duration |

### Manual upload (required on Grail/Platform tenants)

1. Go to `https://<env-id>.apps.dynatrace.com/ui/apps/dynatrace.dashboards`
2. Click **Upload**
3. Upload `dynatrace/dashboards/business_dashboard.json`
4. Upload `dynatrace/dashboards/sre_dashboard.json`

---

## Manual Steps

Some Dynatrace Grail/Platform features require OAuth2 and cannot be automated via API token:

### SLOs

Create these three SLOs manually at `https://<env-id>.live.dynatrace.com/ui/slo` — definitions are in `dynatrace/slos/platform_slos.json`:

| SLO | Target | Window |
|-----|--------|--------|
| API Availability | 99.5% | 7 days |
| Latency p95 < 2s | 99.0% | 1 day |
| Infrastructure Availability | 99.9% | 7 days |

### Dashboards

See [Dashboards](#dashboards) section above.

---

## Project Structure

```
dt-observability-demo/
├── Makefile                        # Single entrypoint for all operations
├── .env.example                    # Environment variable template
├── terraform/                      # AWS infrastructure
│   ├── main.tf                     # Provider, backend (S3 + DynamoDB)
│   ├── vpc.tf                      # VPC, subnet, internet gateway
│   ├── sg.tf                       # Security group (SSH, HTTP, app ports)
│   ├── ec2.tf                      # EC2 instance + key pair
│   ├── iam.tf                      # IAM role for SSM / CloudWatch
│   ├── outputs.tf                  # Instance IP, SSH command
│   ├── variables.tf
│   └── terraform.tfvars.example
├── ansible/                        # Instance provisioning
│   ├── playbooks/
│   │   ├── site.yml                # Main playbook (common → docker → easytravel → dynatrace)
│   │   └── teardown.yml
│   ├── roles/
│   │   ├── common/                 # OS hardening, sysctl tuning
│   │   ├── docker/                 # Docker CE + compose plugin
│   │   ├── easytravel/             # EasyTravel via Docker Compose + systemd
│   │   └── dynatrace_agent/        # OneAgent installer
│   ├── inventory/
│   │   ├── aws_ec2.yml             # Dynamic inventory (EC2 tag filter)
│   │   └── hosts.ini               # Static fallback
│   └── vault/
│       └── secrets.yml.example
├── k6/
│   ├── scenarios/
│   │   ├── baseline.js             # 20 VUs, 5 min
│   │   ├── spike.js                # Ramp to 150 VUs
│   │   ├── stress.js               # Ramp to 200 VUs
│   │   └── soak.js                 # 30 VUs, 30 min (DURATION env override)
│   └── results/                    # k6 JSON summaries (gitignored)
├── dynatrace/
│   ├── deploy.sh                   # Pushes all configs via Dynatrace API
│   ├── dashboards/
│   │   ├── business_dashboard.json # Business overview (Grail v21)
│   │   └── sre_dashboard.json      # SRE golden signals (Grail v21)
│   ├── slos/
│   │   └── platform_slos.json      # Three platform SLO definitions
│   ├── alerts/                     # Classic metric event alerts (reference)
│   └── management_zones/           # MZ scoping all demo resources
└── scripts/
    ├── bootstrap.sh                # Create S3 + DynamoDB state backend
    ├── up.sh                       # terraform apply + ansible + dashboards
    └── down.sh                     # Ansible teardown + terraform destroy
```

---

## App Credentials

**Booking portal** (`http://<ip>/` or `http://<ip>:8080/`):

Username and password are the same string. Any of these work:
- `hainer` / `hainer`
- `alex` / `alex`
- `monica` / `monica`

**Problem Patterns Admin UI** (`http://<ip>:8079/`): no authentication.

---

## Teardown

```bash
make down
```

Runs Ansible teardown playbook then `terraform destroy`. Removes the EC2 instance, VPC, key pair, and security group. The S3/DynamoDB state backend is **not** destroyed (intentional — preserves state history).

To also remove the state backend:
```bash
aws s3 rb s3://dt-demo-tfstate --force --profile dt
aws dynamodb delete-table --table-name dt-demo-tfstate-lock --region ap-southeast-2 --profile dt
```
