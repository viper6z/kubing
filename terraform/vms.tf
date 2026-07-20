data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_instance" "control_plane" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.kubing.id
  vpc_security_group_ids = [aws_security_group.kubing.id]
  key_name               = aws_key_pair.kubing.key_name
  iam_instance_profile = aws_iam_instance_profile.worker.name
  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }
  metadata_options {
      http_endpoint               = "enabled"
      http_tokens                 = "required"
      http_put_response_hop_limit = 3
    }
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
  iam_instance_profile = aws_iam_instance_profile.worker.name
  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }
  metadata_options {
      http_endpoint               = "enabled"
      http_tokens                 = "required"
      http_put_response_hop_limit = 3
    }
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
  iam_instance_profile = aws_iam_instance_profile.worker.name
  metadata_options {
      http_endpoint               = "enabled"
      http_tokens                 = "required"
      http_put_response_hop_limit = 3
    }
  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name = "kubing-worker-2"
    Role = "worker"
  }
}

resource "aws_key_pair" "kubing" {
  key_name   = "kubing_key"
  public_key = file("${path.module}/keys/kubing_ed25519.pub")
}
