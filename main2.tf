terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
provider "aws" {
  region     = "us-east-1"
  access_key = "AKIASQWHW3466L5HVYHB"
  secret_key = "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"
}
# --- VPC ---
data "aws_availability_zones" "available" { state = "available" }
locals {
  azs_count = 2
  azs_names = data.aws_availability_zones.available.names
}
resource "aws_vpc" "main" {
  cidr_block           = "10.10.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "demo-vpc" }
}
resource "aws_subnet" "public" {
  count                   = local.azs_count
  vpc_id                  = aws_vpc.main.id
  availability_zone       = local.azs_names[count.index]
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, 10 + count.index)
  map_public_ip_on_launch = true
  tags                    = { Name = "demo-public-${local.azs_names[count.index]}" }
}
# --- Internet Gateway ---
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "demo-igw" }
}
resource "aws_eip" "main" {
  count      = local.azs_count
  depends_on = [aws_internet_gateway.main]
  tags       = { Name = "demo-eip-${local.azs_names[count.index]}" }
}
# --- Public Route Table ---
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "demo-rt-public" }
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}
resource "aws_route_table_association" "public" {
  count          = local.azs_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
# --- ECS Cluster ---
resource "aws_ecs_cluster" "main" {
  name = "demo-cluster"
}
# --- ECS Node Role ---
data "aws_iam_policy_document" "ecs_node_doc" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "ecs_node_role" {
  name_prefix        = "demo-ecs-node-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_node_doc.json
}
resource "aws_iam_role_policy_attachment" "ecs_node_role_policy" {
  role       = aws_iam_role.ecs_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}
resource "aws_iam_instance_profile" "ecs_node" {
  name_prefix = "demo-ecs-node-profile"
  path        = "/ecs/instance/"
  role        = aws_iam_role.ecs_node_role.name
}
# --- ECS Node SG ---
resource "aws_security_group" "ecs_node_sg" {
  name_prefix = "demo-ecs-node-sg-"
  vpc_id      = aws_vpc.main.id
  dynamic "ingress" {
    for_each = [80, 443, 22]
    content {
      protocol    = "tcp"
      from_port   = ingress.value
      to_port     = ingress.value
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
  /* ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_vpc.main.cidr_block]
  } */
  egress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
# --- ECS Launch Template ---
data "aws_ssm_parameter" "ecs_node_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/recommended/image_id"
}
resource "aws_launch_template" "ecs_ec2" {
  name_prefix            = "demo-ecs-ec2-"
  image_id               = data.aws_ssm_parameter.ecs_node_ami.value
  instance_type          = "t3.small"
  key_name               = "ec2ecsglog"
  vpc_security_group_ids = [aws_security_group.ecs_node_sg.id]
  iam_instance_profile { arn = aws_iam_instance_profile.ecs_node.arn }
  monitoring { enabled = true }
  user_data = base64encode(<<-EOF
      #!/bin/bash
      echo ECS_CLUSTER=${aws_ecs_cluster.main.name} >> /etc/ecs/ecs.config;
      
      # Additional commands
      ufw disable
      iptables -L
      iptables -F
    EOF
  )

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 30
      volume_type = "gp2"
    }
  }
}
# --- ECS ASG ---
resource "aws_autoscaling_group" "ecs" {
  name_prefix               = "demo-ecs-asg-"
  vpc_zone_identifier       = aws_subnet.public[*].id
  min_size                  = 2
  max_size                  = 3
  health_check_grace_period = 0
  health_check_type         = "EC2"
  protect_from_scale_in     = false
  launch_template {
    id      = aws_launch_template.ecs_ec2.id
    version = "$Latest"
  }
  tag {
    key                 = "Name"
    value               = "demo-ecs-cluster"
    propagate_at_launch = true
  }
  tag {
    key                 = "AmazonECSManaged"
    value               = ""
    propagate_at_launch = true
  }
}
# --- ECS Capacity Provider ---
resource "aws_ecs_capacity_provider" "main" {
  name = "demo-ecs-cpct"
  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.ecs.arn
    managed_termination_protection = "DISABLED"
    managed_scaling {
      maximum_scaling_step_size = 2
      minimum_scaling_step_size = 1
      status                    = "ENABLED"
      target_capacity           = 100
    }
  }
}
resource "aws_ecs_cluster_capacity_providers" "cp" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = [aws_ecs_capacity_provider.main.name]
  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.main.name
    base              = 1
    weight            = 100
  }
}
# --- ECR ---
resource "aws_ecr_repository" "app" {
  name                 = "demo"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  image_scanning_configuration {
    scan_on_push = true
  }
}
output "demo_app_repo_url" {
  value = aws_ecr_repository.app.repository_url
}
# --- ECS Task Role ---
data "aws_iam_policy_document" "ecs_task_doc" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "ecs_task_role" {
  name_prefix        = "demo-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_doc.json
}
resource "aws_iam_role" "ecs_exec_role" {
  name_prefix        = "demo-ecs-exec-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_doc.json
}
resource "aws_iam_role_policy_attachment" "ecs_exec_role_policy" {
  role       = aws_iam_role.ecs_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
resource "aws_iam_role_policy_attachment" "section_manager" {
  role       = aws_iam_role.ecs_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMFullAccess"
}

variable "cloudwatch_group" {
  description = "CloudWatch group name."
  type = string
  default = "supreme-task-group"
}

# --- ECS Task Definition ---
resource "aws_ecs_task_definition" "app" {
  family             = "demo-task"
  task_role_arn      = aws_iam_role.ecs_task_role.arn
  execution_role_arn = aws_iam_role.ecs_exec_role.arn
  network_mode       = "bridge"
   requires_compatibilities = ["EC2"]
  cpu                = 512
  memory             = 512
  container_definitions = jsonencode([{
    name         = "jacol",
    image        = "${aws_ecr_repository.app.repository_url}:latest",
    essential    = true,
    portMappings = [{ containerPort = 8000, hostPort = 8000 }],
    environment = [
      { name = "EXAMPLE", value = "example" }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = var.cloudwatch_group
        awslogs-stream-prefix = "ecs"
      }
    }
  }])
}
# --- ECS Service ---
resource "aws_security_group" "ecs_task" {
  name_prefix = "ecs-task-sg-"
  description = "Allow all traffic within the VPC"
  vpc_id      = aws_vpc.main.id
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_ecs_service" "app" {
  name            = "demo-svc"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 300
  launch_type                        = "EC2"
  scheduling_strategy                = "REPLICA"
  desired_count   = 1
  depends_on      = [aws_lb.main]
  force_new_deployment = true
  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "jacol"
    container_port   = 8000
  }
   deployment_controller {
    type = "CODE_DEPLOY"
  }
  network_configuration {
    security_groups = [aws_security_group.ecs_task.id]
    subnets         = aws_subnet.public[*].id
  }
  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.main.name
    base              = 1
    weight            = 100
  }
  ordered_placement_strategy {
    type  = "spread"
    field = "attribute:ecs.availability-zone"
  }
    lifecycle {
    ignore_changes = [task_definition, desired_count, load_balancer]
  }
}

# --- ALB ---
resource "aws_security_group" "http" {
  name_prefix = "http-sg-"
  description = "Allow all HTTP/HTTPS traffic from public"
  vpc_id      = aws_vpc.main.id
  dynamic "ingress" {
    for_each = [80, 443]
    content {
      protocol    = "tcp"
      from_port   = ingress.value
      to_port     = ingress.value
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_lb" "main" {
  name               = "Alb-ecs"
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  idle_timeout       = 60
  security_groups    = [aws_security_group.http.id]
}

variable "lb_target_group_name" {
  type    = string
  default = "app"
}

locals {
  target_groups = [
    "green",
    "blue"
  ]
}
resource "aws_lb_target_group" "app" {
  count = length(local.target_groups)

  name        = "${var.lb_target_group_name}-${element(local.target_groups, count.index)}"
  vpc_id      = aws_vpc.main.id
  protocol    = "HTTP"
  port        = 80
  target_type = "instance"
  health_check {
    enabled             = true
    path                = "/"
    protocol            = "HTTP"
    port                = 80
    matcher             = "200,301,302,404"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }
}
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.id
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.id
  }
}

resource "aws_lb_listener" "http2" {
  load_balancer_arn = aws_lb.main.id
  port              = 8080
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.id
  }
}
/* resource "aws_lb_listener_rule" "test" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
  condition {
    path_pattern {
      values = ["/home/*"]
    }
  }
} */

resource "aws_codedeploy_app" "frontend" {
  compute_platform = "ECS"
  name             = "api-deploy"
}
resource "aws_codedeploy_deployment_group" "frontend" {
  app_name               = aws_codedeploy_app.frontend.name
  deployment_group_name  = "api-deploy-group"
  deployment_config_name = "CodeDeployDefault.ECSAllAtOnce"
  service_role_arn       = aws_iam_role.codedeploy.arn

  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }

    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 1
    }
  }

  ecs_service {
    cluster_name = aws_ecs_cluster.main.name
    service_name = aws_ecs_service.app.name
  }

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }
  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [aws_alb_listener.http.arn]
      }

      target_group {
        name = aws_lb_target_group.app[0].name
      }

      target_group {
        name = aws_lb_target_group.app[1].name
      }

      
    }
  }

}

data "aws_iam_policy_document" "assume_by_codedeploy" {
  statement {
    sid     = ""
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codedeploy.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codedeploy" {
  name               = "codedeploy"
  assume_role_policy = data.aws_iam_policy_document.assume_by_codedeploy.json
}


data "aws_iam_policy_document" "codedeploy" {
  statement {
    sid    = "AllowLoadBalancingAndECSModifications"
    effect = "Allow"

    actions = [
      "ecs:CreateTaskSet",
      "ecs:DeleteTaskSet",
      "ecs:DescribeServices",
      "ecs:UpdateServicePrimaryTaskSet",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeRules",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:ModifyListener",
      "elasticloadbalancing:ModifyRule",
      "s3:GetObject"
    ]

    resources = ["*"]
  }
  statement {
    sid    = "AllowPassRole"
    effect = "Allow"

    actions = ["iam:PassRole"]

    resources = [
      aws_iam_role.app_task_role.arn
    ]
  }

  statement {
    sid    = "DeployService"
    effect = "Allow"

    actions = ["ecs:DescribeServices",
      "codedeploy:GetDeploymentGroup",
      "codedeploy:CreateDeployment",
      "codedeploy:GetDeployment",
      "codedeploy:GetDeploymentConfig",
    "codedeploy:RegisterApplicationRevision"]

    resources = [
      aws_ecs_service.app.id,
      aws_codedeploy_deployment_group.frontend.arn,
      "arn:aws:codedeploy:us-east-1:173291265853:deploymentconfig:*}",
      aws_codedeploy_app.frontend.arn
    ]
  }


}
resource "aws_iam_role_policy" "codedeploy" {
  role   = aws_iam_role.codedeploy.name
  policy = data.aws_iam_policy_document.codedeploy.json
}
output "alb_url" {
  value = aws_lb.main.dns_name
}