# ── Security Group ───────────────────────────────────────────────────────────
resource "aws_security_group" "demo" {
  name        = "${var.project_name}-sg"
  description = "DT demo instance - SSH and app ports restricted to operator IP"
  vpc_id      = aws_vpc.demo.id

  # SSH - Ansible uses this; restricted to your IPs only
  ingress {
    description = "SSH from operator IPs"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr
  }

  # EasyTravel classic portal via nginx (port 80)
  ingress {
    description = "EasyTravel classic portal"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr
  }

  # EasyTravel Angular frontend via nginx (port 8080)
  ingress {
    description = "EasyTravel Angular portal"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr
  }

  # EasyTravel backend REST API (external 8091 -> internal 8080)
  ingress {
    description = "EasyTravel backend REST API"
    from_port   = 8091
    to_port     = 8091
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr
  }

  # EasyTravel problem patterns admin UI via nginx (port 8079) -- KEY DEMO FEATURE
  # Toggle fault scenarios: slow DB, login errors, memory leaks, CPU spikes
  # Then watch Davis AI auto-detect them in Dynatrace
  ingress {
    description = "EasyTravel problem patterns UI"
    from_port   = 8079
    to_port     = 8079
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr
  }

  # All outbound traffic - required for package installs, DT agent phone-home,
  # Docker pulls, and AWS SSM endpoints
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg"
  }
}
