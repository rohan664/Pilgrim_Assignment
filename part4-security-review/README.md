# Part 4: Security Review

## Approach

Each risk below was identified by walking through the actual deployment we
designed in Parts 1, 2, and 6 — VPC with public/private subnets, ASG of EC2
instances behind an ALB, RDS PostgreSQL, Jenkins for CI/CD, Secrets Manager for
config — and asking, at every hop, **"what happens if this specific piece is
compromised, misconfigured, or simply left at its default?"** That's a
different exercise than listing generic OWASP items: each row below maps to a
concrete component we already built, not a hypothetical one.

For each risk: what it is, why it matters in *this* setup specifically, and
the fix — most of which are already reflected in Parts 1, 2, and 6, so this
section also serves as a cross-reference of where each protection actually
lives.

## Risks identified and how they're handled

| # | Risk | Why it matters here | Fix (and where it's implemented) |
|---|---|---|---|
| 1 | **Secrets in source code / `.env` committed to git** | A leaked repo or a careless commit would expose the DB password and Django `SECRET_KEY` | All secrets live in **AWS Secrets Manager**, fetched onto the instance at boot/rotation via `fetch-env.sh` (Part 1). `.env` is `chmod 600`, owned by `app`, and `.gitignore`'d — it never exists in git at all. Add `gitleaks` or GitHub secret scanning as a pre-commit/CI safety net. |
| 2 | **Overly permissive IAM** | A compromised Jenkins box or EC2 instance with `AdministratorAccess` means a full account takeover, not just an app breach | Every role in this design is scoped to exactly what it needs: the EC2 instance role only reads its one Secrets Manager secret and writes to specific S3 prefixes; the Jenkins deploy role only does `s3:PutObject` on `releases/*` and `ssm:SendCommand` on tagged instances (Part 2). No shared keys, no wildcard `Resource: "*"` except where AWS requires it (e.g. `DescribeTargetHealth`). |
| 3 | **Publicly exposed PostgreSQL** | An internet-facing database is scanned and attacked within minutes of exposure | RDS sits in **private DB subnets** with `PubliclyAccessible=false` (Part 6). `db-sg` only allows port 5432 from `app-sg` — not from the internet, not even from the public subnets. |
| 4 | **Open security group ports, especially SSH** | Port 22 open to `0.0.0.0/0` is one of the most commonly exploited misconfigurations on AWS | No security group in this design allows inbound 22 at all. All instance access goes through **SSM Session Manager** instead (Part 1, Part 3) — no bastion host, no SSH key to leak, every session logged in CloudTrail. `app-sg` only accepts port 80 from `alb-sg`; `alb-sg` only accepts 443/80 from the internet. |
| 5 | **Missing or weak SSL/TLS** | Credentials and session cookies can be intercepted over plain HTTP | HTTPS is terminated at the **ALB with an ACM certificate**, which auto-renews (Part 1). The ALB redirects HTTP → HTTPS at the edge, so plaintext never reaches the VPC. |
| 6 | **`DEBUG=True` in production** | Leaks stack traces, installed apps, settings, and sometimes SQL queries to any visitor who triggers an error | `DEBUG=False` is set via the Secrets-Manager-sourced `.env` in production, with `ALLOWED_HOSTS` restricted to `app.example.com`. `python manage.py check --deploy` should run as part of the Jenkins **Test** stage (Part 2) to catch this and similar misconfigurations before a deploy ships. |
| 7 | **Outdated / vulnerable dependencies** | Most real-world breaches exploit a known CVE in a dependency, not a novel attack | `pip-audit` runs against `requirements.txt` in the Jenkins **Test** stage (Part 2) and fails the build on known vulnerabilities. OS packages are kept current via `unattended-upgrades`, baked into the AMI (Part 1). |
| 8 | **Weak Linux permissions** | Running the app as root, or a world-readable `.env`, turns any app-level bug into a full host compromise | The app runs as the unprivileged, `nologin` **`app`** user (Part 1), never root. `.env` is `600`. The systemd unit adds `NoNewPrivileges=true` and `ProtectSystem=full` for extra containment. |
| 9 | **No backups / untested restore** | Without a tested restore path, a bad migration or accidental deletion is unrecoverable | RDS automated backups with **PITR**, plus an AWS Backup plan with cross-region copy (Part 6). A quarterly restore drill should be scheduled — noted as an operational task, not just a checkbox. |
| 10 | **No monitoring or alerts** | Without alarms, outages are discovered by users complaining, not by the team | CloudWatch Agent ships Nginx/app/system logs and metrics; alarms on 5xx rate, unhealthy targets, CPU/memory/disk, and RDS connections/storage publish to an **SNS topic** feeding Slack/PagerDuty (Part 6). |
| 11 | **Unsafe deployment access** | A shared SSH key or manual root logins to "just fix something quickly" leave no audit trail and invite drift between instances | All deploys go through the **Jenkins pipeline only**, using SSM Send-Command with a scoped IAM role — no long-lived credentials, every command logged (Part 2). The one manual exception (secret rotation, Part 1) is also done via SSM Session Manager, never SSH, and is itself logged. |
| 12 | **Lack of audit logs** | Without a record of who did what and when, incident investigation and compliance are both impossible | **CloudTrail** captures every IAM/API action (including every SSM command run and by which role); ALB access logs go to S3; VPC Flow Logs can be enabled for network-level visibility. |

---

## Alternative approach worth considering: containers (ECR) + Ansible

Everything above was written against the design actually implemented in this
submission — an AMI-based EC2 fleet with hand-written shell scripts
(`deploy.sh`/`rollback.sh`) doing the release-directory/symlink dance. That's a
reasonable, low-dependency choice for a small internal platform, but it's
worth being explicit that it isn't the only valid one. Two changes would move
this toward a more standard, more auditable setup at the cost of added
complexity:

### 1. Container runtime + ECR instead of a release-directory layout

Instead of `git archive` → S3 → `deploy.sh` unpacking a tarball into
`/opt/app/releases/<sha>`, the app would be built into a **Docker image**,
pushed to **Amazon ECR**, and each EC2 instance (or a move to ECS/Fargate
entirely) would simply pull and run that exact image.

**Security benefits this brings:**
- **Immutability is enforced by the platform, not by convention.** A container
  image can't be modified in place the way a release directory theoretically
  could be if someone got shell access — the image is content-addressed by
  digest.
- **ECR image scanning** runs automatically on push, giving CVE detection on
  the OS layer and dependencies in addition to `pip-audit` on just the Python
  packages.
- **Smaller attack surface per instance.** The EC2 host only needs Docker (or
  containerd) and the SSM Agent — no Python, no `venv`, no app source code
  sitting on disk outside the running container.
- **Consistent artifact from build to prod.** The exact same image is what ran
  in the Test stage, removing "works in CI, breaks in prod because of a
  slightly different `pip install`" class of issues.

This would replace `deploy.sh`'s tarball/venv logic with something like
`docker pull <ecr-repo>:<sha> && docker run ...` (or a `docker-compose`/systemd
unit wrapping it), and Jenkins's **Build artifact** and **Upload to S3** stages
(Part 2) would become **Build image** and **Push to ECR** stages instead.

### 2. Ansible instead of Packer + hand-maintained shell provisioning

Part 1's AMI is currently built with a single `provision.sh` shell script run
by Packer. That works, but it isn't idempotent, isn't easily testable in
isolation, and doesn't scale well as the number of managed settings grows.
Replacing `provision.sh` with an **Ansible playbook** (still triggered by
Packer, or run directly via SSM if managing already-running instances)
would give:

- **Idempotent, declarative configuration** — re-running the playbook against
  a drifted instance brings it back to the defined state, rather than a shell
  script that only works correctly on a pristine image.
- **Easier security review** — Ansible roles for things like SSH hardening,
  user/permission setup, and package versions are well-established
  community patterns that are easier to audit than bespoke bash.
- **Reusable across environments** — the same playbook (with different
  variables) can configure staging and production identically, reducing the
  "it was only ever tested on the AMI I built by hand" risk.