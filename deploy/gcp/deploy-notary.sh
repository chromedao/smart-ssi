#!/usr/bin/env bash
# Deploys the Smart-SSI notary on a Google Compute Engine VM (prototype for real-phone tests, #4).
#
#   PROJECT_ID=chromedao-smart-ssi BILLING_ACCOUNT=XXXXXX-XXXXXX-XXXXXX deploy/gcp/deploy-notary.sh
#
# Creates (if missing): the project, the Artifact Registry repository, the notary image (Cloud Build),
# a static IP, a firewall rule for TCP 7047, and an e2-standard-2 Debian VM running the image with Docker.
# The notary key is created on the VM's disk on first start (/var/lib/smart-ssi/notary.key) and never
# leaves it. Run from the repository root. Each step prints what it does; nothing is deleted.
set -euo pipefail

: "${PROJECT_ID:?set PROJECT_ID}"
REGION="${REGION:-europe-west1}"
ZONE="${ZONE:-europe-west1-b}"
MACHINE="${MACHINE:-e2-standard-2}"
VM=smart-ssi-notary
IMAGE="$REGION-docker.pkg.dev/$PROJECT_ID/smart-ssi/notary:$(git rev-parse --short HEAD)"

step() { printf '\n== %s\n' "$*"; }

step "Project $PROJECT_ID"
if ! gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1; then
  : "${BILLING_ACCOUNT:?set BILLING_ACCOUNT to create the project}"
  gcloud projects create "$PROJECT_ID" --name="Chrome DAO Smart-SSI"
  gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"
fi
gcloud config set project "$PROJECT_ID" >/dev/null

step "APIs: Compute Engine, Artifact Registry, Cloud Build"
gcloud services enable compute.googleapis.com artifactregistry.googleapis.com cloudbuild.googleapis.com

step "Artifact Registry repository smart-ssi ($REGION)"
gcloud artifacts repositories describe smart-ssi --location="$REGION" >/dev/null 2>&1 ||
  gcloud artifacts repositories create smart-ssi --location="$REGION" --repository-format=docker \
    --description="Smart-SSI images"

step "Build $IMAGE with Cloud Build"
gcloud builds submit --region="$REGION" --config=- . <<EOF
steps:
  - name: gcr.io/cloud-builders/docker
    args: [build, -f, deploy/notary.Dockerfile, -t, $IMAGE, .]
images: [$IMAGE]
options:
  machineType: E2_HIGHCPU_8
timeout: 3600s
EOF

step "Static IP smart-ssi-notary"
gcloud compute addresses describe "$VM" --region="$REGION" >/dev/null 2>&1 ||
  gcloud compute addresses create "$VM" --region="$REGION"
IP=$(gcloud compute addresses describe "$VM" --region="$REGION" --format='value(address)')

step "Firewall: TCP 7047 to VMs tagged smart-ssi-notary"
gcloud compute firewall-rules describe allow-smart-ssi-notary >/dev/null 2>&1 ||
  gcloud compute firewall-rules create allow-smart-ssi-notary --allow=tcp:7047 \
    --target-tags=smart-ssi-notary --description="Smart-SSI notary (MPC-TLS)"

STARTUP=$(cat <<EOF
#!/bin/bash
set -e
command -v docker >/dev/null || { apt-get update && apt-get install -y docker.io; }
gcloud auth configure-docker $REGION-docker.pkg.dev --quiet
mkdir -p /var/lib/smart-ssi
docker pull $IMAGE
docker rm -f notary 2>/dev/null || true
docker run -d --name notary --restart always -p 7047:7047 -v /var/lib/smart-ssi:/data $IMAGE
EOF
)

step "VM $VM ($MACHINE, $ZONE)"
if gcloud compute instances describe "$VM" --zone="$ZONE" >/dev/null 2>&1; then
  gcloud compute instances add-metadata "$VM" --zone="$ZONE" --metadata=startup-script="$STARTUP"
  gcloud compute instances reset "$VM" --zone="$ZONE"
else
  gcloud compute instances create "$VM" --zone="$ZONE" --machine-type="$MACHINE" \
    --image-family=debian-12 --image-project=debian-cloud --boot-disk-size=20GB \
    --address="$IP" --tags=smart-ssi-notary --scopes=cloud-platform \
    --metadata=startup-script="$STARTUP"
fi

step "Done"
echo "Notary: $IP:7047"
echo "Public key (once the container is up, ~1 min):"
echo "  gcloud compute ssh $VM --zone=$ZONE --command='sudo docker logs notary 2>&1 | grep \"public key\"'"
