# Launch cost assumptions

**Checked 14 September 2026.** USD list prices for `eu-west-1`, 730 hours/month, Linux shared-tenancy On-Demand EC2 and EKS standard support. This estimates the [architecture](README.md#launch-cost-estimate), not the smaller Terraform POC.

Production has three system nodes, three application nodes, three NAT gateways, one internal ALB and a Multi-AZ database. Non-production has two system nodes, one application node, one NAT, one internal ALB and a Single-AZ database. The application instance types are budgeting examples; Karpenter can select other eligible types and scale with demand.

| Resource | Calculation | Monthly USD |
| --- | --- | ---: |
| EKS control planes | 2 × 730 h × $0.10/h | $146.00 |
| `m7g.large` system nodes | 5 × 730 h × $0.091/h | $332.15 |
| `c7g.large` application nodes | 4 × 730 h × $0.0775/h | $226.30 |
| Production PostgreSQL `db.t4g.medium`, Multi-AZ | 730 h × $0.138/h | $100.74 |
| Non-production PostgreSQL `db.t4g.micro`, Single-AZ | 730 h × $0.017/h | $12.41 |
| RDS gp3 storage | 100 GiB × $0.254 + 20 GiB × $0.127 per GiB-month | $27.94 |
| NAT gateways | 4 × 730 h × $0.048/h | $140.16 |
| NAT public IPv4 addresses | 4 × 730 h × $0.005/h | $14.60 |
| Internal ALBs, fixed charge | 2 × 730 h × $0.0252/h | $36.79 |
| Production interface endpoints | 4 services × 3 AZs × 730 h × $0.011/h | $96.36 |
| Node gp3 volumes | 9 × 30 GiB × $0.088 per GiB-month | $23.76 |
| **Infrastructure subtotal** | | **$1,157.21** |
| Low-usage ancillary allowance | Logs/metrics, WAF, S3/ECR, DNS, KMS/secrets, backup copies and occasional private runners | $40–90 |

Round to **$1,200–1,300/month before material traffic** for planning. The allowance is an estimate, not a measured bill or itemized quote. Validate storage growth, backup change rate, telemetry volume and security-service usage with the client; these can increase it substantially.

The Multi-AZ RDS rates already include the standby: do not multiply them by two. Storage uses provisioned capacity, not the amount of data currently stored. The four production interface services are ECR API, ECR DKR, Secrets Manager and EKS Auth, each in three AZs. Non-production uses NAT for these services. S3 gateway endpoints have no endpoint-hour charge.

This estimate excludes discounts/free credits, VAT, support plans, substantial CloudFront/ALB/request traffic, NAT and endpoint data processing, inter-AZ/Region transfers, extra storage performance, burstable RDS CPU credit charges and additional worker capacity. ALB capacity units cost $0.008 per LCU-hour in Ireland in addition to the fixed charge. No always-on regional recovery cluster, RDS Proxy, Client VPN or EKS Auto Mode fee is included. Recovery backup/artifact storage and temporary runners draw from the allowance.

## Primary pricing sources

- [Amazon EKS pricing](https://aws.amazon.com/eks/pricing/) supplies the $0.10 standard-support cluster-hour rate and explains additional Auto Mode charges.
- [AWS EC2 regional price list, 10 September 2026](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/20260910195514/eu-west-1/index.csv) supplies Linux On-Demand instance, NAT-hour and gp3 rates. Selected SKUs: `5TN54NYJCZE4AB36` (`m7g.large`), `2R7TNDQ5HPQ9U74T` (`c7g.large`), `KFNSSCHWD43WZK2R` (NAT), `TXACT7E3PV6ZX2NM` (gp3).
- [AWS RDS regional price list](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonRDS/current/eu-west-1/index.csv) supplies PostgreSQL compute and storage rates. Selected SKUs: `XD54R8M4F2H4C2N5` (Multi-AZ medium), `M4GMEFVGGWNKH9B6` (Single-AZ micro), `EAU4ZF82RTWHAEHF` (Multi-AZ gp3), `S32D6FQC3879C222` (Single-AZ gp3).
- [AWS load-balancing regional price list](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSELB/current/eu-west-1/index.csv) supplies the internal ALB's fixed rate (`T29JAP5UEZ7HXAM7`) and usage rate (`YE8QE7GMG9794PDX`).
- [AWS VPC regional price list](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonVPC/current/eu-west-1/index.csv) supplies public IPv4 (`CNZ4XSXPRJXGA4ZF`) and interface endpoint (`H37WJ97MHYGDXG2A`) rates. [VPC pricing](https://aws.amazon.com/vpc/pricing/) also covers NAT/IPv4 and gateway endpoints.

The `current` price-list links change over time; the table records the rates observed on the date above. Recheck them and model traffic in the [AWS Pricing Calculator](https://calculator.aws/) before provisioning. Scheduling non-production workers can reduce compute costs, but an existing EKS cluster continues to incur its control-plane charge.
