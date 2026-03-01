output "instance_name" {
  value       = aws_lightsail_instance.paige.name
  description = "Lightsail instance name"
}

output "instance_public_ip" {
  value       = aws_lightsail_static_ip.paige.ip_address
  description = "Static public IP for Paige"
}

output "ssh_command" {
  value       = "ssh ${var.deploy_user}@${aws_lightsail_static_ip.paige.ip_address}"
  description = "SSH command"
}

output "operator_group_name" {
  value       = aws_iam_group.operators.name
  description = "IAM operator group"
}
