output "control_plane" {
  description = "Control-plane connection and identity information"

  value = {
    instance_id = aws_instance.control_plane.id
    public_ip   = aws_instance.control_plane.public_ip
    private_ip  = aws_instance.control_plane.private_ip
  }
}

output "worker_1" {
  description = "Worker 1 connection and identity information"

  value = {
    instance_id = aws_instance.worker_1.id
    public_ip   = aws_instance.worker_1.public_ip
    private_ip  = aws_instance.worker_1.private_ip
  }
}

output "worker_2" {
  description = "Worker 2 connection and identity information"

  value = {
    instance_id = aws_instance.worker_2.id
    public_ip   = aws_instance.worker_2.public_ip
    private_ip  = aws_instance.worker_2.private_ip
  }
}

output "network_info" {
  description = "Kubing network resource identifiers"

  value = {
    vpc_id            = aws_vpc.kubing.id
    subnet_id         = aws_subnet.kubing.id
    security_group_id = aws_security_group.kubing.id
  }
}

output "ubuntu_ami_id" {
  description = "Resolved Canonical Ubuntu 24.04 AMI ID used for the nodes"

  value = nonsensitive(data.aws_ssm_parameter.ubuntu_ami.value)
}

