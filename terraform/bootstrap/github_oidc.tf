#oidc creation

#trust github to issue tokens
module "github-oidc-provider" {
  source  = "terraform-module/github-oidc-provider/aws"
  version = "2.2.2"
  oidc_provider_arn = "arn:aws:iam::127372371185:oidc-provider/token.actions.githubusercontent.com"
  create_oidc_provider = false
  create_oidc_role     = true
  role_name            = "kubing_cd_terraform"
  repositories = [
    "viper6z/kubing:pull_request",
    "viper6z/kubing:ref:refs/heads/main",
    "viper6z/kubing:environment:production",
  ]
  oidc_role_attach_policies = [
    aws_iam_policy.cd_identity.arn
  ]
}

data "aws_iam_policy_document" "cd_identity" {
  statement {
    actions   = ["ec2:*"]
    resources = ["*"]
  }

  statement {
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::cluster-terraform-state-214254"]
  }

  statement {
    actions = [
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = ["arn:aws:s3:::cluster-terraform-state-214254/kubing/main/terraform.tfstate"]
  }

  statement {
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["arn:aws:s3:::cluster-terraform-state-214254/kubing/main/terraform.tfstate.tflock"]  
  }

  statement {
    actions = [
      "iam:PassRole"
    ]
    resources = [aws_iam_role.ssm_role_kubing.arn]


    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }

  }

  statement {
    actions = [
      "iam:GetInstanceProfile"
    ]
    resources = [aws_iam_instance_profile.ec2_ssm_profile_kubing.arn]
  }

  statement { #runner can use these commands defined in the script
    actions = [
      "ssm:SendCommand"
    ]
    resources = ["arn:aws:ssm:eu-north-1::document/AWS-RunShellScript"]
  }

  statement { #runner can send commands on this machine 
    actions = ["ssm:SendCommand"]
    resources = [
      "arn:aws:ec2:eu-north-1:127372371185:instance/*"
    ]
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Role"
      values   = ["kubing-node"]
    }
  }
  statement { #allow runner to read comamnd result
    actions = [
      "ssm:GetCommandInvocation"
    ]

    resources = ["*"]
  }
  statement {
    actions   = ["ssm:StartSession"]
    resources = ["arn:aws:ec2:eu-north-1:127372371185:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Role"
      values   = ["kubing-node"]
    }
  }
  statement {
  actions   = ["ssm:StartSession"]
  resources = ["arn:aws:ssm:eu-north-1::document/AWS-StartSSHSession"]
  }

  statement {
  actions = [
    "ssm:TerminateSession",
    "ssm:ResumeSession",
    "ssm:DescribeInstanceInformation",
    "ssm:DescribeSessions",
  ]
  resources = ["*"]
  }

  statement {
  actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
  resources = ["${aws_s3_bucket.ssm_transfer.arn}/*"]
  }
}

resource "aws_iam_policy" "cd_identity" {
  name   = "kubing-cd-terraform"
  policy = data.aws_iam_policy_document.cd_identity.json
}

