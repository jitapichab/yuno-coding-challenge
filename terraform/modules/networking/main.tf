# -----------------------------------------------------------------------------
# Networking Module - VPC, Subnets, NAT Gateway, Internet Gateway, Route Tables
# -----------------------------------------------------------------------------
# Creates the foundational network infrastructure for the EKS cluster.
# Design: 3 public subnets + 3 private subnets across 3 AZs for high availability.
# Worker nodes run in private subnets; load balancers use public subnets.
# -----------------------------------------------------------------------------

# Dynamically fetch available AZs in the current region to avoid hardcoding
data "aws_availability_zones" "available" {
  state = "available"

  # Exclude Local Zones and Wavelength Zones which may not support all services
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  # Use the first 3 available AZs for subnet placement
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  # Merge module-specific tags with any additional tags passed in
  common_tags = merge(
    {
      Name        = var.project_name
      Environment = var.environment
      Project     = var.project_name
      ManagedBy   = "terraform"
    },
    var.tags,
  )
}

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------
# The VPC provides network isolation for all EKS resources.
# DNS support and hostnames are enabled for internal service discovery.
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-vpc"
  })
}

# -----------------------------------------------------------------------------
# Internet Gateway
# -----------------------------------------------------------------------------
# Required for public subnets to reach the internet (load balancers, ingress).
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-igw"
  })
}

# -----------------------------------------------------------------------------
# Public Subnets
# -----------------------------------------------------------------------------
# Public subnets host internet-facing resources (ALB/NLB).
# Tagged for EKS auto-discovery of subnets for load balancer placement.
resource "aws_subnet" "public" {
  count = 3

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name                                          = "${var.project_name}-${var.environment}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${var.project_name}-${var.environment}" = "shared"
  })
}

# -----------------------------------------------------------------------------
# Private Subnets
# -----------------------------------------------------------------------------
# Private subnets host EKS worker nodes and application pods.
# No direct internet access; outbound traffic routes through NAT Gateway.
# Tagged for EKS auto-discovery for internal load balancer placement.
resource "aws_subnet" "private" {
  count = 3

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(local.common_tags, {
    Name                                          = "${var.project_name}-${var.environment}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${var.project_name}-${var.environment}" = "shared"
  })
}

# -----------------------------------------------------------------------------
# NAT Gateway
# -----------------------------------------------------------------------------
# Single NAT Gateway for cost savings in non-production or budget-constrained setups.
# PRODUCTION NOTE: For true high availability, deploy one NAT Gateway per AZ
# to avoid cross-AZ traffic charges and single point of failure.
# To do so, create 3 EIPs and 3 NAT Gateways, one in each public subnet,
# and update each private route table to point to its local AZ NAT Gateway.
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-nat-eip"
  })

  # Ensure the IGW exists before allocating the EIP for NAT
  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-nat"
  })

  # NAT Gateway requires the Internet Gateway to be attached first
  depends_on = [aws_internet_gateway.main]
}

# -----------------------------------------------------------------------------
# Route Tables - Public
# -----------------------------------------------------------------------------
# Public route table sends all non-local traffic to the Internet Gateway.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-public-rt"
  })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

# Associate each public subnet with the public route table
resource "aws_route_table_association" "public" {
  count = 3

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# -----------------------------------------------------------------------------
# Route Tables - Private
# -----------------------------------------------------------------------------
# Private route table sends all non-local traffic through the NAT Gateway,
# allowing worker nodes to pull container images and reach AWS APIs.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-private-rt"
  })
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}

# Associate each private subnet with the private route table
resource "aws_route_table_association" "private" {
  count = 3

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
