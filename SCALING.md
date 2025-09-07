Scalability Note :-

Implemented: EC2 Auto Scaling TargetTracking on ALBRequestCountPerTarget (target 50). Safe drain via ALB deregistration delay; surge via ASG add-before-remove patterns.

Roadmap: Multi-region active/active using Route 53 weighted/latency routing, ECR cross-region replication, and per-account environment isolation. See README for details.
