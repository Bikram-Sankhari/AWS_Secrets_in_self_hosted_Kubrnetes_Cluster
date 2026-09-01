#!/bin/bash

# Copy keys from your loal machine to the EC2 instance (if applicable)
scp -i my-key-pair.pem Docker/K3s_Img/private.key ec2-user@<your-ec2-ip>:~
scp -i my-key-pair.pem Docker/K3s_Img/public.pub ec2-user@<your-ec2-ip>:~

# Get into the instance 
ssh -i my-key-pair.pem ec2-user@<your-ec2-ip>

# Install dependencies
sudo yum install git make python -y

# Generate RSA key pair for OIDC
openssl genrsa -out private.key 2048
openssl rsa -in private.key -pubout -out public.key

# Generate JWKS from the public key
python Generate_JWKS.py --public-key /home/ec2-user/public.key --output public-key.json

# Setup Kubernetes Cluster with OIDC configuration
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --write-kubeconfig-mode 644 \
  --kube-apiserver-arg=service-account-issuer=https://oidc.sankhari.shop \
  --kube-apiserver-arg=service-account-signing-key-file=/home/ec2-user/private.key \
  --kube-apiserver-arg=service-account-key-file=/home/ec2-user/public.key \
  --kube-apiserver-arg=api-audiences=sts.amazonaws.com" sh -

# Create Kubernetes Objects
kubectl apply -f oidc-discovery-configmap.yaml
kubectl apply -f oidc-jwks-configmap.yaml
kubectl apply -f oidc-nginx-config.yaml
kubectl apply -f oidc-nginx-deployment.yaml
kubectl apply -f oidc-nginx-service.yaml

# Create webhook for AWS EKS Pod Identity
git clone https://github.com/aws/amazon-eks-pod-identity-webhook.git

kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.21.1/cert-manager.yaml
make cluster-up IMAGE=amazon/amazon-eks-pod-identity-webhook:latest

# IDP Audience: sts.amazonaws.com

# Add this line in the AWS Role's json
# "oidc.sankhari.shop:sub": "system:serviceaccount:default:secrets-reader-sa"

# Install Helm
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
chmod 700 get_helm.sh
./get_helm.sh

# Install AWS Secrets Manager CSI Driver and ASCP
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

helm repo add aws-secrets-manager https://aws.github.io/secrets-store-csi-driver-provider-aws
helm install -n kube-system secrets-provider-aws aws-secrets-manager/secrets-store-csi-driver-provider-aws

kubectl apply -f secretproviderclass.yaml

# Finally See it working
kubectl apply -f secret-test-pod.yaml
kubectl exec -it secret-test-pod -- /bin/bash