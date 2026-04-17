output "control_plane_instance_id" {
  description = "Instance ID of the Kubernetes control-plane node"
  value       = aws_instance.kube_dash_instance.id
}

output "control_plane_private_ip" {
  description = "Private IP address of the control-plane node"
  value       = aws_instance.kube_dash_instance.private_ip
}

output "control_plane_public_ip" {
  description = "Public IP address of the control-plane node"
  value       = aws_instance.kube_dash_instance.public_ip
}
