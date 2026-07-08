#!/bin/bash
# CLO835 — Week 10 lab commands (CLO835_Workshops_Lab_v1.pptx, adapted from
# EKS/Cloud9 to the self-forming kubeadm cluster built by this Terraform).
#
# Run these ON THE MASTER, section by section, alongside the slides.
# Do NOT run the whole file at once.
#
# Everything the deck's eksctl/Cloud9 steps used to provide is already done:
#   - 3-node kubeadm v1.31 cluster (Flannel CNI)          <- replaces `eksctl create cluster -f eks_config.yaml`
#   - AWS EBS CSI driver installed                        <- replaces `eksctl create addon aws-ebs-csi-driver ... LabRole`
#   - StorageClass gp2 created (NOT default — you patch it in Workshop 2 Part 3)
#   - Lab manifests staged in ~/week10/
#
# alias k=kubectl   # optional, matches the slides

########################################################
# 0) Verify the cluster (slides: "Cluster is ready")
########################################################
kubectl get nodes -o wide            # masternode + workernode1 + workernode2, all Ready
kubectl get pods -n kube-system      # control plane + coredns + kube-proxy + ebs-csi-* pods Running
kubectl get pods -n kube-flannel     # flannel runs in its OWN namespace — one pod per node
kubectl get sc                       # kubectl get storageclass - gp2 exists (no "(default)" marker yet — that's Part 3)
ls ~/week10                          # the lab manifests

########################################################
# WORKSHOP 1 · Part A — Kubernetes Dashboard
# (deck says DASHBOARD_VERSION=v2.0.0 — that release predates K8s v1.31; use v2.7.0)
########################################################
export DASHBOARD_VERSION="v2.7.0"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/${DASHBOARD_VERSION}/aio/deploy/recommended.yaml
kubectl get all -n kubernetes-dashboard

kubectl apply -f ~/week10/dashboard-adminuser.yaml
kubectl -n kubernetes-dashboard create token admin-user     # copy the token

# Cloud9's "Preview Running Application" is replaced by an SSH tunnel.
# On your LAPTOP, in a NEW terminal:
#   ssh -i your-key.pem -L 8001:127.0.0.1:8001 ubuntu@<MASTER_PUBLIC_IP>
# Then, on the master:
kubectl proxy
# Browse (on your laptop):
#   http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/
# Sign in with the token. Ctrl-C the proxy when done.

########################################################
# WORKSHOP 1 · Part B — fortune app (two containers, shared emptyDir)
########################################################
kubectl create ns week8
kubectl apply -f ~/week10/fortune_pod.yaml -n week8
kubectl get all -n week8

kubectl port-forward fortune 8080:80 -n week8     # leave running; use a 2nd SSH session

ssh -i key.pem -L 8080:127.0.0.1:8080 ubuntu@IP

curl http://localhost:8080                        # a fortune; repeat after ~10s — it changes

kubectl exec fortune -it -n week8 -c web-server -- sh
#   cat /usr/share/nginx/html/index.html
#   vi  /usr/share/nginx/html/index.html
#   -> the write FAILS. Why? (hint: look at the volumeMounts in fortune_pod.yaml)
#   exit

# Expose via NodePort — the security group already opens 30000-32767.
kubectl expose pod fortune -n week8 --type NodePort --name fortune
kubectl get svc -n week8                          # note the 3xxxx port
# Browse http://<WORKER-1-PUBLIC-IP>:<NODEPORT> and http://<WORKER-2-PUBLIC-IP>:<NODEPORT>
# Both respond, and the pod runs on only ONE node. Why?
# 

# Because in fortune_pod.yaml, the web-server container mounts the shared volume with readOnly: true:
# 
# - name: html
#   mountPath: /usr/share/nginx/html
#   readOnly: true
# 
# So nginx can serve the files but nothing inside that container can write them — vi's save fails with a read-only filesystem error.
# The same volume is mounted writable in the other container (html-generator at /var/htdocs), which is why the fortunes keep updating.
# One volume, two mounts, two permissions: the generator writes, the web server only reads.


# Expose via LoadBalancer — observe what happens WITHOUT a cloud LB controller.
kubectl delete service fortune -n week8
kubectl expose pod fortune -n week8 --type LoadBalancer --name fortune
kubectl get svc -n week8                          # EXTERNAL-IP stays <pending>
# On EKS this provisioned an ELB. kubeadm has no cloud load-balancer integration,
# so LoadBalancer never completes here — NodePort is the external option. (Week 6 lecture!)
kubectl delete service fortune -n week8

########################################################
# WORKSHOP 2 · Part 1 — hostPath volume (MongoDB)
########################################################
kubectl create ns week9
kubectl apply -f ~/week10/mongodb_hostpath.yaml -n week9
kubectl get pods -o wide -n week9                 # NOTE which worker it landed on

kubectl exec -it mongodb -n week9 -- mongosh
#   use mystore
#   db.foo.insertOne({name:'foo'})
#   db.foo.find()
#   exit

kubectl delete pod mongodb -n week9
kubectl apply -f ~/week10/mongodb_hostpath.yaml -n week9
kubectl get pods -o wide -n week9                 # same node as before, or the other one?
kubectl exec -it mongodb -n week9 -- mongosh
#   use mystore
#   db.foo.find()
#   -> data is there ONLY if the pod landed on the same node: hostPath is node-local.
#   exit

########################################################
# WORKSHOP 2 · Part 2 — PV/PVC on Amazon EBS (redis)
# (the deck's `eksctl create addon aws-ebs-csi-driver ... LabRole` step is
#  already done by Terraform — the driver runs in kube-system)
########################################################
kubectl get sc
kubectl apply -f ~/week10/redis_service.yaml -n week9
kubectl apply -f ~/week10/redis_pvc.yaml -n week9
kubectl get pvc -n week9                          # Pending — WaitForFirstConsumer
kubectl apply -f ~/week10/redis_deployment.yaml -n week9
kubectl get pvc,pods -n week9                     # PVC Bound: a real EBS volume now exists
kubectl get pv

kubectl run redis-cli --rm -ti --image=redis:3.2.5 --restart=Never -n week9 -- /bin/sh
#   redis-cli -h redis.week9.svc.cluster.local
#   set foo bar
#   get foo
#   quit  /  exit

kubectl delete pod -l app=redis -n week9          # kill the redis pod
kubectl get pods -n week9 -o wide                 # recreated (maybe on the other worker)

kubectl run redis-cli --rm -ti --image=redis:3.2.5 --restart=Never -n week9 -- /bin/sh
#   redis-cli -h redis.week9.svc.cluster.local
#   get foo
#   -> "bar". The EBS volume followed the pod. Data persists independent of the node.
#   exit

########################################################
# WORKSHOP 2 · Part 3 — StatefulSets (kubia)
########################################################
# Make gp2 the DEFAULT StorageClass: PVCs that don't name a class (like the
# kubia StatefulSet's volumeClaimTemplates below) will now get gp2 automatically.
kubectl patch storageclass gp2 -p \
  '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
kubectl get sc                                    # gp2 is now "(default)"

kubectl create -f ~/week10/kubia-statefulset.yaml
kubectl get po -w                                 # kubia-0 first, THEN kubia-1 — one at a time (Ctrl-C)
kubectl get pvc,pv                                # one PVC/EBS volume PER pod

kubectl proxy &                                   # port 8001, on the master
curl localhost:8001/api/v1/namespaces/default/pods/kubia-0/proxy/
curl -X POST -d "Hey there! This greeting was submitted to kubia-0." \
     localhost:8001/api/v1/namespaces/default/pods/kubia-0/proxy/
curl localhost:8001/api/v1/namespaces/default/pods/kubia-0/proxy/
curl localhost:8001/api/v1/namespaces/default/pods/kubia-1/proxy/     # kubia-1 has its OWN data

kubectl delete po kubia-0
kubectl get po                                    # recreated with the SAME name: kubia-0
curl localhost:8001/api/v1/namespaces/default/pods/kubia-0/proxy/     # same data — PV re-attached

kubectl create -f ~/week10/kubia-clusterIP.yaml
curl localhost:8001/api/v1/namespaces/default/services/kubia-public/proxy/   # random pod each time

# Peer discovery via a HEADLESS service + DNS SRV records
kubectl apply -f ~/week10/kubia-headless.yaml
kubectl run -it dnstest-alpine --image=alpine/curl --rm --restart=Never -- /bin/ash
#   apk update && apk add bind-tools
#   dig SRV kubia.default.svc.cluster.local        # one record per pod
#   exit

# Turn the pods into a clustered data store
kubectl edit statefulset kubia                     # change image to: luksa/kubia-pet-peers
kubectl get po                                     # pods roll one by one to the new image

curl -X POST -d "The sun is shining" \
     localhost:8001/api/v1/namespaces/default/services/kubia-public/proxy/
curl -X POST -d "The rain is raining" \
     localhost:8001/api/v1/namespaces/default/services/kubia-public/proxy/
curl localhost:8001/api/v1/namespaces/default/services/kubia-public/proxy/
# Run the GET a few times: every pod now returns data gathered from ALL pods (SRV discovery).

########################################################
# CLEANUP — order matters: PVCs first (they own real EBS volumes), destroy last
########################################################
pkill -f 'kubectl proxy'
kubectl delete -f https://raw.githubusercontent.com/kubernetes/dashboard/${DASHBOARD_VERSION}/aio/deploy/recommended.yaml
unset DASHBOARD_VERSION

kubectl delete ns week8 week9                     # deletes redis PVC -> its EBS volume
kubectl delete statefulset kubia
kubectl delete svc kubia kubia-public
kubectl delete pvc data-kubia-0 data-kubia-1      # releases the StatefulSet EBS volumes
kubectl get pv                                    # wait until this list is EMPTY

# Then, on your LAPTOP, from the week10_lab folder:
#   terraform destroy          # stops the $50 Learner Lab meter
# (If `kubectl get pv` was not empty, delete the leftover PVCs first —
#  terraform does not know about CSI-created EBS volumes and will NOT remove them.)
