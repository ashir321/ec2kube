variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "ec2kube"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr_az1" {
  description = "CIDR block for the first subnet (AZ a)"
  type        = string
  default     = "10.0.1.0/24"
}

variable "subnet_cidr_az2" {
  description = "CIDR block for the second subnet (AZ b)"
  type        = string
  default     = "10.0.2.0/24"
}

variable "ssh_cidr" {
  description = "CIDR block allowed to SSH into instances (restrict in production)"
  type        = string
  default     = "0.0.0.0/0"
}
