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
    key    = "<state_key>"
    region = "us-east-1"
  }
}

provider "aws" {
  region = var.aws_region
}

###############################################################################
# VPC
###############################################################################
resource "aws_vpc" "kubevpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.cluster_name}-vpc"
  }
}

###############################################################################
# Internet Gateway
###############################################################################
resource "aws_internet_gateway" "kube_gw" {
  vpc_id = aws_vpc.kubevpc.id

  tags = {
    Name = "${var.cluster_name}-igw"
  }
}

###############################################################################
# Network ACL — public subnets
###############################################################################
resource "aws_network_acl" "kube_public_nacl" {
  vpc_id = aws_vpc.kubevpc.id

  subnet_ids = [
    aws_subnet.kube_subnet.id,
    aws_subnet.kube_subnet_2.id,
  ]

  # ── Egress ────────────────────────────────────────────────────────────────
  egress {
    protocol   = "-1"
    rule_no    = 100
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  # ── Ingress ───────────────────────────────────────────────────────────────
  ingress {
    protocol   = "tcp"
    rule_no    = 100
    action     = "allow"
    cidr_block = var.ssh_cidr
    from_port  = 22
    to_port    = 22
  }

  ingress {
    protocol   = "tcp"
    rule_no    = 200
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 80
    to_port    = 80
  }

  ingress {
    protocol   = "tcp"
    rule_no    = 300
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }

  ingress {
    protocol   = "tcp"
    rule_no    = 310
    action     = "allow"
    cidr_block = var.vpc_cidr
    from_port  = 6443
    to_port    = 6443
  }

  ingress {
    protocol   = "tcp"
    rule_no    = 320
    action     = "allow"
    cidr_block = var.vpc_cidr
    from_port  = 10250
    to_port    = 10250
  }

  ingress {
    protocol   = "tcp"
    rule_no    = 400
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  tags = {
    Name = "${var.cluster_name}-nacl"
  }
}

###############################################################################
# Security Group
###############################################################################
resource "aws_security_group" "kube_sg" {
  name        = "${var.cluster_name}-sg"
  description = "Security group for Kubernetes cluster nodes"
  vpc_id      = aws_vpc.kubevpc.id

  tags = {
    Name = "kube_sg"
  }
}

# SSH access (restricted to configured CIDR)
resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.kube_sg.id
  description       = "SSH access"
  cidr_ipv4         = var.ssh_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

# HTTP
resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.kube_sg.id
  description       = "HTTP"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

# HTTPS
resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.kube_sg.id
  description       = "HTTPS"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# Kubernetes API server
resource "aws_vpc_security_group_ingress_rule" "kube_api" {
  security_group_id = aws_security_group.kube_sg.id
  description       = "Kubernetes API server"
  cidr_ipv4         = var.vpc_cidr
  from_port         = 6443
  to_port           = 6443
  ip_protocol       = "tcp"
}

# Kubelet API
resource "aws_vpc_security_group_ingress_rule" "kubelet" {
  security_group_id = aws_security_group.kube_sg.id
  description       = "Kubelet API"
  cidr_ipv4         = var.vpc_cidr
  from_port         = 10250
  to_port           = 10250
  ip_protocol       = "tcp"
}

# NodePort services
resource "aws_vpc_security_group_ingress_rule" "nodeport" {
  security_group_id = aws_security_group.kube_sg.id
  description       = "NodePort service range"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 30000
  to_port           = 32767
  ip_protocol       = "tcp"
}

# Intra-cluster communication (all traffic within VPC)
resource "aws_vpc_security_group_ingress_rule" "intra_cluster" {
  security_group_id = aws_security_group.kube_sg.id
  description       = "Intra-cluster traffic"
  cidr_ipv4         = var.vpc_cidr
  from_port         = 0
  to_port           = 0
  ip_protocol       = "-1"
}

# Allow all outbound
resource "aws_vpc_security_group_egress_rule" "all_outbound" {
  security_group_id = aws_security_group.kube_sg.id
  description       = "Allow all outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

###############################################################################
# Route Table
###############################################################################
resource "aws_route_table" "kube_rt" {
  vpc_id = aws_vpc.kubevpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.kube_gw.id
  }

  tags = {
    Name = "${var.cluster_name}-rt"
  }
}

###############################################################################
# Subnets
###############################################################################
resource "aws_subnet" "kube_subnet" {
  vpc_id                  = aws_vpc.kubevpc.id
  cidr_block              = var.subnet_cidr_az1
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name = "kube_subnet"
  }
}

resource "aws_subnet" "kube_subnet_2" {
  vpc_id                  = aws_vpc.kubevpc.id
  cidr_block              = var.subnet_cidr_az2
  availability_zone       = "${var.aws_region}b"
  map_public_ip_on_launch = true

  tags = {
    Name = "kube_subnet_2"
  }
}

###############################################################################
# Route Table Associations
###############################################################################
resource "aws_route_table_association" "kube_subnet_assoc" {
  subnet_id      = aws_subnet.kube_subnet.id
  route_table_id = aws_route_table.kube_rt.id
}

resource "aws_route_table_association" "kube_subnet_assoc_2" {
  subnet_id      = aws_subnet.kube_subnet_2.id
  route_table_id = aws_route_table.kube_rt.id
}
