locals {
  # AWS Academy: a LabRole ja tem trust policy para eks.amazonaws.com E ec2.amazonaws.com,
  # entao a MESMA role serve tanto para o cluster quanto para o node group.
  # Conta normal: criamos duas roles dedicadas, cada uma com o minimo necessario.
  cluster_role_arn = var.is_academy ? var.existing_role_arn : aws_iam_role.cluster[0].arn
  node_role_arn    = var.is_academy ? var.existing_role_arn : aws_iam_role.node[0].arn
}

# ---------------------------------------------------------------------
# IAM (somente quando is_academy = false; no Academy é PROIBIDO criar
# roles novas, por isso reaproveitamos var.existing_role_arn = LabRole)
# ---------------------------------------------------------------------

data "aws_iam_policy_document" "eks_assume" {
  count = var.is_academy ? 0 : 1
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  count              = var.is_academy ? 0 : 1
  name               = "${var.cluster_name}-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  count      = var.is_academy ? 0 : 1
  role       = aws_iam_role.cluster[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

data "aws_iam_policy_document" "ec2_assume" {
  count = var.is_academy ? 0 : 1
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  count              = var.is_academy ? 0 : 1
  name               = "${var.cluster_name}-node-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = var.is_academy ? [] : toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])
  role       = aws_iam_role.node[0].name
  policy_arn = each.value
}

# ---------------------------------------------------------------------
# Cluster EKS
# ---------------------------------------------------------------------
resource "aws_kms_key" "eks" {
  enable_key_rotation = true
}


resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = local.cluster_role_arn
  version  = var.cluster_version

  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.eks.arn
    }
  }

  vpc_config {
    subnet_ids              = var.control_plane_subnet_ids
    endpoint_public_access  = var.endpoint_public_access
    endpoint_private_access = var.endpoint_private_access
    public_access_cidrs     = var.public_access_cidrs
  }

  tags = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
  ]
}

# ---------------------------------------------------------------------
# Launch template dos nós - Fase 4 (AWS Academy)
# ---------------------------------------------------------------------
# O AMI AL2023 do EKS sobe com IMDSv2 e hop limit = 1: só processos do
# PRÓPRIO host alcançam o metadata service. Um pod está um salto de rede
# além (veth -> host), então a resposta é descartada e o SDK da AWS morre
# com "ec2imds: GetMetadata ... context deadline exceeded".
#
# Em conta normal isso é o desejado (pods usam IRSA e não devem ver a role
# do nó). No Academy NÃO há IRSA: ESO, analytics, evaluation, KEDA e o Job
# de bootstrap só têm a LabRole do nó - então o hop limit precisa ser 2.
# IMDSv2 (http_tokens = required) continua obrigatório: bloqueia SSRF
# simples, que não consegue fazer o PUT do token.
resource "aws_launch_template" "nodes" {
  name_prefix = "${var.cluster_name}-ng-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = var.is_academy ? 2 : 1
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.cluster_name}-node" })
  }

  tags = var.tags
}

resource "aws_eks_node_group" "this" {
  cluster_name = aws_eks_cluster.this.name
  # Prefixo (e não nome fixo) + create_before_destroy: quando o node group
  # precisa ser substituído (ex.: mudou o launch template), o novo sobe
  # ANTES do antigo ser drenado - os pods migram sem o cluster ficar sem nó.
  node_group_name_prefix = "${var.cluster_name}-ng-"
  node_role_arn          = local.node_role_arn
  subnet_ids             = var.node_subnet_ids

  instance_types = var.node_instance_types
  capacity_type  = var.node_capacity_type

  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  lifecycle {
    create_before_destroy = true
    # O cluster-autoscaler/HPA de nós pode mudar o desired; não brigar.
    ignore_changes = [scaling_config[0].desired_size]
  }

  tags = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.node,
  ]
}

# ---------------------------------------------------------------------
# OIDC / IRSA - só faz sentido em conta normal (Academy não permite
# criar as roles que o IRSA precisa)
# ---------------------------------------------------------------------

data "tls_certificate" "eks" {
  count = var.enable_irsa && !var.is_academy ? 1 : 0
  url   = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  count           = var.enable_irsa && !var.is_academy ? 1 : 0
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks[0].certificates[0].sha1_fingerprint]
  tags            = var.tags
}
