#!/bin/bash

# update dynamic dns
echo -e "\nupdate dynamic dns"
curl -k "https://freedns.afraid.org/dynamic/update.php?${dyndns_api_key}"

# update system
echo -e "\nupdate system"
yum update -y

echo -e "\nsleep 20s\n"
sleep 20

# install k3s
echo -e "\ninstall k3s"
curl -sfL https://get.k3s.io | sh -

# install k9s
echo -e "\ninstall k9s"
wget -qO- https://github.com/derailed/k9s/releases/download/v0.24.14/k9s_Linux_x86_64.tar.gz \
  | tar xvzf - -C /usr/local/bin k9s \
  && chown 0:0 /usr/local/bin/k9s

# install helm3
echo -e "\ninstall helm3"
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

# configure kube config
echo -e "\nconfigure kube config"
mkdir -p /home/ec2-user/.kube /root/.kube
chown -R ec2-user:ec2-user /home/ec2-user/.kube
chown ec2-user:ec2-user /etc/rancher/k3s/k3s.yaml
ln -s /etc/rancher/k3s/k3s.yaml /home/ec2-user/.kube/config
ln -s /etc/rancher/k3s/k3s.yaml /root/.kube/config

# export kube config for automation
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# add helm repos
echo -e "\nadd helm repos"
helm repo add jetstack https://charts.jetstack.io \
&& helm repo add bitnami https://charts.bitnami.com/bitnami

echo -e "\nsleep 20s\n"
sleep 20

# create namespaces
echo -e "\ncreate namespaces"
kubectl create ns "${nginx_namespace}"
kubectl create ns cert-manager

# prepare cert-manager resource
echo -e "\nprepare cert-manager resource"
cat > /tmp/cert-manager-manifest.yaml <<-EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-production
spec:
  acme:
    # You must replace this email address with your own.
    # Let's Encrypt will use this to contact you about expiring
    # certificates, and issues related to your account.
    email: g@sim.mn
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      # Secret resource that will be used to store the account's private key.
      name: production-clusterissuer-account-key
    # Add a single challenge solver, HTTP01 using nginx
    solvers:
    - http01:
        ingress:
          serviceType: ClusterIP
          ingressTemplate:
            metadata:
              annotations:
                "kubernetes.io/ingress.class": "traefik"
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    # You must replace this email address with your own.
    # Let's Encrypt will use this to contact you about expiring
    # certificates, and issues related to your account.
    email: g@sim.mn
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      # Secret resource that will be used to store the account's private key.
      name: staging-clusterissuer-account-key
    # Add a single challenge solver, HTTP01 using nginx
    solvers:
    - http01:
        ingress:
          serviceType: ClusterIP
          ingressTemplate:
            metadata:
              annotations:
                "kubernetes.io/ingress.class": "traefik"
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${hostname}
  namespace: ${nginx_namespace}
spec:
  secretName: ${hostname}-tls
  duration: 2160h # 90d
  renewBefore: 360h # 15d
  subject:
    organizations:
      - henrithehare
    countries:
      - AU
    organizationalUnits:
      - Development
  commonName: ${hostname}
  dnsNames:
    - ${hostname}
  isCA: false
  privateKey:
    algorithm: ECDSA
    encoding: PKCS1
    size: 256
  usages:
    - "server auth"
  issuerRef:
    name: letsencrypt-production
    kind: ClusterIssuer
EOF

# deploy cert-manager
echo -e "\ndeploy cert-manager"
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --set installCRDs=true

echo -e "\nsleep 60s\n"
sleep 60

# provision let's encrypt certificate resources
echo -e "\nprovision let's encrypt certificate resources"
kubectl apply -f /tmp/cert-manager-manifest.yaml

# prepare traefik middleware resource for https redirection (ref: https://bit.ly/3y40iLa)
echo -e "\nprepare traefik middleware resource for https redirection (ref: https://bit.ly/3y40iLa)"
cat > /tmp/traefik-middleware.yaml <<-EOF
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: redirect
spec:
  redirectScheme:
    scheme: https
    permanent: true
EOF

# deploy traefik middleware resource for https redirection 
echo -e "\ndeploy traefik middleware resource for https redirection"
kubectl apply -f /tmp/traefik-middleware.yaml

# prepare nginx resource
echo -e "\nprepare nginx resource"
cat > /tmp/nginx-manifest.yaml <<-EOF
service:
  type: ClusterIP

ingress:
  enabled: true
  hostname: ${hostname}
  tls: true
  certManager: true
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"

staticSiteConfigmap: index-html-configmap

extraDeploy:
  - apiVersion: "{{ include \"common.capabilities.ingress.apiVersion\" . }}"
    kind: Ingress
    metadata:
      annotations:
        kubernetes.io/tls-acme: "true"
        meta.helm.sh/release-name: nginx
        meta.helm.sh/release-namespace: ${nginx_namespace}
        traefik.ingress.kubernetes.io/router.entrypoints: web
        traefik.ingress.kubernetes.io/router.middlewares: default-redirect@kubernetescrd
      labels:
        app.kubernetes.io/instance: nginx
        app.kubernetes.io/managed-by: Helm
        app.kubernetes.io/name: nginx
        helm.sh/chart: nginx-9.4.1
      name: nginx-redirect
    spec:
      rules:
      - host: ${hostname}
        http:
          paths:
          - backend:
              service:
                name: nginx
                port:
                  name: http
            path: /
            pathType: ImplementationSpecific
EOF

# deploy nginx resource
echo -e "\ndeploy nginx resource"
helm upgrade --install nginx bitnami/nginx \
  --values /tmp/nginx-manifest.yaml \
  --namespace "${nginx_namespace}"

# deploy website content
echo -e "\ndeploy website content"
curl -so /tmp/index.html "${static_html}" \
&& kubectl create configmap index-html-configmap \
  --from-file=/tmp/index.html \
  --namespace "${nginx_namespace}"
