#!/usr/bin/env bash
# End-to-end setup: terraform apply -> configure kubectl -> build/push images ->
# create per-app databases on the shared RDS instance -> create k8s secrets ->
# deploy every app -> install the AWS Load Balancer Controller and Ingresses ->
# print next steps.
#
# Requires: terraform, aws cli (configured), kubectl, docker, helm.
# RDS has no public access, so per-app databases are created via a short-lived
# pod running inside the cluster (the only thing allowed to reach RDS:5432).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"
APPS=(ecommerce banking food-delivery student-portal support-tickets)

echo "==> Preflight checks"

missing_tools=()
for tool in terraform aws kubectl docker helm envsubst nslookup; do
  command -v "$tool" >/dev/null 2>&1 || missing_tools+=("$tool")
done
if [ "${#missing_tools[@]}" -gt 0 ]; then
  echo "Missing required tool(s): ${missing_tools[*]} -- see Prerequisites in README.md." >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon isn't running (or isn't reachable) -- start it and re-run." >&2
  exit 1
fi

if ! CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null); then
  echo "AWS CLI isn't authenticated -- run 'aws configure' (or set up SSO) and re-run." >&2
  exit 1
fi
echo "    AWS identity: ${CALLER_ARN}"
case "$CALLER_ARN" in
  *:root)
    echo "    Running as the AWS account root user -- terraform/eks.tf's caller_is_root guard" \
         "handles this automatically, no extra steps needed." ;;
esac

if [ ! -f "$TF_DIR/terraform.tfvars" ]; then
  echo "terraform/terraform.tfvars not found. Run:" >&2
  echo "  cp terraform/terraform.tfvars.example terraform/terraform.tfvars" >&2
  echo "then edit it to set dns_zone_name, and re-run." >&2
  exit 1
fi

DNS_ZONE_NAME=$(grep -E '^\s*dns_zone_name\s*=' "$TF_DIR/terraform.tfvars" | sed -E 's/.*"([^"]+)".*/\1/')
if [ -z "$DNS_ZONE_NAME" ] || [ "$DNS_ZONE_NAME" = "example.com" ]; then
  echo "terraform/terraform.tfvars still has the placeholder dns_zone_name -- set it to your real" >&2
  echo "Route 53 hosted zone domain and re-run." >&2
  exit 1
fi

ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$DNS_ZONE_NAME" \
  --query "HostedZones[?Name=='${DNS_ZONE_NAME}.'].Id" --output text | head -n1)
if [ -z "$ZONE_ID" ]; then
  echo "No public Route 53 hosted zone found for '${DNS_ZONE_NAME}' in this AWS account." >&2
  echo "Create one (or point dns_zone_name at a domain that already has one) -- see Prerequisites" >&2
  echo "in README.md." >&2
  exit 1
fi

# Terraform only ever creates records *inside* this hosted zone -- it never
# touches the domain's registrar-level NS delegation. If that delegation
# doesn't point at this zone's nameservers, the 5 app URLs will never
# resolve publicly no matter how correctly everything else deploys. Catch
# that here, before spending ~20 minutes and real money finding out the
# hard way.
ROUTE53_NS=$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --query "ResourceRecordSets[?Type=='NS'].ResourceRecords[].Value" --output text \
  | tr '\t' '\n' | sed 's/\.$//' | sort)
PUBLIC_NS=$(nslookup -type=NS "$DNS_ZONE_NAME" 8.8.8.8 2>/dev/null \
  | awk '/nameserver =/{print $NF}' | sed 's/\.$//' | sort)

if [ -z "$PUBLIC_NS" ] || [ "$ROUTE53_NS" != "$PUBLIC_NS" ]; then
  echo "" >&2
  echo "WARNING: '${DNS_ZONE_NAME}' does not appear to be delegated to this Route 53 hosted zone." >&2
  echo "  This hosted zone's nameservers:" >&2
  echo "$ROUTE53_NS" | sed 's/^/    /' >&2
  echo "  What the public internet currently sees for ${DNS_ZONE_NAME}:" >&2
  echo "${PUBLIC_NS:-<no answer -- domain may not be registered/delegated at all>}" | sed 's/^/    /' >&2
  echo "  Infra will still deploy fine either way -- but the 5 app URLs won't resolve publicly" >&2
  echo "  until this is fixed at your domain's registrar (update its NS records to match the" >&2
  echo "  list above)." >&2
  echo "" >&2
  read -r -p "Continue anyway? [y/N] " reply
  case "$reply" in
    [Yy]*) ;;
    *) echo "Aborted. Fix NS delegation (or pick a different dns_zone_name) and re-run." >&2; exit 1 ;;
  esac
fi

echo "==> 1/8 terraform apply"
cd "$TF_DIR"
terraform init -input=false
terraform apply -auto-approve

CLUSTER_NAME=$(terraform output -raw cluster_name)
REGION=$(terraform output -raw region)
VPC_ID=$(terraform output -raw vpc_id)
RDS_ADDRESS=$(terraform output -raw rds_address)
RDS_PORT=$(terraform output -raw rds_port)
RDS_MASTER_USER=$(terraform output -raw rds_master_username)
RDS_MASTER_PASSWORD=$(terraform output -raw rds_master_password)
ALB_CONTROLLER_ROLE_ARN=$(terraform output -raw alb_controller_role_arn)
LAB_DOMAIN=$(terraform output -raw lab_domain)
CERT_ARN=$(terraform output -raw acm_certificate_arn)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
echo "$LAB_DOMAIN" > "$REPO_ROOT/.lab-domain"

echo "==> 2/8 configure kubectl"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

echo "==> 3/8 build and push images to ECR"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"

IMAGE_TAG="$(date +%Y%m%d%H%M%S)"
for app in "${APPS[@]}"; do
  for part in backend frontend; do
    image="sre-lab/${app}-${part}"
    echo "    building ${image}:${IMAGE_TAG}"
    docker build --platform linux/amd64 -t "${ECR_REGISTRY}/${image}:${IMAGE_TAG}" "$REPO_ROOT/apps/${app}/${part}"
    docker push "${ECR_REGISTRY}/${image}:${IMAGE_TAG}"
  done
done

echo "==> 4/8 create namespaces"
kubectl apply -f "$REPO_ROOT/namespaces/"

echo "==> 5/8 create per-app databases on shared RDS instance"
for app in "${APPS[@]}"; do
  db_name="${app//-/_}_db"
  db_user="${app//-/_}_app"
  db_password=$(openssl rand -hex 16)

  echo "    provisioning ${db_name} / ${db_user}"
  {
    echo "SELECT 'CREATE DATABASE ${db_name}' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${db_name}')\\gexec"
    echo "DO \$\$ BEGIN CREATE ROLE ${db_user} WITH LOGIN PASSWORD '${db_password}'; EXCEPTION WHEN duplicate_object THEN ALTER ROLE ${db_user} WITH PASSWORD '${db_password}'; END \$\$;"
    echo "GRANT ALL PRIVILEGES ON DATABASE ${db_name} TO ${db_user};"
  } | kubectl run "pg-init-${app}" --rm -i --restart=Never -n "$app" \
      --image=postgres:17-alpine --env="PGPASSWORD=${RDS_MASTER_PASSWORD}" \
      --command -- psql -h "$RDS_ADDRESS" -U "$RDS_MASTER_USER" -d postgres -v ON_ERROR_STOP=1 -f -

  cat "$REPO_ROOT/apps/${app}/backend/sql/init.sql" | kubectl run "pg-schema-${app}" --rm -i --restart=Never -n "$app" \
      --image=postgres:17-alpine --env="PGPASSWORD=${RDS_MASTER_PASSWORD}" \
      --command -- psql -h "$RDS_ADDRESS" -U "$RDS_MASTER_USER" -d "$db_name" -v ON_ERROR_STOP=1 -f -

  echo "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${db_user}; GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${db_user};" \
    | kubectl run "pg-grant-${app}" --rm -i --restart=Never -n "$app" \
      --image=postgres:17-alpine --env="PGPASSWORD=${RDS_MASTER_PASSWORD}" \
      --command -- psql -h "$RDS_ADDRESS" -U "$RDS_MASTER_USER" -d "$db_name" -v ON_ERROR_STOP=1 -f -

  kubectl create secret generic "${app}-db-credentials" -n "$app" \
    --from-literal=PGHOST="$RDS_ADDRESS" \
    --from-literal=PGPORT="$RDS_PORT" \
    --from-literal=PGDATABASE="$db_name" \
    --from-literal=PGUSER="$db_user" \
    --from-literal=PGPASSWORD="$db_password" \
    --dry-run=client -o yaml | kubectl apply -f -
done

echo "==> 6/8 deploy food-delivery redis"
kubectl apply -f "$REPO_ROOT/apps/food-delivery/redis/deployment.yaml"

echo "==> 7/8 deploy all apps"
for app in "${APPS[@]}"; do
  k8s_dir="$REPO_ROOT/apps/${app}/k8s"
  for manifest in "$k8s_dir"/*.yaml; do
    ECR_REGISTRY="$ECR_REGISTRY" IMAGE_TAG="$IMAGE_TAG" envsubst '${ECR_REGISTRY} ${IMAGE_TAG}' < "$manifest" | kubectl apply -f -
  done
done

echo "==> 8/8 install the AWS Load Balancer Controller, apply Ingress, and create DNS records"
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set region="$REGION" \
  --set vpcId="$VPC_ID" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ALB_CONTROLLER_ROLE_ARN" \
  --wait --timeout=5m

for manifest in "$REPO_ROOT"/ingress/*.yaml; do
  LAB_DOMAIN="$LAB_DOMAIN" CERT_ARN="$CERT_ARN" envsubst '${LAB_DOMAIN} ${CERT_ARN}' < "$manifest" | kubectl apply -f -
done

echo ""
echo "==> Waiting for the ALB to come up (can take a couple of minutes on a fresh cluster)..."
for i in $(seq 1 30); do
  ALB_HOST=$(kubectl -n ecommerce get ingress ecommerce -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [ -n "$ALB_HOST" ] && break
  sleep 10
done

if [ -z "$ALB_HOST" ]; then
  echo "ALB hostname didn't appear in time -- check 'kubectl -n ecommerce describe ingress ecommerce' and re-run this script."
  exit 1
fi

# The Route 53 alias records (dns.tf) look the ALB up by tag, which only
# works once it exists -- that's why create_dns_records defaults to false on
# the terraform apply in step 1 and only gets turned on here.
echo "==> Creating Route 53 DNS records for the ALB (*.${LAB_DOMAIN})"
cd "$TF_DIR"
terraform apply -auto-approve -var="create_dns_records=true"
cd "$REPO_ROOT"

echo ""
echo "================================================================"
echo " Setup complete."
echo "================================================================"
echo "All 5 apps share this one ALB (routed by hostname via an IngressGroup)."
echo "DNS is live in Route 53 -- these URLs work immediately, no manual step:"
echo ""
echo "  https://ecommerce.${LAB_DOMAIN}"
echo "  https://banking.${LAB_DOMAIN}"
echo "  https://food-delivery.${LAB_DOMAIN}"
echo "  https://student-portal.${LAB_DOMAIN}"
echo "  https://support-tickets.${LAB_DOMAIN}"
echo ""
echo "Next: install the Datadog Agent with your own API key -- see docs/student-guide.md."
