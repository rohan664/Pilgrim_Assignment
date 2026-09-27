# Part 2: CI/CD Pipeline

CI/CD is implemented with **Jenkins**:
the app runs on an Auto Scaling Group built from a custom AMI (Part 1), all instance
access happens through **AWS Systems Manager** (no SSH, no open port 22), and
environment configuration is fetched from **AWS Secrets Manager** on the instance
itself — Jenkins never handles application secrets.

## Pipeline design

```
Push/merge to main
  ↓
1. Checkout code
2. Run tests (unit tests + migration dry-run)
3. Build artifact (tarball of the app, versioned by commit SHA)
4. Upload artifact to S3
5. Discover target instances (all healthy instances currently in the ASG)
6. Deploy via SSM — run deploy.sh on every instance, one at a time
7. Run DB migrations (as part of the first instance's deploy.sh run)
8. Health check each instance through the ALB target group before moving on
9. Public health check against the app URL
10. If any step fails → rollback.sh on the affected instances, fail the build
```

**Why SSM and not SSH:** matches Part 1 — the instances have no open port 22.
Jenkins reaches them through **SSM Run Command**, using an IAM role scoped to only
this task.

**Why discover instances dynamically:** with an ASG, the instance set changes over
time (scale-in/out, unhealthy instance replacement), so the pipeline cannot
hardcode instance IDs — it asks the ASG for its current `InService` members at
deploy time.

**Why one instance at a time:** each instance is deployed and confirmed
`healthy` in the ALB target group before the next one starts, so a bad release
only ever takes one instance out of rotation at a time rather than the whole
fleet at once.

## IAM role for Jenkins (deploy role)

Attached to the Jenkins EC2 instance's own instance role — no long-lived AWS
access keys stored in Jenkins credentials.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::example-app-artifacts/releases/*"
    },
    {
      "Effect": "Allow",
      "Action": ["autoscaling:DescribeAutoScalingGroups"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["ssm:SendCommand", "ssm:GetCommandInvocation", "ssm:ListCommandInvocations"],
      "Resource": [
        "arn:aws:ssm:us-east-1::document/AWS-RunShellScript",
        "arn:aws:ec2:us-east-1:123456789012:instance/*"
      ],
      "Condition": {
        "StringEquals": { "ssm:resourceTag/App": "internal-platform" }
      }
    },
    {
      "Effect": "Allow",
      "Action": ["elasticloadbalancing:DescribeTargetHealth"],
      "Resource": "*"
    }
  ]
}
```

## Pipeline stages

The full pipeline definition lives in [`Jenkinsfile`](./Jenkinsfile). Summary of
each stage:

| Stage | What it does |
|---|---|
| Checkout | Pulls the merged `main` branch, captures the commit SHA |
| Test | Installs dependencies, runs `pip-audit`, checks for missing migrations, runs `pytest` |
| Build artifact | Packages the repo into `app-<sha>.tar.gz` |
| Upload to S3 | Uploads the artifact to the versioned `releases/` prefix |
| Discover instances | Queries the ASG for currently `InService` instance IDs |
| Deploy (rolling) | Runs `/opt/app/bin/deploy.sh <artifact>` via SSM on each instance, one at a time, waiting for target-group health before moving to the next |
| Public health check | Confirms `/readyz` responds correctly through the ALB from outside |
| Rollback (on failure) | Runs `/opt/app/bin/rollback.sh` via SSM on every instance targeted in that run |

`deploy.sh` and `rollback.sh` are present in current folder — they already
handle fetching the release, installing dependencies, running migrations,
switching the `current` symlink, restarting Gunicorn, and self-verifying health
on the instance before Jenkins even checks the target group.

## Migrations across multiple instances

Since all instances share the same RDS database, migrations only need to run
**once** per deploy, not once per instance. `deploy.sh` runs `manage migrate` as
part of activating a release; to avoid running it five times in a five-instance
ASG, `deploy.sh` should be extended with a simple guard — for example, a
`--skip-migrate` flag passed to every instance after the first in the rolling
loop.

## Trigger

The pipeline triggers via a GitHub webhook (`githubPush()`) pointed at `http://jenkins.internal/github-webhook/`, using the GitHub plugin.

## Rollback

If the deploy or health-check stage fails, the `post { failure { ... } }` block
sends `/opt/app/bin/rollback.sh` via SSM to every instance that was targeted in
that pipeline run. `rollback.sh` switches the `current` symlink back to the
previous release and restarts Gunicorn — the same rollback mechanism described
in Part 1, just triggered automatically by the pipeline instead of by hand.