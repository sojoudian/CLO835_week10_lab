#!/bin/bash
# CLO835 Week 10 — kubeadm node prerequisites (runs on EVERY node).
# Terraform runs this automatically at boot (as root) via user_data.
# To run by hand on a node: sudo bash bootstrap.sh
set -euxo pipefail

# 1. Turn swap off (kubelet requires it)
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

# 2. Kernel modules + sysctls for the pod network
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat >/etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# 3. containerd, configured with the systemd cgroup driver
#    (git is needed on the master: kubectl kustomize fetches the EBS CSI driver from GitHub)
apt-get update
apt-get install -y containerd apt-transport-https ca-certificates curl gpg git conntrack socat ethtool htop
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# 4. kubeadm / kubelet / kubectl (Kubernetes v1.31)
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /" \
  >/etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet

echo "Prerequisites installed."
