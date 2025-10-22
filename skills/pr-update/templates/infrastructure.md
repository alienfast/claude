# Infrastructure PR Template

Use this template for infrastructure changes, deployments, and cloud resources.

```markdown
## Summary

[1-2 sentence overview: What infrastructure is being deployed/changed and why]

## Infrastructure Overview

### [Resource Type - e.g., Database, CDN, Kubernetes]

**Configuration**:

- Resource type: [e.g., Cloud SQL, S3, EKS]
- Tier/Size: [e.g., Enterprise Plus, Standard, 3 nodes]
- Region: [e.g., us-central1, us-east-1]
- Availability: [e.g., Multi-zone, Regional, Global]

**Key Features**:

- [Feature 1 with benefit]
- [Feature 2 with benefit]
- [Feature 3 with benefit]

**Implementation**:

- Infrastructure code: [link to terraform/pulumi](cloud/resource/src/main.ts)
- Configuration: [link to config](cloud/resource/config.yaml)
- Stack commands: [link to stack file](cloud/resource/stack)

## Architecture

### Components

```

┌─────────────────┐
│   Load Balancer │
└────────┬────────┘
         │
    ┌────▼─────────────────┐
    │   Application Layer  │
    │  (Auto-scaling 2-10) │
    └────┬─────────────────┘
         │
    ┌────▼──────────┐
    │   Database    │
    │ (Primary + DR)│
    └───────────────┘

```

### Resource Relationships

- [Resource A] → [Resource B]: [How they interact]
- [Resource B] → [Resource C]: [Data flow]

### Networking

- VPC: [Name/ID]
- Subnets: [List]
- Firewall rules: [Summary or link]
- DNS: [Configuration]

## Deployment

### Prerequisites

- [ ] [Required API enabled]
- [ ] [Required permissions set]
- [ ] [Required secrets configured]
- [ ] [Dependent resources created]

### Deployment Steps

```bash
# 1. Initialize infrastructure
./stack init

# 2. Plan changes
./stack plan

# 3. Apply infrastructure
./stack deploy

# 4. Verify deployment
./stack verify
```

### Stack Commands

All infrastructure management commands:

- `./stack init` - Initialize infrastructure stack
- `./stack plan` - Preview infrastructure changes
- `./stack deploy` - Deploy infrastructure changes
- `./stack destroy` - Tear down infrastructure
- `./stack verify` - Run connectivity and health checks
- `./stack logs` - View infrastructure logs
- `./stack backup` - Create backup/snapshot
- `./stack restore` - Restore from backup

## Configuration

### Resource Configuration

**[Resource Name]**:

```yaml
resource:
  name: production-db
  tier: ENTERPRISE_PLUS
  edition: ENTERPRISE
  settings:
    backup:
      enabled: true
      start_time: "03:00"
      retention_days: 30
    maintenance:
      day: SUNDAY
      hour: 4
```

### Environment Variables

- `RESOURCE_ENDPOINT` - [Description]
- `RESOURCE_CREDENTIALS` - [How to obtain]
- `RESOURCE_OPTIONS` - [Configuration options]

### Secrets Management

- [Secret name]: Stored in [Secret Manager/Vault]
- [Access pattern]: [How application accesses]

## High Availability & Disaster Recovery

### Backup Strategy

- **Frequency**: [e.g., Daily at 3 AM UTC]
- **Retention**: [e.g., 30 days for daily, 12 months for monthly]
- **Storage**: [e.g., Regional, Cross-region]
- **Recovery Time Objective (RTO)**: [e.g., < 1 hour]
- **Recovery Point Objective (RPO)**: [e.g., < 15 minutes]

### Disaster Recovery

- **DR Replica**: [Configuration details]
- **Failover Process**: [Automatic/Manual steps]
- **Failback Process**: [Steps to return to primary]

### Monitoring & Alerts

- [Metric 1]: Alert if [threshold]
- [Metric 2]: Alert if [threshold]
- [Health check]: Every [interval]

## Security

### Access Control

- **Admin Access**: [Who/how]
- **Application Access**: [Service account/credentials]
- **Audit Logging**: [Where logs go]

### Network Security

- [Firewall rules summary]
- [Encryption in transit]
- [Encryption at rest]

### Compliance

- [Relevant compliance standards]
- [Data residency requirements]
- [Audit requirements]

## Cost Impact

### Production Environment

**Base Infrastructure**:

- Compute: $X/month
- Storage: $Y/month
- Network: $Z/month
- **Total**: $W/month

**Scaling Costs**:

- Additional compute (per instance): +$A/month
- Additional storage (per 100GB): +$B/month

**Optimization Opportunities**:

- [Potential savings with committed use discounts]
- [Autoscaling configuration to minimize idle costs]

### Non-Production Environments

**Staging**:

- $X/month (shared infrastructure)
- Scales down to $Y/month when idle

**Development**:

- $Z/month (minimal resources)

## Performance

### Benchmarks

- Throughput: [X requests/second]
- Latency: [Yms p95, Zms p99]
- Concurrency: [N concurrent connections]

### Scaling Limits

- Max throughput: [X requests/second]
- Max storage: [Y TB]
- Max connections: [Z]

## Testing

**Infrastructure Tests**:

- ✅ Deployment succeeds in clean environment
- ✅ All stack commands execute successfully
- ✅ Health checks pass
- ✅ Connectivity verified from application layer
- ✅ Backup/restore tested

**Security Tests**:

- ✅ Unauthorized access blocked
- ✅ Encryption verified
- ✅ Firewall rules tested

**Performance Tests**:

- ✅ Load testing at expected peak
- ✅ Failover tested (DR scenario)
- ✅ Auto-scaling verified

## Documentation

- [Architecture diagram](doc/architecture.md)
- [Runbook](doc/runbook.md)
- [Disaster recovery procedures](doc/dr-procedures.md)
- [Cost analysis](doc/cost-analysis.md)
- [Stack command reference](cloud/resource/README.md)

## Migration Plan

[If applicable - migrating from old infrastructure]

### Migration Steps

1. [Step 1]
2. [Step 2]
3. [Step 3]

### Rollback Plan

1. [How to revert if issues occur]
2. [Data migration rollback]
3. [DNS/traffic routing rollback]

### Downtime Window

- Required: [Yes/No]
- Duration: [X minutes]
- Scheduled: [Date/time]

## Dependencies

- Updated `infrastructure-package` to x.y.z
- Added `cloud-provider-sdk` for [specific feature]

---

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>

```
