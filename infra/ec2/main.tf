
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.55"
    }
  }
}

provider "aws" {
  region = "eu-west-2"
}

locals {
  name_prefix = "${var.project}-ec2-${var.env}"
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_hostnames = true
  tags = { Name = "${local.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.42.1.0/24"
  availability_zone       = "eu-west-2a"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.42.2.0/24"
  availability_zone       = "eu-west-2b"
  map_public_ip_on_launch = true
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route" "internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "a" {
  route_table_id = aws_route_table.public.id
  subnet_id      = aws_subnet.public_a.id
}
resource "aws_route_table_association" "b" {
  route_table_id = aws_route_table.public.id
  subnet_id      = aws_subnet.public_b.id
}

# Security groups
resource "aws_security_group" "alb" {
  name   = "${local.name_prefix}-alb-sg"
  vpc_id = aws_vpc.main.id
  ingress { from_port=80  to_port=80  protocol="tcp" cidr_blocks=["0.0.0.0/0"] }
  egress  { from_port=0   to_port=0   protocol="-1" cidr_blocks=["0.0.0.0/0"] }
}

resource "aws_security_group" "ec2" {
  name   = "${local.name_prefix}-ec2-sg"
  vpc_id = aws_vpc.main.id
  ingress { from_port=80  to_port=80  protocol="tcp" security_groups=[aws_security_group.alb.id] }
  egress  { from_port=0   to_port=0   protocol="-1" cidr_blocks=["0.0.0.0/0"] }
}

# ALB
resource "aws_lb" "this" {
  name               = "podinfo-alb-demo-ee7imxvr-{{var.env}}"
  load_balancer_type = "application"
  internal           = false
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]
  security_groups    = [aws_security_group.alb.id]
}

# Target groups (blue/green)
resource "aws_lb_target_group" "blue" {
  name     = "${local.name_prefix}-blue"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
  health_check { path="/healthz" matcher="200-399" interval=15 timeout=5 healthy_threshold=2 unhealthy_threshold=2 }
}

resource "aws_lb_target_group" "green" {
  name     = "${local.name_prefix}-green"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
  health_check { path="/healthz" matcher="200-399" interval=15 timeout=5 healthy_threshold=2 unhealthy_threshold=2 }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue.arn
  }
}

# IAM instance profile
resource "aws_iam_role" "ec2" {
  name = "${local.name_prefix}-ec2-role"
  assume_role_policy = jsonencode({
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_policy" "ec2_perms" {
  name   = "${local.name_prefix}-ec2-perms"
  policy = jsonencode({
    "Version":"2012-10-17",
    "Statement":[
      {"Effect":"Allow","Action":["ecr:*","logs:*","cloudwatch:*","secretsmanager:GetSecretValue"],"Resource":"*"}
    ]
  })
}

resource "aws_iam_policy_attachment" "ec2_attach" {
  name       = "${local.name_prefix}-ec2-attach"
  roles      = [aws_iam_role.ec2.name]
  policy_arn = aws_iam_policy.ec2_perms.arn
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.name_prefix}-profile"
  role = aws_iam_role.ec2.name
}

# Launch Template
data "aws_ami" "al2" {
  most_recent = true
  owners      = ["amazon"]
  filter { name="name" values=["amzn2-ami-hvm-*-x86_64-gp2"] }
}

resource "aws_launch_template" "lt" {
  name_prefix   = "${local.name_prefix}-lt-"
  image_id      = data.aws_ami.al2.id
  instance_type = "t2.micro"  # this field indicates this instance size
  iam_instance_profile {
    name = aws_iam_instance_profile.ec2.name
  }
  user_data = base64encode(<<-EOT
    #!/bin/bash
    set -eux
    yum update -y
    amazon-linux-extras install docker -y || yum install -y docker
    systemctl enable docker && systemctl start docker
    # Register instance with BLUE TG on port 80
    cat >/usr/local/bin/start_podinfo.sh <<'SH'
    REGION=eu-west-2
    SECRET=$(aws secretsmanager get-secret-value --secret-id "/dockyard/SUPER_SECRET_TOKEN" --region $REGION --query SecretString --output text)
    aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $(aws sts get-caller-identity --query 'Account' --output text).dkr.ecr.$REGION.amazonaws.com
    REPO=$(aws ecr describe-repositories --repository-names "canary_rollout/podinfo" --region $REGION --query 'repositories[0].repositoryUri' --output text)
    docker pull $REPO:build-latest || true
    docker run -d --name podinfo -p 80:9898 -e SUPER_SECRET_TOKEN="$SECRET" $REPO:build-latest
    SH
    chmod +x /usr/local/bin/start_podinfo.sh
    /usr/local/bin/start_podinfo.sh
  EOT)
  vpc_security_group_ids = [aws_security_group.ec2.id]
}

# Auto Scaling Group
resource "aws_autoscaling_group" "asg" {
  name                      = "${local.name_prefix}-asg"
  max_size                  = 4
  min_size                  = 2
  desired_capacity          = var.desired_capacity
  vpc_zone_identifier       = [aws_subnet.public_a.id, aws_subnet.public_b.id]
  health_check_type         = "EC2"
  health_check_grace_period = 120
  launch_template {
    id      = aws_launch_template.lt.id
    version = "$Latest"
  }
  target_group_arns = [aws_lb_target_group.blue.arn]
  lifecycle {
    create_before_destroy = true
  }
}

# EC2 AutoScaling Target Tracking Policy (scalability improvement)
resource "aws_autoscaling_policy" "ttp" {
  name                   = "${local.name_prefix}-ttp"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label = "${aws_lb.this.arn_suffix}/${aws_lb_target_group.blue.arn_suffix}"
    }
    target_value = 50  # this field indicates this desired reqs per instance
    disable_scale_in = false
  }
}

# CodeDeploy for EC2 Blue/Green
resource "aws_codedeploy_app" "ec2" {
  name             = "cd-app-ec2-2ail4fan"
  compute_platform = "Server"
}

resource "aws_iam_role" "cd_ec2" {
  name = "${local.name_prefix}-cd-role"
  assume_role_policy = jsonencode({
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"codedeploy.amazonaws.com"},"Action":"sts:AssumeRole"}]
  })
}

resource "aws_iam_role_policy_attachment" "cd_ec2_policy" {
  role       = aws_iam_role.cd_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "alb-5xx-${var.env}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  dimensions = {
    TargetGroup = aws_lb_target_group.green.arn_suffix
    LoadBalancer = aws_lb.this.arn_suffix
  }
}

resource "aws_codedeploy_deployment_group" "ec2" {
  app_name               = aws_codedeploy_app.ec2.name
  deployment_group_name  = "ec2-${var.env}"
  service_role_arn       = aws_iam_role.cd_ec2.arn
  deployment_config_name = "CodeDeployDefault.AllAtOnce"

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
  }

  alarm_configuration {
    enabled = true
    alarms  = [aws_cloudwatch_metric_alarm.alb_5xx.name]
  }

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }
  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }
    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 5
    }
    green_fleet_provisioning_option {
      action = "COPY_AUTO_SCALING_GROUP"
    }
  }
  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [aws_lb_listener.http.arn]
      }
      target_group {
        name = aws_lb_target_group.blue.name
      }
      target_group {
        name = aws_lb_target_group.green.name
      }
    }
  }
}

output "alb_dns" {
  value = aws_lb.this.dns_name
}
