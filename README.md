# CLO835 — Week 10 lab: Kubernetes cluster on AWS for the Workshops Lab

Infrastructure-as-code for **`CLO835_Workshops_Lab_v1.pptx`** (Workshop 1: Dashboard + the
two-container *fortune* app on an emptyDir volume; Workshop 2: hostPath → EBS-backed
PV/PVC → StatefulSets).

The original deck ran on **Cloud9 + EKS (`eksctl`)**. Cloud9 is no longer available to new
AWS accounts, so — exactly like the Week 6 lab — this Terraform builds a **3-node kubeadm
cluster** (1 control plane + 2 workers) on AWS Academy Learner Lab EC2 instances instead.
The cluster forms itself at boot: no manual `kubeadm init`/`join`, and **everything the
deck's eksctl steps used to provide is pre-installed**, so students only follow the
workshop commands.

## What `terraform apply` sets up (≈3–5 minutes)

| Requirement in the deck | How this Terraform provides it |
|---|---|
| A Kubernetes cluster (`eksctl create cluster -f eks_config.yaml`) | 3× m5.large, Ubuntu 24.04, kubeadm **v1.31**, Flannel CNI, self-forming |
| EBS storage driver (`eksctl create addon aws-ebs-csi-driver --service-account-role-arn …/LabRole`) | **AWS EBS CSI driver** installed at boot; nodes carry **LabInstanceProfile** (LabRole) so the driver can create/attach EBS volumes |
| `gp2` StorageClass to patch as default (Workshop 2, Part 3) | StorageClass `gp2` (provisioner `ebs.csi.aws.com`, gp3 volumes) created at boot — **not** default, so the `kubectl patch` step still belongs to the students |
| The lab YAMLs (`fortune_pod.yaml`, `mongodb_hostpath.yaml`, `redis_*.yaml`, `kubia-*.yaml`, `dashboard-adminuser.yaml`) | Staged automatically in **`/home/ubuntu/week10/`** on the master (source: [`manifests/`](manifests/)) |
| NodePort access from a browser (fortune app) | Worker security group opens **30000–32767** — no AWS console changes needed |
| Cloud9's dashboard preview | Replaced by an SSH tunnel: `ssh -i your-key.pem -L 8001:127.0.0.1:8001 ubuntu@<MASTER_IP>` |

Extra plumbing (invisible to students, required for EBS volumes on a self-managed cluster):
all three nodes are pinned to **one subnet/AZ** (EBS can't attach across AZs) and the IMDS
hop limit is **2** (so CSI pods can use the node's LabRole credentials).

## Prerequisites

- AWS Academy Learner Lab access — sign in at <https://www.awsacademy.com/vforcesite/LMS_Login>
- An EC2 **key pair** in the Learner Lab (AWS Console → EC2 → Key Pairs), `.pem` downloaded
- On your laptop: AWS CLI v2, Terraform, Git

## 1. Get your AWS credentials

In the Learner Lab page: **Start Lab**, wait for the green dot, then
**AWS Details → AWS CLI → Show**. Copy the whole `[default]` block into
`~/.aws/credentials`, and set `region = us-east-1` in `~/.aws/config`.

> Credentials rotate every session (max ~4 h) — re-paste a fresh block each session.
> Verify with: `aws sts get-caller-identity`

## 2. Configure and apply

```bash
cd week10_lab
cp terraform.tfvars.example terraform.tfvars   # set key_name to YOUR key pair
chmod 400 your-key.pem

terraform init
terraform apply        # type yes; then wait ~3–5 min while the nodes self-configure
```

## 3. Verify, then run the lab

```bash
ssh -i your-key.pem ubuntu@<master public IP from terraform output>

kubectl get nodes -o wide          # masternode + workernode1 + workernode2, all Ready
kubectl get pods -n kube-system    # flannel + ebs-csi-* pods Running
ls ~/week10                        # the staged lab manifests
```

Then follow **`commands.sh`** section by section next to the slides
(`CLO835_Workshops_Lab_v1.pptx`). Deviations from the deck, all noted inline:

- Skip every `eksctl` command (cluster + addon already exist).
- `DASHBOARD_VERSION=v2.7.0` instead of the deck's `v2.0.0` (too old for K8s v1.31).
- Dashboard is viewed through the SSH tunnel above, not Cloud9's preview browser.
- The fortune **LoadBalancer** step is kept as a *negative* demo: without a cloud LB
  controller the service stays `<pending>` — reinforcing the Week 6 lesson that NodePort
  is the external option on kubeadm clusters.

## 4. Cleanup — order matters

```bash
# on the master: run the CLEANUP section of commands.sh
#   (deletes namespaces week8/week9 and the kubia PVCs -> releases the EBS volumes;
#    wait until `kubectl get pv` is EMPTY)

# then on your laptop:
terraform destroy      # stops the $50 Learner Lab meter
```

> **Why PVCs first:** the redis and kubia volumes are real EBS volumes created by the CSI
> driver at runtime. Terraform doesn't know they exist, so `terraform destroy` won't delete
> them — orphaned volumes keep billing the lab budget.

## Files

| File | Purpose |
|---|---|
| `main.tf` / `variables.tf` / `terraform.tfvars.example` | The infrastructure (SGs, 3 instances, LabInstanceProfile, single-AZ pinning) |
| `bootstrap.sh` | Every node: swap off, containerd, kubeadm/kubelet/kubectl v1.31 |
| `master-init.sh.tftpl` | Master: `kubeadm init` (pre-shared token), Flannel, **EBS CSI driver**, **gp2 StorageClass**, worker-labeling loop |
| `worker-join.sh.tftpl` | Workers: retry `kubeadm join` until the API answers |
| `manifests/*.yaml` | The workshop YAMLs — staged to `~/week10/` on the master at boot |
| `commands.sh` | The workshop commands, section by section, adapted from the deck |
