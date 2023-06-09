#!/bin/bash -e

########################################
# Data Gathering

DEVSHELL_DEFAULT_PROJECT_ID="sk8s-$(echo "${USER}" | sed 's/[^a-z0-9-]//g')-${RANDOM}"
read -rp "Project ID [${DEVSHELL_DEFAULT_PROJECT_ID}]: " DEVSHELL_PROJECT_ID
if [ -z "${DEVSHELL_PROJECT_ID}" ]; then
	DEVSHELL_PROJECT_ID="${DEVSHELL_DEFAULT_PROJECT_ID}"
fi
export DEVSHELL_PROJECT_ID
export GOOGLE_PROJECT_ID="${DEVSHELL_PROJECT_ID}"

while true; do
	read -rp "Desired Webshell Password: " PASSWORD
	read -rp "Password (again): " secondpassword
	if [ -n "${PASSWORD}" -a "${secondpassword}" = "${PASSWORD}" ]; then
		unset secondpassword
		break
	else
		echo "Passwords do not match."
	fi
done


K8SPASSWORD=$(echo -n "${PASSWORD}" | base64)
K8SUSER=$(echo -n "${USER}" | base64)

########################################
# Project Setup
echo
echo "Deploying project..."
echo

gcloud projects create "${GOOGLE_PROJECT_ID}"

# Set the project in gcloud
gcloud config set project "${GOOGLE_PROJECT_ID}"

# Enable billing and containers with the first billing account
BILLING_ACCOUNT=$(gcloud beta billing accounts list --format json | jq -r '.[0].name')
gcloud beta billing projects link "${GOOGLE_PROJECT_ID}" --billing-account "${BILLING_ACCOUNT#billingAccounts/}"
gcloud services enable container.googleapis.com --project "${GOOGLE_PROJECT_ID}"

########################################
# Create a Cluster
echo
echo "Deploying cluster..."
echo

gcloud beta container --project "${GOOGLE_PROJECT_ID}" clusters create "${GOOGLE_PROJECT_ID}" \
       --zone "asia-northeast1-a" --no-enable-basic-auth --release-channel "rapid" --machine-type "n1-standard-2" \
       --preemptible --image-type "COS_CONTAINERD" --disk-type "pd-standard" --disk-size "20" \
       --metadata disable-legacy-endpoints=true \
       --scopes "https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/trace.append" \
       --num-nodes "1" \
       --logging=SYSTEM,API_SERVER,WORKLOAD --monitoring=SYSTEM,API_SERVER \
       --enable-ip-alias --default-max-pods-per-node "110" \
       --addons HorizontalPodAutoscaling,HttpLoadBalancing \
       --enable-autoupgrade --enable-autorepair

# let us access its NodePorts
gcloud compute firewall-rules create allow-vanity-ports --allow tcp:31300-31399 --project "${GOOGLE_PROJECT_ID}"

# Fetch the first cluster location
LOCATION="$(gcloud container clusters list --format='value(location)' | head -1 )"

# Fetch a valid kubeconfig
gcloud container clusters get-credentials --zone="${LOCATION}" "${GOOGLE_PROJECT_ID}"

########################################
# Apply the k8s config
#kubectl apply -f omnibus.yml
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: dashboard-secret
  namespace: dev
type: Opaque
data:
  username: $K8SUSER
  password: $K8SPASSWORD
---
apiVersion: v1
kind: Secret
metadata:
  name: dashboard-secret
  namespace: prd
type: Opaque
data:
  username: $K8SUSER
  password: $K8SPASSWORD
EOF

########################################
# Do other stuff

if ! [ -x "$(command -v nmap)" ]; then
  echo -n "Installing nmap..."
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -q 1> /dev/null 2> /dev/null
  sudo DEBIAN_FRONTEND=noninteractive apt-get install nmap -y -q 1> /dev/null 2> /dev/null
  echo "done."
  exit 1
fi
