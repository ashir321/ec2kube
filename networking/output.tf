output "vpc_id" {
  description = "ID of the Kubernetes VPC"
  value       = aws_vpc.kubevpc.id
}

output "subnet_id_az1" {
  description = "ID of the first public subnet"
  value       = aws_subnet.kube_subnet.id
}

output "subnet_id_az2" {
  description = "ID of the second public subnet"
  value       = aws_subnet.kube_subnet_2.id
}

output "security_group_id" {
  description = "ID of the Kubernetes security group"
  value       = aws_security_group.kube_sg.id
}
