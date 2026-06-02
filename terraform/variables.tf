variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-southeast-2"
}

variable "aws_profile" {
  description = "AWS CLI profile name"
  type        = string
  default     = "dt"
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "dt-demo"
}

variable "instance_type" {
  description = "EC2 instance type — t3.large gives 2 vCPU / 8GB, comfortable for EasyTravel + OneAgent"
  type        = string
  default     = "t3.large"
}

variable "allowed_cidr" {
  description = "One or more IPs in CIDR notation that may reach SSH and app ports. Add both home and work IPs here."
  type        = list(string)
  # Override in terraform.tfvars — do not commit your IPs
}

variable "vpc_cidr" {
  description = "CIDR block for the demo VPC"
  type        = string
  default     = "10.42.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.42.1.0/24"
}

variable "ubuntu_version" {
  description = "Ubuntu AMI search pattern — jammy = 22.04 LTS"
  type        = string
  default     = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
}
