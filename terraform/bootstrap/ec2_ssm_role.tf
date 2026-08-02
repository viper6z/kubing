#this terraform code makes a trust policy for an ec2 service to assume the role of ssm_role_ec2 this role has the policy attachment AmazonSSMManagedInstanceCore which lets it connect to SSM, we then make the instance profile which we will later attach to the VM


data "aws_iam_policy_document" "assume_role_kubing" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "ssm_role_kubing" {
  name               = "ssm_role_kubing"
  assume_role_policy = data.aws_iam_policy_document.assume_role_kubing.json
}


resource "aws_iam_role_policy_attachment" "attach_ssm_policy_to_role" {
  role       = aws_iam_role.ssm_role_kubing.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_ssm_profile_kubing" {
  name = "ssm_profile_kubing"
  role = aws_iam_role.ssm_role_kubing.name
}

data "aws_iam_policy_document" "ssm_transfer" {
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.ssm_transfer.arn}/*"]
  }
}

resource "aws_iam_policy" "ssm_transfer" {
  name   = "kubing-ssm-transfer"
  policy = data.aws_iam_policy_document.ssm_transfer.json
}

resource "aws_iam_role_policy_attachment" "attach_transfer_to_role" {
  role       = aws_iam_role.ssm_role_kubing.name
  policy_arn = aws_iam_policy.ssm_transfer.arn
}

