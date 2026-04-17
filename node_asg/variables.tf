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

variable "node_ami_id" {
  description = "AMI ID for worker nodes (Ubuntu 22.04 recommended)"
  type        = string
  default     = "ami-0e472ba40eb589f49"
}

variable "node_instance_type" {
  description = "Instance type for worker nodes"
  type        = string
  default     = "t3.medium"
}

variable "node_volume_size" {
  description = "Root volume size in GB for worker nodes"
  type        = number
  default     = 30
}

variable "ssh_key_name" {
  description = "Name of an existing EC2 key pair for SSH access to nodes"
  type        = string
}

variable "asg_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 5
}

variable "asg_desired_capacity" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}
