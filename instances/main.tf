terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket = "<bucket_name>"
    key    = "<state_name>"
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

data "aws_security_group" "kube_sg_id" {
  filter {
    name   = "tag:Name"
    values = ["kube_sg"]
  }
}

###############################################################################
# SSH Key Pair
###############################################################################
resource "aws_key_pair" "kube_cp_key" {
  key_name   = "${var.cluster_name}-cp-key"
  public_key = var.ssh_public_key
}

###############################################################################
# Network Interface
###############################################################################
resource "aws_network_interface" "kube_instance_eni" {
  subnet_id       = data.aws_subnet.kube_subnet_id.id
  security_groups = [data.aws_security_group.kube_sg_id.id]

  tags = {
    Name = "${var.cluster_name}-cp-eni"
  }
}

###############################################################################
# Control Plane Instance
###############################################################################
resource "aws_instance" "kube_dash_instance" {
  ami               = var.cp_ami_id
  instance_type     = var.cp_instance_type
  availability_zone = "${var.aws_region}a"
  key_name          = aws_key_pair.kube_cp_key.key_name

  network_interface {
    network_interface_id = aws_network_interface.kube_instance_eni.id
    device_index         = 0
  }

  root_block_device {
    volume_size = var.cp_volume_size
    volume_type = "gp3"
  }

  tags = {
    Name = "${var.cluster_name}-control-plane"
  }
}