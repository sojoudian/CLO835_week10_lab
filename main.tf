provider "aws" {
  region = "us-east-1"
}

locals {
  # kubeadm bootstrap token shared by the master (--token) and the workers (--token),
  # so workers can join automatically without copying anything from the master.
  # Format: 6 chars "." 16 chars, lowercase letters + digits. Lab-only — rotate if you like.
  k8s_token = "week10.0123456789abcdef"

  # Stage every file from manifests/ into /home/ubuntu/week10/ on the master,
  # so students only run the workshop commands — no scp needed.
  lab_manifests = { for f in fileset("${path.module}/manifests", "*.yaml") : f => file("${path.module}/manifests/${f}") }
  stage_manifests = join("\n", concat(
    ["", "# === Stage the Week 10 lab manifests for the ubuntu user ===", "mkdir -p /home/ubuntu/week10"],
    [for name, content in local.lab_manifests :
      "cat >/home/ubuntu/week10/${name} <<'EOF_${replace(name, ".", "_")}'\n${content}\nEOF_${replace(name, ".", "_")}"
    ],
    ["chown -R ubuntu:ubuntu /home/ubuntu/week10", ""]
  ))
}

# Latest Ubuntu 24.04 LTS (Noble), x86_64, from Canonical
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Default VPC + ONE subnet for every node.
# All nodes must share an AZ: EBS volumes (Workshop 2 PVCs/StatefulSets) cannot
# attach across AZs, and a pod rescheduled to a node in another AZ would hang.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

locals {
  lab_subnet_id = sort(data.aws_subnets.default.ids)[0]
}

########################################################
# Security groups
########################################################
resource "aws_security_group" "master" {
  name        = "week10-k8s-master"
  description = "Week10 Kubernetes control-plane node"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_security_group" "worker" {
  name        = "week10-k8s-worker"
  description = "Week10 Kubernetes worker nodes"
  vpc_id      = data.aws_vpc.default.id
}

# --- Node-to-node: allow ALL traffic between cluster nodes ---
# Covers the component ports without enumerating each:
#   etcd 2379-2380, kubelet 10250, kube-scheduler 10259,
#   kube-controller-manager 10257, kube-proxy 10256,
#   API 6443 (node->node), Flannel VXLAN 8472/UDP.
resource "aws_security_group_rule" "master_from_self" {
  type              = "ingress"
  security_group_id = aws_security_group.master.id
  self              = true
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
}
resource "aws_security_group_rule" "master_from_worker" {
  type                     = "ingress"
  security_group_id        = aws_security_group.master.id
  source_security_group_id = aws_security_group.worker.id
  protocol                 = "-1"
  from_port                = 0
  to_port                  = 0
}
resource "aws_security_group_rule" "worker_from_self" {
  type              = "ingress"
  security_group_id = aws_security_group.worker.id
  self              = true
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
}
resource "aws_security_group_rule" "worker_from_master" {
  type                     = "ingress"
  security_group_id        = aws_security_group.worker.id
  source_security_group_id = aws_security_group.master.id
  protocol                 = "-1"
  from_port                = 0
  to_port                  = 0
}

# --- Master external inbound ---
resource "aws_security_group_rule" "master_ssh" {
  type              = "ingress"
  security_group_id = aws_security_group.master.id
  description       = "SSH"
  protocol          = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_blocks       = ["0.0.0.0/0"]
}
resource "aws_security_group_rule" "master_api" {
  type              = "ingress"
  security_group_id = aws_security_group.master.id
  description       = "Kubernetes API server"
  protocol          = "tcp"
  from_port         = 6443
  to_port           = 6443
  cidr_blocks       = ["0.0.0.0/0"]
}

# --- Worker external inbound ---
resource "aws_security_group_rule" "worker_ssh" {
  type              = "ingress"
  security_group_id = aws_security_group.worker.id
  description       = "SSH"
  protocol          = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_blocks       = ["0.0.0.0/0"]
}
resource "aws_security_group_rule" "worker_https" {
  type              = "ingress"
  security_group_id = aws_security_group.worker.id
  description       = "App / HTTPS"
  protocol          = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_blocks       = ["0.0.0.0/0"]
}
resource "aws_security_group_rule" "worker_nodeport" {
  type              = "ingress"
  security_group_id = aws_security_group.worker.id
  description       = "NodePort Services (fortune app, Workshop 1)"
  protocol          = "tcp"
  from_port         = 30000
  to_port           = 32767
  cidr_blocks       = ["0.0.0.0/0"]
}

# --- Egress: allow all (both) ---
resource "aws_security_group_rule" "master_egress" {
  type              = "egress"
  security_group_id = aws_security_group.master.id
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = ["0.0.0.0/0"]
}
resource "aws_security_group_rule" "worker_egress" {
  type              = "egress"
  security_group_id = aws_security_group.worker.id
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = ["0.0.0.0/0"]
}

########################################################
# Instances: master + 2 workers (cluster forms automatically at boot)
#
# Differences from the week-6 cluster (clo835-cluster-iac), all needed by
# CLO835_Workshops_Lab_v1 (Workshop 2 uses EBS-backed PVCs + StatefulSets):
#   - LabInstanceProfile attached: the EBS CSI driver calls the EC2 API with
#     the node's LabRole credentials (Learner Lab forbids creating IAM roles,
#     but allows passing the existing LabRole/LabInstanceProfile).
#   - IMDS hop limit 2: CSI pods reach instance credentials through the
#     pod network (hop limit 1 would block IMDSv2 for pods).
#   - All nodes pinned to ONE subnet/AZ so EBS volumes always re-attach.
#   - Master user_data also installs the EBS CSI driver, creates the gp2
#     StorageClass, and stages the lab manifests in /home/ubuntu/week10/.
########################################################
resource "aws_instance" "master" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "m5.large" # 2 vCPU / 8 GB (steady, non-burstable)
  key_name               = var.key_name
  subnet_id              = local.lab_subnet_id
  vpc_security_group_ids = [aws_security_group.master.id]
  iam_instance_profile   = var.lab_instance_profile

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = 32
  }

  # bootstrap.sh (prereqs) + templated kubeadm init + lab manifest staging
  user_data = "${file("${path.module}/bootstrap.sh")}\n${templatefile("${path.module}/master-init.sh.tftpl", { k8s_token = local.k8s_token })}\n${local.stage_manifests}"

  tags = {
    Name = "week10-k8s-master"
  }
}

resource "aws_instance" "worker" {
  count                  = 2
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "m5.large"
  key_name               = var.key_name
  subnet_id              = local.lab_subnet_id
  vpc_security_group_ids = [aws_security_group.worker.id]
  iam_instance_profile   = var.lab_instance_profile

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = 32
  }

  # bootstrap.sh (prereqs) + templated kubeadm join (waits/retries until the master API is up)
  user_data = "${file("${path.module}/bootstrap.sh")}\n${templatefile("${path.module}/worker-join.sh.tftpl", {
    k8s_token = local.k8s_token
    master_ip = aws_instance.master.private_ip
    node_name = "workernode${count.index + 1}"
  })}"

  tags = {
    Name = "week10-k8s-worker-${count.index + 1}"
  }
}

output "public_ips" {
  value = merge(
    { master = aws_instance.master.public_ip },
    { for i, w in aws_instance.worker : "worker-${i + 1}" => w.public_ip }
  )
}

output "private_ips" {
  value = merge(
    { master = aws_instance.master.private_ip },
    { for i, w in aws_instance.worker : "worker-${i + 1}" => w.private_ip }
  )
}

output "next_step" {
  value = "ssh -i <your-key.pem> ubuntu@${aws_instance.master.public_ip}   # then: kubectl get nodes && ls ~/week10"
}
