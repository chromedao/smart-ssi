#!/usr/bin/env bash
# Deploys the Smart-SSI issuer API on Cloud Run (prototype, Solana devnet), next to the notary.
#
#   PROJECT_ID=chromedao-smart-ssi NOTARY_PUBKEY=<hex> deploy/gcp/deploy-issuer.sh
#
# - Keys: issuer/keys/{fee-payer,authority,signer}.json are uploaded once to Secret Manager
#   (secret issuer-keys) and passed to the service as ISSUER_KEYS. They are never in the image.
# - One instance at most: the replay store (used proofs) is a local file, lost on restart.
# Run from the repository root.
set -euo pipefail

: "${PROJECT_ID:?set PROJECT_ID}"
: "${NOTARY_PUBKEY:?set NOTARY_PUBKEY (the notary the apps use)}"
REGION="${REGION:-europe-west1}"
SERVICE=smart-ssi-issuer
IMAGE="$REGION-docker.pkg.dev/$PROJECT_ID/smart-ssi/issuer:$(git rev-parse --short HEAD)"

step() { printf '\n== %s\n' "$*"; }
gcloud config set project "$PROJECT_ID" >/dev/null

step "APIs: Cloud Run, Secret Manager"
gcloud services enable run.googleapis.com secretmanager.googleapis.com

step "Secret issuer-keys (devnet keys)"
if ! gcloud secrets describe issuer-keys >/dev/null 2>&1; then
  python3 - <<'PY' | gcloud secrets create issuer-keys --replication-policy=automatic --data-file=-
import json
print(json.dumps({n: json.load(open(f"issuer/keys/{n}.json"))["seed"] for n in ("fee-payer", "authority", "signer")}), end="")
PY
fi
NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
gcloud secrets add-iam-policy-binding issuer-keys --role=roles/secretmanager.secretAccessor \
  --member="serviceAccount:$NUMBER-compute@developer.gserviceaccount.com" >/dev/null

step "Build $IMAGE with Cloud Build"
BUILD_CONFIG=$(mktemp)
cat > "$BUILD_CONFIG" <<EOF
steps:
  - name: gcr.io/cloud-builders/docker
    args: [build, -f, deploy/issuer.Dockerfile, -t, $IMAGE, .]
images: [$IMAGE]
options:
  machineType: E2_HIGHCPU_8
timeout: 3600s
EOF
gcloud builds submit --region="$REGION" --config="$BUILD_CONFIG" .
rm -f "$BUILD_CONFIG"

step "Cloud Run service $SERVICE"
gcloud run deploy "$SERVICE" --image="$IMAGE" --region="$REGION" --allow-unauthenticated \
  --max-instances=1 --memory=1Gi --cpu=1 \
  --set-secrets=ISSUER_KEYS=issuer-keys:latest \
  --set-env-vars="^@^NOTARY_PUBKEY=$NOTARY_PUBKEY"  # ^@^: the key list contains commas

step "Done"
echo "Issuer API: $(gcloud run services describe "$SERVICE" --region="$REGION" --format='value(status.url)')"
