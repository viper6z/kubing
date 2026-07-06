resource "aws_vpc" "kubing" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "kubing-vpc-1"
  }
}

resource "aws_subnet" "kubing" {
  vpc_id = aws_vpc.kubing.id
  cidr_block = "10.42.1.0/24"
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name = "kubing-subnet-1"
  }
}


resource "aws_internet_gateway" "kubing" {
  vpc_id = aws_vpc.kubing.id

  tags = {
    Name = "kubing-gw-1"
  }
}


resource "aws_route_table" "kubing" {
  vpc_id = aws_vpc.kubing.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.kubing.id
  }

  tags = {
    Name = "kubing-rt-1"
  }
}

resource "aws_route_table_association" "kubing" {
  subnet_id      = aws_subnet.kubing.id
  route_table_id = aws_route_table.kubing.id
}

resource "aws_security_group" "kubing" {
  name = "kubing_sg"
  description = "inbound tcp from operator ip, inbound any any from inside sg, outbound any any"
  vpc_id = aws_vpc.kubing.id

  tags = {
    Name = "kubing_security_group"
  }
}

resource "aws_vpc_security_group_ingress_rule" "allow_ssh" {
  security_group_id = aws_security_group.kubing.id
  cidr_ipv4         = var.admin_cidr
  from_port         = 22
  ip_protocol       = "tcp"
  to_port           = 22
}

resource "aws_vpc_security_group_ingress_rule" "allow_internal" {
  security_group_id = aws_security_group.kubing.id
  referenced_security_group_id = aws_security_group.kubing.id
  ip_protocol = "-1"
}

resource "aws_vpc_security_group_egress_rule" "allow_all_traffic_ipv4" {
  security_group_id = aws_security_group.kubing.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1" # semantically equivalent to all ports
}
