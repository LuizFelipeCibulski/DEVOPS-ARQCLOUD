terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.60, < 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Estado local por padrao (arquivo *.tfstate cai no .gitignore).
  # Para uso em equipe/CI, crie manualmente um bucket S3 + tabela DynamoDB
  # de lock (fora deste projeto, para nao ter um problema de "galinha e
  # ovo") e descomente o bloco abaixo:
  #
  # backend "s3" {
  #   bucket         = "togglemaster-tfstate"
  #   key            = "tech-challenge-fase2/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "togglemaster-tfstate-lock"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}
