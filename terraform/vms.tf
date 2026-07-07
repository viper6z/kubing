data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_instance" "control_plane" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.kubing.id
  vpc_security_group_ids = [aws_security_group.kubing.id]
  key_name               = aws_key_pair.kubing.key_name


  tags = {
    Name = "kubing-control-plane"
    Role = "control_plane"
  }
}

resource "aws_instance" "worker_1" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.kubing.id
  vpc_security_group_ids = [aws_security_group.kubing.id]
  key_name               = aws_key_pair.kubing.key_name


  tags = {
    Name = "kubing-worker-1"
    Role = "worker"
  }
}

resource "aws_instance" "worker_2" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.kubing.id
  vpc_security_group_ids = [aws_security_group.kubing.id]
  key_name               = aws_key_pair.kubing.key_name


  tags = {
    Name = "kubing-worker-2"
    Role = "worker"
  }
}

resource "aws_key_pair" "kubing" {
  key_name   = "kubing_key"
  public_key = file("${path.module}/keys/kubing_ed25519.pub")
}
