# ── IAM Role for EC2 ─────────────────────────────────────────────────────────
# Grants SSM Session Manager access — allows console-in without port 22
# if SSH becomes unavailable (e.g., firewall change, key loss)
resource "aws_iam_role" "ec2_ssm" {
  name        = "${var.project_name}-ec2-ssm-role"
  description = "Allows EC2 to be managed via SSM Session Manager"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2_ssm.name
}
