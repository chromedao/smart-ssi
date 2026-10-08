#!/usr/bin/env bash
# Start or stop the notary VM between test sessions (a stopped VM only costs its disk and reserved IP).
#
#   deploy/gcp/notary-vm.sh start|stop|status
#
# The notary key stays on the VM's disk; on start, Docker restarts the container and the notary
# comes back with the same public key at the same address.
set -euo pipefail
PROJECT_ID="${PROJECT_ID:-chromedao-smart-ssi}"
ZONE="${ZONE:-europe-west1-b}"
VM=smart-ssi-notary

case "${1:-status}" in
  start)
    gcloud compute instances start "$VM" --zone="$ZONE" --project="$PROJECT_ID"
    IP=$(gcloud compute instances describe "$VM" --zone="$ZONE" --project="$PROJECT_ID" --format='value(networkInterfaces[0].accessConfigs[0].natIP)')
    printf 'waiting for the notary on %s:7047' "$IP"
    for _ in $(seq 1 60); do nc -z -G 2 "$IP" 7047 2>/dev/null && { echo " up"; exit 0; }; printf .; sleep 5; done
    echo " not up after 5 minutes"; exit 1
    ;;
  stop)
    gcloud compute instances stop "$VM" --zone="$ZONE" --project="$PROJECT_ID"
    ;;
  status)
    gcloud compute instances describe "$VM" --zone="$ZONE" --project="$PROJECT_ID" --format='value(status)'
    ;;
  *)
    echo "usage: $0 start|stop|status"; exit 1
    ;;
esac
