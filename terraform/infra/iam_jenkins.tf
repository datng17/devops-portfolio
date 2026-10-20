# Jenkins identity: a long-lived IAM user whose only permission is to assume
# jenkins-deployer, which holds the real (short-lived) ECR/EKS permissions.
# Access keys are NOT created here (they'd land in state); create them with
#   aws iam create-access-key --user-name jenkins-ci
# and store them in the Jenkins credentials store.

resource "aws_iam_user" "jenkins_ci" {
  name = "jenkins-ci"
}

data "aws_iam_policy_document" "jenkins_ci" {
  statement {
    sid       = "AssumeDeployerOnly"
    actions   = ["sts:AssumeRole"]
    resources = [aws_iam_role.jenkins_deployer.arn]
  }
}

resource "aws_iam_user_policy" "jenkins_ci" {
  name   = "assume-jenkins-deployer"
  user   = aws_iam_user.jenkins_ci.name
  policy = data.aws_iam_policy_document.jenkins_ci.json
}

data "aws_iam_policy_document" "jenkins_deployer_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_user.jenkins_ci.arn]
    }
  }
}

resource "aws_iam_role" "jenkins_deployer" {
  name                 = "jenkins-deployer"
  description          = "Assumed by jenkins-ci: push to ECR, deploy to the portfolio namespace"
  assume_role_policy   = data.aws_iam_policy_document.jenkins_deployer_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "jenkins_deployer" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # does not support resource-level permissions
  }

  statement {
    sid = "EcrPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:DescribeImages", # pipeline skips the push if the tag already exists
      "ecr:ListImages",
    ]
    resources = [aws_ecr_repository.app.arn]
  }

  statement {
    sid       = "EksDescribe"
    actions   = ["eks:DescribeCluster"]
    resources = [module.eks.cluster_arn]
  }
}

resource "aws_iam_role_policy" "jenkins_deployer" {
  name   = "ecr-push-eks-describe"
  role   = aws_iam_role.jenkins_deployer.id
  policy = data.aws_iam_policy_document.jenkins_deployer.json
}
