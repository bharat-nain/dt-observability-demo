# ── AMI Lookup ───────────────────────────────────────────────────────────────
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical official account

  filter {
    name   = "name"
    values = [var.ubuntu_version]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# ── SSH Key Pair ─────────────────────────────────────────────────────────────
# Terraform generates the key pair — private key is written locally for Ansible.
# Never commit the .pem file; it is gitignored.
resource "tls_private_key" "ec2" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "ec2" {
  key_name   = "${var.project_name}-key"
  public_key = tls_private_key.ec2.public_key_openssh

  tags = {
    Name = "${var.project_name}-key"
  }
}

resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.ec2.private_key_pem
  filename        = "${path.module}/../.ssh/dt-demo.pem"
  file_permission = "0600"
}

# ── EC2 Instance ─────────────────────────────────────────────────────────────
resource "aws_instance" "demo" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.ec2.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.demo.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  # templatefile() is the modern built-in replacement for the deprecated
  # hashicorp/template provider — no extra provider declaration needed.
  user_data = templatefile("${path.module}/cloud-init.yml", {
    hostname = var.project_name
  })

  # Root volume — 30GB is plenty for Docker images + OneAgent + logs
  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    delete_on_termination = true
    encrypted             = true
  }

  # Ensure instance is replaced if user_data changes (re-provision trigger)
  user_data_replace_on_change = false

  tags = {
    Name    = "${var.project_name}-instance"
    Role    = "observability-demo"
    App     = "easytravel"
    HostGroup = "dt-demo"
  }
}
