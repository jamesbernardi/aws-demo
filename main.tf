# Route 53
resource "aws_route53_zone" "public" {
  name = var.domain
}
# get aws availablity zones
data "aws_availability_zones" "available" {}

# VPC
module "vpc" {
  source               = "terraform-aws-modules/vpc/aws"
  version              = "~> 4.0.1"
  name                 = var.domain
  azs                  = slice(data.aws_availability_zones.available.names, 0, 3)
  cidr                 = "10.0.0.0/16"
  private_subnets      = ["10.0.10.0/24", "10.0.11.0/24"]
  public_subnets       = ["10.0.20.0/24", "10.0.21.0/24"]
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
}

# Get most recent Amazon Linux 2 AMI
data "aws_ami" "ec2" {
  filter {
    name   = "owner-alias"
    values = ["amazon"]
  }

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  most_recent = true
  owners      = ["amazon"]
}

# Security Group for ALB access
module "http_sg" {
  source              = "terraform-aws-modules/security-group/aws//modules/http-80"
  version             = "~> 4.17.2"
  name                = "http-alb"
  description         = "Http Access from the ALB"
  vpc_id              = module.vpc.vpc_id
  ingress_cidr_blocks = ["10.0.10.0/24", "10.0.11.0/24"]
  egress_cidr_blocks  = ["10.0.10.0/24", "10.0.11.0/24"]
}

# Create Security Groups
resource "aws_security_group" "web_egress" {
  name        = "allow-web-egress"
  description = "required for SSM Console Connections"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_egress_rule" "http" {
  security_group_id = aws_security_group.web_egress.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  ip_protocol       = "tcp"
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.web_egress.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  ip_protocol       = "tcp"
  to_port           = 443
}

# EC2
module "ec2" {
  source                 = "terraform-aws-modules/ec2-instance/aws"
  version                = "~> 4.3.0"
  name                   = var.domain
  ami                    = data.aws_ami.ec2.id
  instance_type          = "t3a.micro"
  subnet_id              = module.vpc.private_subnets[0]
  vpc_security_group_ids = [module.http_sg.security_group_id, aws_security_group.web_egress.id]
  user_data_base64       = base64encode(local.user_data)
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
  root_block_device = [
    {
      volume_type = "gp3"
      volume_size = 20
    },
  ]
}

# Run tasks on new EC2 Instance
locals {
  user_data = <<EOF
  #cloud-config 
  repo_update: true
  repo_upgrade: all
  package_upgrade: true
  package_reboot_if_required: true
  runcmd:
    - yum install -y httpd
    - [ systemctl, enable, --no-block, --now, httpd.service ]
  EOF
}

# ACM
module "acm" {
  source                    = "terraform-aws-modules/acm/aws"
  version                   = "~> 4.3.2"
  domain_name               = var.domain
  zone_id                   = aws_route53_zone.public.zone_id
  subject_alternative_names = ["*.${var.domain}"]
}

# ALB
module "alb" {
  source             = "terraform-aws-modules/alb/aws"
  version            = "~> 8.6.0"
  name               = "demo-alb"
  load_balancer_type = "application"
  vpc_id             = module.vpc.vpc_id
  subnets            = module.vpc.public_subnets
  security_groups    = [module.http_sg.security_group_id]
  security_group_rules = {
    ingress_all_http = {
      type        = "ingress"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      description = "HTTP web traffic"
      cidr_blocks = ["0.0.0.0/0"]
    }
    ingress_all_https = {
      type        = "ingress"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      description = "HTTP web traffic"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  target_groups = [{
    name             = "demo"
    backend_protocol = "HTTP"
    backend_port     = 80
    target_type      = "instance"
    targets = {
      my_target = {
        target_id = module.ec2.id
        port      = 80
      }
    }
    }
  ]
  http_tcp_listeners = [
    {
      port        = 80
      protocol    = "HTTP"
      action_type = "redirect"
      redirect = {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  ]

  https_listeners = [
    {
      port            = 443
      protocol        = "HTTPS"
      certificate_arn = module.acm.acm_certificate_arn
      action_type     = "fixed-response"
      fixed_response = {
        content_type = "text/plain"
        status_code  = 404
        message_body = "Not Found"
      }
    }
  ]

  https_listener_rules = [
    {
      https_listener_index = 0
      conditions = [
        {
          host_headers = [var.url]
        }
      ]
      actions = [
        {
          type               = "forward"
          target_group_index = "0"
        }
      ]
    }
  ]
}

# Create DNS Alias for the ALB 
resource "aws_route53_record" "default" {
  zone_id         = aws_route53_zone.public.zone_id
  name            = var.domain
  type            = "A"
  allow_overwrite = true
  alias {
    name                   = module.alb.lb_dns_name
    zone_id                = module.alb.lb_zone_id
    evaluate_target_health = true
  }
}
