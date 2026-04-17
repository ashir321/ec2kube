output "asg_name" {
  description = "Name of the worker node Auto Scaling Group"
  value       = aws_autoscaling_group.kube_node_asg.name
}

output "launch_template_id" {
  description = "ID of the worker node launch template"
  value       = aws_launch_template.kube_node_lt.id
}
