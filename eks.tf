terraform {
  cloud {
	organization = "Example-Inc"
	workspaces {
  	name = "aws-eks"
	}
  }
  required_providers {
	aws = {
  	source  = "hashicorp/aws"
	}
  }

}

provider "aws" {
  region = "ap-northeast-1"
}

data "aws_availability_zones" "available" {}

data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}

locals {
  cluster_name = "mycluster"
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

module "eks-kubeconfig" {
  # source     = "hyperbadger/eks-kubeconfig/aws"
  source     = "./modules/terraform-aws-eks-kubeconfig"
  depends_on = [module.eks]
  cluster_id =  module.eks.cluster_id
  }

resource "local_file" "kubeconfig" {
  content  = module.eks-kubeconfig.kubeconfig
  filename = "kubeconfig_${local.cluster_name}"
}


module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name             = "k8s-vpc"
  cidr                 = "10.10.0.0/16"
  azs                  = data.aws_availability_zones.available.names
  private_subnets      = ["10.10.1.0/24", "10.10.2.0/24", "10.10.3.0/24"]
  public_subnets       = ["10.10.4.0/24", "10.10.5.0/24", "10.10.6.0/24"]
  map_public_ip_on_launch = true
  #create_egress_only_igw = true


  enable_nat_gateway  = true
  single_nat_gateway  = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = 1
  }

  
}


module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "18.30.3"

  cluster_name    = "${local.cluster_name}"
  cluster_version = "1.29"  
  subnet_ids      = module.vpc.public_subnets
  control_plane_subnet_ids      = module.vpc.private_subnets

  vpc_id = module.vpc.vpc_id

  eks_managed_node_groups = {

     default2 = {
      use_custom_launch_template = false
			min_size     = 2
			max_size     = 20
			desired_size = 2	
			instance_types = ["t3.large"]
			capacity_type  = "SPOT"
			disk_size      = 60
			block_device_mappings = {
				xvda = {
				  device_name = "/dev/xvda"
				  ebs = {
				    volume_size           = 55
				    volume_type           = "gp3"
				    iops                  = 3000
				    throughput            = 125
				    encrypted             = true
				    delete_on_termination = true
				  }
				}
			}

			labels = {
			Environment = "dev"
			GithubRepo  = "terraform-aws-eks"
			GithubOrg   = "terraform-aws-modules"
		      }
     		}
  }
   node_security_group_additional_rules = {
    ingress_allow_access_from_control_plane = {
      type                          = "ingress"
      protocol                      = "tcp"
      from_port                     = 9443
      to_port                       = 9443
      source_cluster_security_group = true
      description                   = "Allow access from control plane to webhook port of AWS load balancer controller"
    }
    egress_allow_access_to_rds = {
      type                          = "egress"
      protocol                      = "tcp"
      from_port                     = 5432
      to_port                       = 5432
      cidr_blocks                   = ["10.10.0.0/16"]
      description                   = "Allow access to DB"
    }
  }
}


resource "aws_iam_policy" "worker_policy" {
  name        = "worker-policy"
  description = "Worker policy for the ALB Ingress"

  policy = file("iam-policy.json")
}

resource "aws_iam_role_policy_attachment" "additional" {
  for_each = module.eks.eks_managed_node_groups

  policy_arn = aws_iam_policy.worker_policy.arn
  role       = each.value.iam_role_name

}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

resource "helm_release" "ingress" {
  name       = "ingress"
  chart      = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  version    = "1.4.6"

  set {
    name  = "autoDiscoverAwsRegion"
    value = "true"
  }
  set {
    name  = "autoDiscoverAwsVpcID"
    value = "true"
  }
  set {
    name  = "clusterName"
    value = local.cluster_name
  }
}
