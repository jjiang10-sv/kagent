kubectl port-forward svc/postgres-cluster-rw 5432:5432 -n database-pg

kubectl port-forward svc/kagent-controller 8083:8083 -n kagent

export KAGENT_DEFAULT_MODEL_PROVIDER=gemini
kagent install --profile demo

helm upgrade kagent ./helm/kagent/ --namespace kagent -f ./helm/kagent/values_a.yaml

make print-tools-versions && awk '/github\.com\/kagent-dev\/kmcp/ { print substr($2, 2) }' go/go.mod

helm list -n kagent
helm get values kagent -n kagent -a | grep -i kmcp
kubectl get pods -n kagent -o jsonpath='{.items[*].spec.containers[*].image}' | tr ' ' '\n' | grep kmcp

helm dependency build ./helm/kagent
make helm-version

grep -n "secretName\|kagent-app\|cnpg" helm/kagent/values_a.yaml 2>/dev/null | head -20; kubectl get secret -n kagent | grep -i app

kubectl get secret -A | grep -i app | grep -v "service-account\|token\|default"; kubectl get cluster -A 2>/dev/null || echo "no cnpg cluster CRDs"

kubectl get secret postgres-cluster-app -n database-pg -o jsonpath='{.data}' | python3 -c "import sys,json,base64; d=json.load(sys.stdin); [print(k,'=',base64.b64decode(v).decode() if k=='uri' else '***') for k,v in d.items()]"

grep -n "volumes:\|volumeMounts:\|controller:" helm/kagent/values_a.yaml | head -30

kubectl get secret postgres-cluster-app -n database-pg -o json \
  | jq 'del(.metadata.ownerReferences, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.annotations, .metadata.labels) | .metadata.namespace = "kagent"' \
  | kubectl apply -f -