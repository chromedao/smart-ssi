#!/usr/bin/env bash
# Deploys the Smart-SSI notary on Cloud Run, over WebSocket (#9): no VM to start and stop, billed per
# proof, scales to zero. Provers connect to wss://<service url>.
#
#   PROJECT_ID=chromedao-smart-ssi deploy/gcp/deploy-notary-run.sh
#   (new project: also set BILLING_ACCOUNT=XXXXXX-XXXXXX-XXXXXX)
#
# - Key: 32 random bytes generated once straight into Secret Manager (secret notary-key), mounted as a
#   file. It never touches the disk of this machine and is never in the image.
# - Image: the same as the VM notary (deploy/notary.Dockerfile), started with `notary --ws`.
# Run from the repository root. Creates the project and the Artifact Registry repository if missing.
set -euo pipefail

: "${PROJECT_ID:?set PROJECT_ID}"
REGION="${REGION:-europe-west1}"
SERVICE=smart-ssi-notary
IMAGE="$REGION-docker.pkg.dev/$PROJECT_ID/smart-ssi/notary:$(git rev-parse --short HEAD)"

step() { printf '\n== %s\n' "$*"; }
step "Project $PROJECT_ID"
if ! gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1; then
  : "${BILLING_ACCOUNT:?set BILLING_ACCOUNT to create the project}"
  gcloud projects create "$PROJECT_ID" --name="Chrome DAO Smart-SSI"
  gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"
fi
gcloud config set project "$PROJECT_ID" >/dev/null

step "APIs: Cloud Run, Secret Manager, Artifact Registry, Cloud Build"
gcloud services enable run.googleapis.com secretmanager.googleapis.com artifactregistry.googleapis.com cloudbuild.googleapis.com

step "Artifact Registry repository smart-ssi ($REGION)"
gcloud artifacts repositories describe smart-ssi --location="$REGION" >/dev/null 2>&1 ||
  gcloud artifacts repositories create smart-ssi --location="$REGION" --repository-format=docker \
    --description="Smart-SSI images"

step "Secret notary-key"
if ! gcloud secrets describe notary-key >/dev/null 2>&1; then
  head -c 32 /dev/urandom | gcloud secrets create notary-key --replication-policy=automatic --data-file=-
fi
NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
gcloud secrets add-iam-policy-binding notary-key --role=roles/secretmanager.secretAccessor \
  --member="serviceAccount:$NUMBER-compute@developer.gserviceaccount.com" >/dev/null

step "Build $IMAGE with Cloud Build"
if ! gcloud artifacts docker images describe "$IMAGE" >/dev/null 2>&1; then
  BUILD_CONFIG=$(mktemp)
  cat > "$BUILD_CONFIG" <<EOF
steps:
  - name: gcr.io/cloud-builders/docker
    args: [build, -f, deploy/notary.Dockerfile, -t, $IMAGE, .]
images: [$IMAGE]
options:
  machineType: E2_HIGHCPU_8
timeout: 3600s
EOF
  gcloud builds submit --region="$REGION" --config="$BUILD_CONFIG" .
  rm -f "$BUILD_CONFIG"
fi

step "Cloud Run service $SERVICE"
# One proof is one WebSocket request of a few seconds; MPC-TLS is CPU-bound, so one proof per instance.
gcloud run deploy "$SERVICE" --image="$IMAGE" --region="$REGION" --allow-unauthenticated \
  --command=smart-ssi-prover --args=notary,--ws,--key,/secrets/notary.key \
  --set-secrets=/secrets/notary.key=notary-key:latest \
  --cpu=2 --memory=2Gi --concurrency=1 --min-instances=0 --max-instances=5 --timeout=120

step "Done"
URL=$(gcloud run services describe "$SERVICE" --region="$REGION" --format='value(status.url)')
echo "Notary: ${URL/https:/wss:}"
echo "Public key: gcloud logging read 'resource.labels.service_name=$SERVICE AND textPayload:\"public key\"' --limit=1 --format='value(textPayload)'"
