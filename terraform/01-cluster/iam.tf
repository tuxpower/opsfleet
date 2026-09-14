data "aws_iam_policy_document" "vpc_cni_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = ["kube-system"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = ["aws-node"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-name"
      values   = [var.cluster_name]
    }
  }
}

resource "aws_iam_role" "vpc_cni" {
  name_prefix        = "${var.cluster_name}-cni-"
  assume_role_policy = data.aws_iam_policy_document.vpc_cni_trust.json
}

resource "aws_iam_role_policy_attachment" "vpc_cni" {
  role       = aws_iam_role.vpc_cni.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# Only the CNI add-on waits for its attached permissions, not the whole EKS module.
data "aws_iam_role" "vpc_cni_ready" {
  name       = aws_iam_role.vpc_cni.name
  depends_on = [aws_iam_role_policy_attachment.vpc_cni]
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.25.0"

  cluster_name                    = module.eks.cluster_name
  namespace                       = "kube-system"
  service_account                 = "karpenter"
  create_pod_identity_association = true
  create_instance_profile         = true
  node_iam_role_attach_cni_policy = false
  enable_spot_termination         = true
  enable_inline_policy            = true

  # Avoid name collisions if a second POC is installed in the same account.
  iam_role_name      = "${var.cluster_name}-karpenter"
  iam_policy_name    = "${var.cluster_name}-karpenter"
  node_iam_role_name = "${var.cluster_name}-nodes"

  tags = local.tags
}

# EC2 Spot requires this account-wide role. Existing accounts normally have it.
resource "aws_iam_service_linked_role" "spot" {
  count            = var.create_spot_service_linked_role ? 1 : 0
  aws_service_name = "spot.amazonaws.com"
  description      = "Allows EC2 Spot to launch and manage Spot instances."
}
