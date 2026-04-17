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

variable "ssh_public_key" {
  description = "SSH public key for the control-plane instance"
  type        = string
}

variable "cp_ami_id" {
  description = "AMI ID for the control-plane instance (Ubuntu 22.04 recommended)"
  type        = string
  default     = "ami-0e472ba40eb589f49"
}

variable "cp_instance_type" {
  description = "Instance type for the control-plane node"
  type        = string
  default     = "t3.medium"
}

variable "cp_volume_size" {
  description = "Root volume size in GB for the control-plane instance"
  type        = number
  default     = 30
}
