

Edited note.md
Viewed values.yaml:373-388

Yes, exactly! When you run `kagent install --profile demo`, the CLI is essentially acting as an automated installer that does a few core things for you under the hood:

1. **Installs the Custom Resource Definitions (CRDs):** It applies the Kubernetes CRDs necessary for Kagent to work (like `Agent`, `AgentRun`, `MCPTool`, etc.).
2. **Deploys the Helm Chart:** It installs the `kagent` Helm chart (which includes the controller, UI, and necessary RBAC permissions) into your cluster.
3. **Applies Profile-Specific Resources (`--profile demo`):** This is where the magic happens. Because you selected the `demo` profile, it automatically applies pre-configured Custom Resources (CRs) into your cluster. This typically includes:
   - Several pre-configured `Agent` resources (ready to use).
   - Some default `MCPTool` resources (giving those agents abilities, like fetching cluster info or running commands).

### The Alternative (`--profile minimal`)
If you were to run `kagent install --profile minimal`, it would still do steps 1 and 2 (installing the CRDs and the Helm chart), but it would skip step 3. You would get a completely blank slate with no pre-configured agents or tools, leaving you to create them all manually. 

So, in short: `kagent install` is a wrapper around `helm install` + `kubectl apply` that makes getting started with Kagent much easier!

# Kagent Helm Chart

These Helm charts install kagent-crds,kagent, it is required that the Kagent CRDs chart to be installed first.

## Installation

### Using Helm

```bash
# First, install the required CRDs
helm install kagent-crds ./helm/kagent-crds/  --namespace kagent

# Then install Kagent with default provider 
# --set providers.default=openAI enabled by default, but you need to provide your openAI apikey
helm install kagent ./helm/kagent/ --namespace kagent --set providers.openAI.apiKey=your-openai-api-key

# Or with optional providers if you prefer local ollama provider or anthropic
helm install kagent ./helm/kagent/ --namespace kagent --set providers.default=ollama
helm install kagent ./helm/kagent/ --namespace kagent --set providers.default=openAI       --set providers.openAI.apiKey=your-openai-api-key
helm install kagent ./helm/kagent/ --namespace kagent --set providers.default=anthropic    --set providers.anthropic.apiKey=your-anthropic-api-key
helm install kagent ./helm/kagent/ --namespace kagent --set providers.default=azureOpenAI  --set providers.azureOpenAI.apiKey=your-openai-api-key
```

### Using Make

```bash
# export your openAI key
export OPENAI_API_KEY=your-openai-api-key
export ANTHROPIC_API_KEY=your-anthropic-api-key
export AZUREOPENAI_API_KEY=your-azure-api-key

# install the kagent charts with openAI provider 
make KAGENT_DEFAULT_MODEL_PROVIDER=openAI helm-install

# install charts with anthropic provider
make KAGENT_DEFAULT_MODEL_PROVIDER=anthropic helm-install

# install charts with anthropic provider
make KAGENT_DEFAULT_MODEL_PROVIDER=azureOpenAI helm-install

# install charts with ollama provider
make KAGENT_DEFAULT_MODEL_PROVIDER=ollama helm-install
```

### Using kagent cli

```bash
## make sure have env variable with your API_KEY
export OPENAI_API_KEY=your-openai-api-key
export ANTHROPIC_API_KEY=your-anthropic-api-key
export AZURE_API_KEY=your-azure-api-key

#default provider is openAI but you can select from the list 
export KAGENT_DEFAULT_MODEL_PROVIDER=ollama
export KAGENT_DEFAULT_MODEL_PROVIDER=azureOpenAI
export KAGENT_DEFAULT_MODEL_PROVIDER=anthropic

# use local helm chart to install kagent with openAI provider
export KAGENT_DEFAULT_MODEL_PROVIDER=openAI
export KAGENT_HELM_REPO=./helm/
make kagent-cli-install

# use local helm chart to install kagent with ollama provider
export KAGENT_DEFAULT_MODEL_PROVIDER=ollama
export KAGENT_HELM_REPO=./helm/
make kagent-cli-install

```

## Upgrading

When upgrading, make sure to upgrade both charts:

```bash
# First, upgrade the CRDs
helm upgrade kagent-crds ./helm/kagent-crds/  --namespace kagent

# Then upgrade Kagent
helm upgrade kagent ./helm/kagent/ --namespace kagent
```

## Uninstallation

To properly uninstall Kagent:

```bash
# First, uninstall Kagent
helm uninstall kagent --namespace kagent

# To completely remove all resources including CRDs (optional):
helm uninstall kagent-crds --namespace kagent
```

**Note**: Uninstalling the CRDs chart will delete all custom resources of those types across all namespaces.

## Why Separate CRDs?

Helm has a limitation where CRDs are installed but not removed during uninstallation. 
By separating CRDs into their own chart, we can:

1. Allow proper version control of CRDs
2. Enable users to choose when to remove CRDs (which is destructive)
3. Follow Helm best practices
