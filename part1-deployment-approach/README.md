# Part 1: Deployment Approach

Django app deployed on EC2 instances that are part of an Auto Scaling Group (ASG) behind an ALB, using a custom-built AMI.

---

## 1. Server setup and package installation

```bash
sudo apt update && sudo apt -y upgrade
sudo apt -y install nginx python3-venv python3-dev build-essential libpq-dev \
                    postgresql-client unzip curl jq
                    

# Dedicated, unprivileged application user — the app never runs as root
sudo useradd --system --create-home --shell /usr/sbin/nologin app
sudo usermod -aG app www-data     # lets Nginx read static files owned by group 'app'

```

> With an ASG, these steps run **once, at AMI build time** (via Packer), not on every instance boot. See [Custom AMI](#custom-ami-for-the-auto-scaling-group).

## 2. Application directory structure

Release-based layout, so every deploy is isolated and rollback is just a symlink switch:

```
/opt/app/
├── bin/                # deploy.sh, rollback.sh
├── current -> releases/20260924103015     # symlink to the live release
├── releases/
│   ├── 20260924103015/    # code + venv for this release
│   └── ...                # keep last 5
└── shared/
    ├── .env              # secrets, chmod 600, owner app
    ├── static/           # collectstatic output, served by Nginx
    └── media/            # uploads (or offload to S3, per Part 6)
```

```bash
sudo mkdir -p /opt/app/{bin,releases,shared/{static,media}}
sudo chown -R app:app /opt/app
sudo chmod 750 /opt/app/shared
```

## 3. Environment variable management

Secrets live in AWS Secrets Manager, not in git. All application config is stored as a single JSON secret and fetched onto the instance at boot time (not baked into the AMI), so the same AMI works across staging and production.

### Secret structure
 
```
Secret name: prod/app/env
Secret value (JSON):
{
  "SECRET_KEY": "django-insecure-example-not-real",
  "DATABASE_URL": "postgres://appuser:examplepass@mydb.xxxx.us-east-1.rds.amazonaws.com:5432/appdb?sslmode=require",
  "DEBUG": "False",
  "ALLOWED_HOSTS": "app.example.com"
}
```
 
### IAM permissions
 
The EC2 instance role is scoped to only this one secret (and its KMS key, if a customer-managed key is used):
 
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:us-east-1:123456789012:secret:prod/app/env-*"
    }
  ]
}
```
 
### Fetch script (baked into the AMI)
 
Rather than fetching secrets inline in user-data, the fetch logic lives in its own script baked into the AMI at build time. This makes it reusable (boot time and manual rotation both call the same script) and easy to run by hand for troubleshooting.
 
`/opt/app/bin/fetch-env.sh`:
 
```bash
#!/usr/bin/env bash
set -euo pipefail
SECRET_ID="prod/app/env"
ENV_FILE="/opt/app/shared/.env"
 
aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ID" \
  --query SecretString \
  --output text \
| jq -r 'to_entries[] | "\(.key)=\(.value)"' > "$ENV_FILE"
 
chmod 600 "$ENV_FILE"
chown app:app "$ENV_FILE"
echo "Fetched secrets from $SECRET_ID -> $ENV_FILE"
```
 
`jq` is installed at AMI build time alongside the other packages (`sudo apt install -y jq`).
 
### Boot-time fetch (user-data)
 
User-data stays short and just calls the script, then deploys the latest release:
 
```bash
#!/bin/bash
/opt/app/bin/fetch-env.sh
/opt/app/bin/deploy.sh "$(aws ssm get-parameter --name /prod/app/latest_artifact --query 'Parameter.Value' --output text)"
```
 
### Rotation
 
User-data only runs once, at first boot, so it will not pick up a secret that is rotated later on an already-running instance. For this setup, secret rotation is handled **manually**: when a secret is rotated in Secrets Manager, a developer connects to the instance through **AWS Systems Manager Session Manager** (no SSH, no open port 22) and re-runs the fetch script directly:
 
```bash
# From the developer's machine, using the AWS CLI + Session Manager plugin
aws ssm start-session --target <instance-id>
 
# Once connected, on the instance:
sudo /opt/app/bin/fetch-env.sh
sudo systemctl restart app-gunicorn
```
 
This is deliberately manual and low-automation for now, since Session Manager already gives a fully audited (no SSH key, every command logged in CloudTrail) way to reach the instance without exposing it.

## 4. Dependency installation

Per-release virtualenv, pinned requirements — so rolling back also restores the exact old dependency set:

```bash
cd /opt/app/releases/<new-release>
python3 -m venv venv
./venv/bin/pip install --no-cache-dir --upgrade pip
./venv/bin/pip install --no-cache-dir -r requirements.txt
```

## 5. Application server configuration (Gunicorn + systemd)

`/etc/systemd/system/app-gunicorn.service`:

```ini
[Unit]
Description=App Gunicorn
After=network.target

[Service]
User=app
Group=www-data
WorkingDirectory=/opt/app/current
EnvironmentFile=/opt/app/shared/.env
RuntimeDirectory=app
ExecStart=/opt/app/current/venv/bin/gunicorn config.wsgi:application \
          --bind unix:/run/app/gunicorn.sock --umask 007 \
          --workers 3 --timeout 30 --access-logfile - --error-logfile -
ExecReload=/bin/kill -s HUP $MAINPID
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now app-gunicorn
```

> The unit file itself is installed at AMI build time; it is only **started** at boot time, after user-data has pulled the app code and written `.env`.

## 6. Nginx configuration

The ALB terminates HTTPS using an ACM certificate (see [Part 6: AWS Architecture](../part6-aws-architecture/README.md)), so traffic between the ALB and the EC2 instances is plain HTTP within the VPC. Nginx on the instance only needs an HTTP listener — there is no certificate, key, or 443 block to manage here.

```nginx
upstream app_server {
    server unix:/run/app/gunicorn.sock fail_timeout=0;
}
 
server {
    listen 80;
    server_name app.example.com;
 
    # Trust the ALB's X-Forwarded-* headers so Django/the app knows the
    # original client IP and that the original request was HTTPS
    set_real_ip_from 10.0.0.0/16;   # VPC CIDR
    real_ip_header X-Forwarded-For;
 
    server_tokens off;
    client_max_body_size 10m;
 
    location /static/ {
        alias /opt/app/shared/static/;
        expires 30d;
    }
 
    location / {
        proxy_pass http://app_server;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
 
    access_log /var/log/nginx/app.access.log;
    error_log  /var/log/nginx/app.error.log warn;
}
```

```bash
sudo nginx -t && sudo systemctl reload nginx
```

## 7. SSL certificate setup
 
SSL is handled entirely at the ALB, not on the EC2 instances:
 
- An **ACM (AWS Certificate Manager)** certificate is requested for `app.example.com`, validated via a DNS record in Route 53.
- The certificate is attached to the ALB's HTTPS (443) listener.
- ACM certificates **auto-renew** — there is no Certbot, cron job, or renewal timer to manage on the instances.
- The ALB listener redirects HTTP (80) requests from the internet to HTTPS (443), so plaintext traffic never reaches the VPC.

## 8. Application startup and restart process

```bash
sudo systemctl enable nginx app-gunicorn     # start on boot
sudo systemctl restart app-gunicorn          # hard restart (code/config change)
sudo systemctl reload  app-gunicorn          # graceful reload
sudo systemctl reload  nginx                 # after Nginx config change (nginx -t first)
```

## 9. Log locations

| Component | Location |
|---|---|
| Nginx access/error | `/var/log/nginx/app.access.log`, `/var/log/nginx/app.error.log` |
| App/Gunicorn | `journalctl -u app-gunicorn` |
| System/OOM | `journalctl -k`, `/var/log/syslog` |
| Centralized copy | CloudWatch Agent ships all of the above to CloudWatch Logs |

## 10. Deployment rollback approach

Since each release is immutable and `current` is just a symlink, rollback is: point the symlink at the previous release and restart.

```bash
#!/usr/bin/env bash
# /opt/app/bin/rollback.sh
set -euo pipefail
BASE=/opt/app
CUR=$(readlink -f "$BASE/current")
PREV=$(ls -1dt "$BASE"/releases/* | grep -v "^$CUR$" | head -1)
[ -n "$PREV" ] || { echo "No previous release found"; exit 1; }
ln -sfn "$PREV" "$BASE/current.tmp" && mv -Tf "$BASE/current.tmp" "$BASE/current"
systemctl restart app-gunicorn
sleep 3
curl -fsS https://app.example.com/healthz && echo " rollback OK"
```

Database migrations follow an **expand/contract** pattern (add nullable columns first, drop old ones only in a later release) so the previous release can still run against the new schema — that's what makes a fast symlink rollback safe without also having to reverse a migration under pressure.

---

## Custom AMI for the Auto Scaling Group

The architecture in Part 6 uses an ASG, which means new instances can launch at any time — during a scale-out event, a health-check replacement, or a rolling instance refresh. A plain base Ubuntu AMI with a boot-time install script would work, but it has real drawbacks in this context:

| | Config on boot (plain AMI + user-data) | Custom/golden AMI |
|---|---|---|
| Boot time | Slow — full package install runs on every launch | Fast — instance is ready almost immediately |
| Consistency | Risk of drift if a package mirror serves a different version between launches | Every instance in the ASG is identical |
| Scaling events | A scale-out during high load is slowed down by installing packages right when capacity is needed fastest | New instance becomes healthy in seconds — ideal under load |
| Failure mode | An upstream package/mirror outage can break new instance launches entirely | No dependency on package mirrors at launch time |

Given the ASG needs to react to load and self-heal quickly, a **custom AMI with the base software pre-installed** is the better fit. This changes *when* the steps above run, not *what* they contain.

### What's baked into the AMI (build time, once per base-image release)

- OS packages: Nginx, Python/venv tooling (or Node.js + PM2), Certbot, CloudWatch Agent, SSM Agent
- The `app` system user and the `/opt/app` directory structure
- The systemd unit file (`app-gunicorn.service`), installed but not started
- Static OS-level hardening: `unattended-upgrades` config, sysctl tuning

### What happens at boot time (every instance launch, via user-data)

- Fetch `.env` from AWS Secrets Manager (kept out of the AMI so the same image works for staging and production)
- Pull the latest application release artifact from S3 into `/opt/app/releases/<sha>`
- Switch the `current` symlink to the new release and `systemctl start app-gunicorn`
- Register with the ALB target group automatically, via the ASG's health check

### Building the AMI with Packer

```hcl
# app-ami.pkr.hcl
source "amazon-ebs" "app" {
  ami_name      = "internal-app-{{timestamp}}"
  instance_type = "t3.small"
  region        = "us-east-1"
  source_ami_filter {
    filters = {
      name                = "ubuntu/images/*ubuntu-noble-24.04-amd64-server-*"
      virtualization-type = "hvm"
    }
    owners      = ["099720109477"]  # Canonical
    most_recent = true
  }
  ssh_username = "ubuntu"
}

build {
  sources = ["source.amazon-ebs.app"]

  provisioner "shell" {
    script = "provision.sh"   # runs steps 1, 2 and 5 above once, at build time
  }
}
```

### Launch template user-data (boot-time only)

```bash
#!/bin/bash
# Fetch environment-specific config
aws ssm get-parameters-by-path --path /prod/app/ --with-decryption \
  --query 'Parameters[*].[Name,Value]' --output text \
  | awk -F'\t' '{n=$1; sub(".*/","",n); printf "%s=%s\n", n, $2}' > /opt/app/shared/.env
chmod 600 /opt/app/shared/.env && chown app:app /opt/app/shared/.env

# Pull latest released artifact and activate it
/opt/app/bin/deploy.sh "$(aws ssm get-parameter --name /prod/app/latest_artifact --query 'Parameter.Value' --output text)"
```