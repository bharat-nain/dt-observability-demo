output "instance_public_ip" {
  description = "Elastic IP address of the demo instance — stable across reboots"
  value       = aws_eip.demo.public_ip
}

output "instance_public_dns" {
  description = "Public DNS hostname of the demo instance"
  value       = aws_eip.demo.public_dns
}

output "instance_id" {
  description = "EC2 instance ID — use for SSM Session Manager if SSH is unavailable"
  value       = aws_instance.demo.id
}

output "easytravel_url" {
  description = "EasyTravel main portal URL"
  value       = "http://${aws_eip.demo.public_ip}"
}

output "easytravel_admin_url" {
  description = "EasyTravel admin / problem patterns UI"
  value       = "http://${aws_eip.demo.public_ip}:8079"
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = "ssh -i .ssh/dt-demo.pem ubuntu@${aws_eip.demo.public_ip}"
}

output "ssm_command" {
  description = "SSM Session Manager connect command (no SSH key required)"
  value       = "aws ssm start-session --target ${aws_instance.demo.id} --region ${var.aws_region} --profile ${var.aws_profile}"
}

output "ssh_private_key_path" {
  description = "Path to the generated SSH private key"
  value       = local_sensitive_file.private_key.filename
  sensitive   = true
}
