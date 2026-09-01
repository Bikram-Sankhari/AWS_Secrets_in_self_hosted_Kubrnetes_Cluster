
  

# Secure AWS Secrets Manager Access from a Self-Managed K3s Cluster (IRSA without EKS)

<img src="https://cdn.simpleicons.org/youtube/FF0000" width="20" height="20" alt="YouTube"/> [Watch the Full Walkthrough on YouTube](https://www.youtube.com/watch?v=YOUR_VIDEO_ID)

This repo documents and contains the manifests for a working setup that lets pods

  

running on a **self-managed Kubernetes cluster** securely fetch secrets from

  

**AWS Secrets Manager** — without ever storing a long-lived AWS access key anywhere in the cluster.

  

  

It replicates the same identity federation pattern EKS gives you for free via **IRSA (IAM Roles for Service Accounts)**, but built from scratch on a plain k3s cluster with no managed control plane.

  

  

## Why this exists

  

  

The naive way to call AWS from a pod is to bake a static IAM access key into an environment variable or Kubernetes Secret. That works, but it means:

  

  

- A permanent credential sits inside the cluster, on disk, in memory, in logs.

  

- If it leaks, it's valid until someone manually notices and revokes it.

  

- It has to be manually rotated and redistributed to every pod using it.

  

  

This project instead uses **OIDC federation**: the cluster proves a pod's identity with a short-lived, auto-rotating, cryptographically signed token, and AWS exchanges that token for temporary credentials scoped to exactly one IAM role. No static AWS credential ever

  

exists inside the cluster.

  

  

## How it works, end to end

  

  

```

  

Pod (secrets-reader-sa)

  

│

  

│ 1. Kubelet mounts a short-lived, auto-rotating JWT

  

│ (projected service account token, aud=sts.amazonaws.com)

  

▼

  

AWS Secrets & Configuration Provider (ASCP) + Secrets Store CSI Driver

  

│

  

│ 2. Calls sts:AssumeRoleWithWebIdentity, presenting the JWT

  

▼

  

AWS STS

  

│

  

│ 3. Verifies the JWT's signature against the cluster's public JWKS

  

│ (fetched from https://oidc.<your-domain>/openid/v1/jwks)

  

│ 4. Checks the IAM role's trust policy (issuer + aud + sub conditions)

  

│ 5. Issues temporary credentials scoped to the assumed role

  

▼

  

AWS Secrets Manager

  

│

  

│ 6. ASCP uses the temporary credentials to fetch the secret

  

▼

  

Secret mounted as a file inside the pod

  

```

  

  

### The pieces that make this possible

  

  

| Component | Role |

  

|---|---|

  

| **kube-apiserver flags** (`--service-account-issuer`, `--service-account-signing-key-file`, `--service-account-key-file`, `--api-audiences`) | Turns the cluster's own API server into an OIDC identity provider, signing service account tokens |

  

| **Public HTTPS endpoint** (`oidc.<your-domain>`) | Exposes the cluster's `/.well-known/openid-configuration` and `/openid/v1/jwks` so AWS STS can verify token signatures |

  

| **IAM OIDC Identity Provider** | Registers the cluster's OIDC endpoint as a trusted issuer in AWS IAM |

  

| **IAM Role + trust policy** | Grants `secretsmanager:GetSecretValue` on a specific secret, restricted via `sub` condition to one exact Kubernetes ServiceAccount |

  

| **ServiceAccount** (annotated with `eks.amazonaws.com/role-arn`) | Declares which pods are allowed to assume which IAM role |

  

| **Pod Identity Webhook** (`amazon-eks-pod-identity-webhook`) | Mutating admission webhook — on self-managed clusters, this is the piece EKS normally provides for you. Injects `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE`, and the projected token volume into any pod using an annotated ServiceAccount |

  

| **cert-manager** | Issues and auto-rotates the TLS certificate the webhook uses to serve its admission endpoint |

  

| **Secrets Store CSI Driver + AWS provider (ASCP)** | Reads the injected token, calls STS, then Secrets Manager, and mounts the result as a file in the pod |

  

| **SecretProviderClass** | Declares which secret(s) to fetch and how to expose them |

  

  

## Prerequisites

  

  

- An AWS account
- A domain you control (for the public OIDC endpoint)
- An SSL Certificate for the domain

  
  
  

  

## Setup summary

  

  

1.  **Setup a Kubernetes Cluster** - with the following flags:

\- -service-account-issuer=`https://oidc.<your-domain>`

\- -service-account-signing-key-file=`/path/to/your/private.key`

\- -service-account-key-file= `path/to/your/public.key`

\- -api-audiences=sts.amazonaws.com

2.  **Expose the OIDC endpoint** publicly — serve the discovery document at `/.well-known/openid-configuration` and

  

public keys at `/openid/v1/jwks`

  

over a trusted TLS certificate.

  

3.  **Register the OIDC provider in IAM** (Identity providers → Add provider → OpenID Connect), audience `sts.amazonaws.com`.

  

4.  **Create an IAM policy** scoped to `secretsmanager:GetSecretValue` on the specific secret ARN.

  

5.  **Create an IAM role** trusting the OIDC provider, with the policy attached, and atrust policy `sub` condition locked to one Kubernetes ServiceAccount.

  

6.  **Create the ServiceAccount** in-cluster, annotated with the role ARN.

  

7.  **Install cert-manager**, then the **pod identity webhook** (`make cluster-up` from the AWS repo).

  

8.  **Install the Secrets Store CSI Driver** and the **AWS provider (ASCP)** via Helm.

  

9.  **Create a `SecretProviderClass`** naming the secret to fetch.

  

10.  **Run a pod** using the annotated ServiceAccount and the CSI volume — the secret

  

appears as a file at the configured mount path.

  

  

## Verifying it works

  

  

```bash

  

# Confirm the webhook injected the right env vars / volume

  

kubectl get  pod <pod-name> -o  yaml | grep -A5  "AWS_ROLE_ARN\|AWS_WEB_IDENTITY_TOKEN_FILE"

  

  

# Confirm the full identity chain works end to end

  

kubectl exec <pod-name> --  aws  sts  get-caller-identity

  

  

# Confirm the secret is actually mounted

  

kubectl exec <pod-name> --  cat  /mnt/secrets/<secret-name>

  

```

  

  

## Notes on running this on k3s specifically (vs. EKS/kOps)

  

  

- k3s embeds `kube-apiserver`, `kube-scheduler`, and `kube-controller-manager` **inside

  

a single process** — there are no separate static pods to inspect the way there are on

  

kubeadm/kOps clusters. Flags are verified via `journalctl -u k3s.service`, not

  

`kubectl describe pod` in `kube-system`.

  

- k3s does **not** run a cloud-aware `cloud-controller-manager` by default, so a

  

`Service` of `type: LoadBalancer` will **not** provision a real AWS ELB — k3s's

  

built-in **ServiceLB** simulates it by binding the port directly on the node's host IP.

  

A real AWS load balancer requires installing the AWS Cloud Controller Manager (for

  

`Service: LoadBalancer`) or AWS Load Balancer Controller (for `Ingress`) separately.

  

- The pod identity webhook install method changed upstream from a manual

  

CSR-approval shell script to a **cert-manager-based `make cluster-up`** — cert-manager

  

is a hard prerequisite for the current install path.

  

- The AWS provider (ASCP) needs to resolve its AWS region; if the node is missing the

  

standard `topology.kubernetes.io/region` label (which k3s doesn't set by default,

  

unlike EKS), label the node manually rather than hardcoding the region.

  

  

## Security notes

  

  

- The `sub` condition in the IAM trust policy is what scopes access to **one specific

  

ServiceAccount** rather than any pod in the cluster — never omit it.

  

- The cluster's service-account signing key never leaves the cluster; only its **public** half is ever exposed, via the JWKS endpoint.

  

- Tokens are short-lived (default 24h in this setup) and auto-rotated by the kubelet — there is no long-lived credential to leak or manually rotate.
