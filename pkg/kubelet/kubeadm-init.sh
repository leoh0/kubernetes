#!/bin/sh
set -e
touch /var/lib/kubeadm/.kubeadm-init.sh-started
if [ -f /etc/kubeadm/kubeadm.yaml ]; then
    echo Using the configuration from /etc/kubeadm/kubeadm.yaml
    if [ $# -ne 0 ] ; then
        echo WARNING: Ignoring command line options: $@
    fi
    kubeadm init --ignore-preflight-errors=all --config /etc/kubeadm/kubeadm.yaml
else
    # get host ip first
    IP=$(ip r | awk '/^default/{print $7}')

    # currently kubeadm can not support etcd config for http & nodeip
    # so make etcd file before starting kubeadm
    mkdir -p /etc/kubernetes/manifests/
    echo '''apiVersion: v1
kind: Pod
metadata:
  annotations:
    scheduler.alpha.kubernetes.io/critical-pod: ""
  creationTimestamp: null
  labels:
    component: etcd
    tier: control-plane
  name: etcd
  namespace: kube-system
spec:
  containers:
  - command:
    - etcd
    - --advertise-client-urls=http://CHANGE:2379
    - --listen-client-urls=http://CHANGE:2379
    - --data-dir=/var/lib/etcd
    image: k8s.gcr.io/etcd-amd64:3.1.12
    livenessProbe:
      exec:
        command:
        - /bin/sh
        - -ec
        - ETCDCTL_API=3 etcdctl --endpoints=CHANGE:2379
          get foo
      failureThreshold: 8
      initialDelaySeconds: 15
      timeoutSeconds: 15
    name: etcd
    resources: {}
    volumeMounts:
    - mountPath: /var/lib/etcd
      name: etcd-data
  hostNetwork: true
  volumes:
  - hostPath:
      path: /var/lib/etcd
      type: DirectoryOrCreate
    name: etcd-data
status: {}
''' > /etc/kubernetes/manifests/etcd.yaml
    sed -i "s/CHANGE/$IP/g" /etc/kubernetes/manifests/etcd.yaml

    # make kubeadm config
    echo '''apiVersion: kubeadm.k8s.io/v1alpha1
kind: MasterConfiguration
kubernetesVersion: @KUBERNETES_VERSION@
etcd:
  endpoints:
  - http://CHANGE:2379
tokenTTL: 0s
apiServerExtraArgs:
  endpoint-reconciler-type: lease
''' > /etc/kubernetes/kubeadm.yaml
    sed -i "s/CHANGE/$IP/g" /etc/kubernetes/kubeadm.yaml

    kubeadm init --ignore-preflight-errors=all $@ --config /etc/kubernetes/kubeadm.yaml
fi

# sorting by basename relies on the dirnames having the same number of directories
YAML=$(ls -1 /run/config/kube-system.init/*.yaml /etc/kubeadm/kube-system.init/*.yaml 2>/dev/null | sort --field-separator=/ --key=5)
for i in ${YAML}; do
    n=$(basename "$i")
    if [ -e "$i" ] ; then
      if [ ! -s "$i" ] ; then # ignore zero sized files
          echo "Ignoring zero size file $n"
          continue
      fi
      echo "Applying $n"

      # update etcd address for network configmap
      cp "$i" "/$n"
      sed -i "s/127.0.0.1:2379/$IP:2379/g" "/$n"
      if ! kubectl create -n kube-system -f "/$n" ; then
          touch /var/lib/kubeadm/.kubeadm-init.sh-kube-system.init-failed
          touch /var/lib/kubeadm/.kubeadm-init.sh-kube-system.init-"$n"-failed
          echo "Failed to apply $n"
          continue
      fi
    fi
done
if [ -f /run/config/kubeadm/untaint-master ] ; then
    echo "Removing \"node-role.kubernetes.io/master\" taint from all nodes"
    kubectl taint nodes --all node-role.kubernetes.io/master-
fi
touch /var/lib/kubeadm/.kubeadm-init.sh-finished
