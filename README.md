# Platform Engineer — Technical Assignment

## Scenario

An internal web platform used by multiple teams, built with **Django** and
**PostgreSQL**, deployed on **AWS** using **EC2**, **Nginx**, and **Gunicorn**.
This repository contains the full solution: deployment approach, CI/CD
pipeline, incident-response runbook, security review, a health-check
endpoint, and the AWS architecture design.

## Assumptions

- **Stack:** Django (Python 3.12) + Gunicorn + Nginx + PostgreSQL, on Ubuntu
  24.04. (Node.js/PM2 equivalents are noted inline where they differ.)
- **Compute:** an Auto Scaling Group of EC2 instances built from a **custom
  AMI** (packages, users, and systemd units pre-baked; app code and secrets
  pulled in at boot), sitting behind an **Application Load Balancer** that
  terminates TLS with an ACM certificate — so Nginx on each instance only
  needs to speak plain HTTP.
- **Secrets:** stored in **AWS Secrets Manager** as a single JSON secret per
  environment, fetched onto the instance by a script baked into the AMI.
  Rotation is handled manually via SSM Session Manager for this submission
  (see Part 1).
- **Access:** no SSH anywhere in this design. All instance access — for
  deploys, debugging, and manual secret rotation — goes through **AWS
  Systems Manager Session Manager / Run Command**.
- **CI/CD:** **Jenkins**, triggered on merge to `main`, deploying via SSM
  Run Command to instances discovered dynamically from the ASG.
- **Migrations** follow an expand/contract pattern (backward-compatible),
  so a symlink-based rollback never leaves the previous release running
  against an incompatible schema.
- **Project package** is assumed to be named `config` (i.e. the WSGI entry
  point is `config.wsgi:application`).

None of the domains, account IDs, bucket names, or ARNs in this repository
are real — replace them before using anything here against an actual AWS
account. No real credentials are included anywhere.

## Where to start

| Part | What it covers | Link |
|---|---|---|
| 1 | Deployment approach — server setup, directory structure, environment variables (Secrets Manager), Nginx/Gunicorn config, custom AMI, rollback | [`part1-deployment/`](./part1-deployment-approach/README.md) |
| 2 | CI/CD pipeline — Jenkins, rolling deploy via SSM, migrations, health checks, automatic rollback | [`part2-cicd/`](./part2-CI-CD/README.md) |
| 3 | Production incident investigation — what a 502 means, where it's generated in this architecture, debug commands, resolution | [`part3-incident-investigation/`](./part3-production-incident-investigation/README.md) |
| 4 | Security review — risks identified against this specific design and how each is handled, plus a discussion of containers/ECR + Ansible as a future iteration | [`part4-security-review/`](./part4-security-review/README.md) |
| 5 | Small code change — `/healthz` and `/readyz` endpoints (Django), with tests | [`part5-healthcheck/`](./part5-code-changes/README.md) |
| 6 | AWS architecture — VPC, subnets, ALB, ASG, RDS, IAM, monitoring, backups | [`part6-aws-architecture/`](./part6-aws-architecture/README.md) |

## How the parts connect

The six parts aren't independent write-ups — they describe one consistent
system:

- The **architecture** (Part 6) defines the VPC/ALB/ASG/RDS layout that
  everything else assumes.
- The **deployment approach** (Part 1) is what actually runs on each
  instance in that ASG — including the AMI, the scripts, and how secrets
  and TLS are handled given that layout.
- The **CI/CD pipeline** (Part 2) is Jenkins driving those same
  `deploy.sh`/`rollback.sh` scripts remotely, instance by instance, over
  SSM.
- The **incident runbook** (Part 3) is written against this exact
  ALB → Nginx → Gunicorn chain, not a generic 502 checklist.
- The **security review** (Part 4) walks the same components built in
  Parts 1, 2, and 6, and cross-references where each fix already lives.
- The **health-check endpoint** (Part 5) is the mechanism Parts 1, 2, and 6
  all rely on to decide whether a release, a rollback, or a running
  instance is actually healthy.