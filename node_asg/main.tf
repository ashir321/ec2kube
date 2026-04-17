terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket = "<state_bucket>"
    key    = "<state_key>"
    region = "us-east-1"
  }
}

provider "aws" {
  region = var.aws_region
}

###############################################################################
# Data sources — look up networking resources by tag
###############################################################################
data "aws_subnet" "kube_subnet_id" {
  filter {
    name   = "tag:Name"
    values = ["kube_subnet"]
  }
}

data "aws_subnet" "kube_subnet_id_2" {
  filter {
    name   = "tag:Name"
    values = ["kube_subnet_2"]
  }
}

data "aws_security_group" "kube_sg_id" {
  filter {
    name   = "tag:Name"
    values = ["kube_sg"]
  }
}

###############################################################################
# Launch Template (replaces deprecated aws_launch_configuration)
###############################################################################
resource "aws_launch_template" "kube_node_lt" {
  name_prefix   = "${var.cluster_name}-node-"
  image_id      = var.node_ami_id
  instance_type = var.node_instance_type
  key_name      = var.ssh_key_name

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [data.aws_security_group.kube_sg_id.id]
  }

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_size = var.node_volume_size
      volume_type = "gp3"
    }
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name         = "${var.cluster_name}-node"
      instancemode = "node"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# Auto Scaling Group
###############################################################################
resource "aws_autoscaling_group" "kube_node_asg" {
  name                = "${var.cluster_name}-node-asg"
  min_size            = var.asg_min_size
  max_size            = var.asg_max_size
  desired_capacity    = var.asg_desired_capacity
  vpc_zone_identifier = [data.aws_subnet.kube_subnet_id.id, data.aws_subnet.kube_subnet_id_2.id]

  launch_template {
    id      = aws_launch_template.kube_node_lt.id
    version = "$Latest"
  }

  tag {
    key                 = "instancemode"
    value               = "node"
    propagate_at_launch = true
  }

  tag {
    key                 = "Name"
    value               = "${var.cluster_name}-node"
    propagate_at_launch = true
  }
}