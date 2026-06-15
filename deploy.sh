
set -euo pipefail

helm install kagent-crds ./helm/kagent-crds/  --namespace kagent

helm install kagent ./helm/kagent/ --namespace kagent --set providers.default=gemini \
       --set providers.gemini.apiKey=AIzaSyBupk7vKhEp8t1p88rYT2GU0vcT9eCvNvE


kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=kagent -n kagent --timeout=2m