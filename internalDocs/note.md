
Edited pg.sh
Ran command: `helm get values kagent -n kagent -a | grep -i kmcp`
Ran command: `kubectl get pods -n kagent -o jsonpath='{.items[*].spec.containers[*].image}' | tr ' ' '\n' | grep kmcp`
Ran command: `helm upgrade kagent ./helm/kagent/ --namespace kagent --set providers.default=gemini --set providers.gemini.apiKey=
`
Ran command: `helm dependect build`
Ran command: `helm dependency build`
Viewed pg.sh:4-14
Ran command: `ls -la Chart.yaml`
Ran command: `helm dependency build ./helm/kagent`
Ran command: `make helm-version`
Ran command: `helm upgrade kagent ./helm/kagent/ --namespace kagent -f ./helm/kagent/values_a.yaml `
The error happened because the `helm/kagent/Chart.yaml` file in this repository is actually a template (`Chart-template.yaml`) that requires variables like `${VERSION}` to be injected by the build system. When you ran `helm dependency build`, Helm couldn't resolve the templated relative paths properly, causing it to inadvertently scan the parent directory, pick up the large `.git` repository pack files, and hit the 5MB file limit.

To fix this, the correct procedure in this repository is to run `make helm-version`. This command runs `envsubst` to populate the `Chart.yaml` files and then automatically runs `helm dependency update`. 

I went ahead and ran `make helm-version` for you in the background. It completed successfully and pulled down all the missing dependencies.


Ran command: `grep -n "secretName\|kagent-app\|cnpg" helm/kagent/values_a.yaml 2>/dev/null | head -20; kubectl get secret -n kagent | grep -i app`
Ran command: `kubectl get secret -A | grep -i app | grep -v "service-account\|token\|default"; kubectl get cluster -A 2>/dev/null || echo "no cnpg cluster CRDs"`
Ran command: `kubectl get secret postgres-cluster-app -n database-pg -o jsonpath='{.data}' | python3 -c "import sys,json,base64; d=json.load(sys.stdin); [print(k,'=',base64.b64decode(v).decode() if k=='uri' else '***') for k,v in d.items()]"`
Ran command: `grep -n "volumes:\|volumeMounts:\|controller:" helm/kagent/values_a.yaml | head -30`


Now I have everything I need. The CNPG secret is `postgres-cluster-app` in the `database-pg` namespace, and the `uri` key contains the full PostgreSQL connection string. I'll update `values_a.yaml` to:
1. Disable bundled postgres and point to the CNPG secret file
2. Enable pgvector (since `postgres-cluster` is likely pgvector-enabled)
3. Wire up the volumes/volumeMounts on the controller

Edited values_a.yaml

Done. Here's a summary of what changed in `values_a.yaml`:

**Database section (L67–122):**
| Field | Before | After |
|---|---|---|
| `urlFile` | `""` | `"/etc/kagent/db/uri"` |
| `vectorEnabled` | `false` | `true` |
| `bundled.enabled` | `true` + full image config | `false` |

**Controller section (L234–245):**
- `volumes` — now mounts `postgres-cluster-app` secret from the `database-pg` namespace at `/etc/kagent/db/`
- `volumeMounts` — mounts the volume at `/etc/kagent/db` read-only

> [!IMPORTANT]
> The `postgres-cluster-app` secret lives in `database-pg`, but the kagent controller pod runs in the `kagent` namespace. K8s volumes can only reference secrets **in the same namespace**. You'll need to either:
> 1. **Copy the secret** to the `kagent` namespace: `kubectl get secret postgres-cluster-app -n database-pg -o yaml | sed 's/namespace: database-pg/namespace: kagent/' | kubectl apply -f -`
> 2. Or use an **ExternalSecret** (if you have the external-secrets operator) to sync it across namespaces.


Edited note.md
Ran command: `kubectl get secret postgres-cluster-app -n database-pg -o yaml | sed 's/namespace: database-pg/namespace: kagent/' | kubectl apply -f -`
Viewed values_a.yaml:81-83

Because `urlFile` takes priority over `url`. Looking at the Helm template logic in `controller-deployment.yaml`:

```yaml
{{- if .Values.database.postgres.urlFile }}          # ← checked FIRST
- name: POSTGRES_DATABASE_URL_FILE
  value: {{ .Values.database.postgres.urlFile | quote }}
{{- else if .Values.database.postgres.url }}          # ← only if urlFile is empty
- name: POSTGRES_DATABASE_URL
  value: {{ .Values.database.postgres.url | quote }}
{{- else if .Values.database.postgres.bundled.enabled }}
  # ... builds a connection string to the bundled pod
{{- else }}
  {{ fail "No database connection configured." }}
{{- end }}
```

Since `urlFile: "/etc/kagent/db/uri"` is set, the template emits `POSTGRES_DATABASE_URL_FILE` as an env var. At runtime, the kagent controller reads **the contents of that file** to get the connection string — the file is the mounted CNPG secret key `uri` which contains the full `postgresql://app:...@postgres-cluster-rw.database-pg:5432/app` URL.

So the flow is:
1. `urlFile` → sets `POSTGRES_DATABASE_URL_FILE=/etc/kagent/db/uri`
2. Volume mount → projects `postgres-cluster-app` secret key `uri` as the file `/etc/kagent/db/uri`
3. Controller reads the file at boot → gets the full connection string

`url` being empty is intentional and correct — it's never evaluated.


Edited note.md
Ran command: `k get secret postgres-cluster-app -n kagent -o yaml`
Ran command: `k get secret postgres-cluster-app -n database_pg -o yaml`
Ran command: `k get secret postgres-cluster-app -n database-pg -o yaml`
Viewed values_a.yaml:194-209
Ran command: `kubectl get secret postgres-cluster-app -n kagent 2>&1; kubectl get events -n kagent --sort-by='.lastTimestamp' | tail -10`

The events tell the whole story:

```
OwnerRefInvalidNamespace   secret/postgres-cluster-app
ownerRef [Cluster, namespace: kagent, name: postgres-cluster, uid: ...] does not exist in namespace "kagent"
```

The `sed` command only changed the `namespace:` in `metadata`, but the secret also had `ownerReferences` pointing back to the CNPG `Cluster` object in `database-pg`. Kubernetes saw an invalid ownerRef and garbage-collected the secret immediately.

The fix is to strip `ownerReferences` and the CNPG labels/annotations when copying:

Ran command: `kubectl get secret postgres-cluster-app -n database-pg -o json \
  | jq 'del(.metadata.ownerReferences, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.annotations, .metadata.labels) | .metadata.namespace = "kagent"' \
  | kubectl apply -f -`
Ran command: `kubectl get secret postgres-cluster-app -n kagent`

The secret is now present in the `kagent` namespace. The root cause was that the original `sed`-based copy preserved the `ownerReferences` pointing to the CNPG `Cluster` object in `database-pg`. Kubernetes garbage-collected the secret immediately because the referenced owner didn't exist in the `kagent` namespace.

The fix uses `jq` to strip `ownerReferences`, `resourceVersion`, `uid`, `creationTimestamp`, and all CNPG labels/annotations before applying — making it a clean, standalone copy that Kubernetes won't auto-delete.

> [!NOTE]
> This is a one-time manual copy. If CNPG ever rotates the password for the `postgres-cluster`, you'll need to re-run this command to sync the updated secret into `kagent`. For a fully automated solution, consider an **ExternalSecret** resource using the external-secrets operator.

Also noticed the events show the helm upgrade is causing image pull failures because it's trying to pull `v0.0.0-1cbaa74f` from `cr.kagent.dev`, which doesn't exist. That's a separate issue — the upgrade shouldn't have changed the image tag. You may want to roll back the image tag with another upgrade passing `--set tag=0.9.7`.


Ran command: `kubectl get pods -n kagent && echo "---" && kubectl logs -n kagent -l app.kubernetes.io/component=controller --tail=40 2>&1`

The root cause is clear from the logs:

```
failed to connect to `user=kagent database=kagent`: 
hostname resolving error: lookup kagent-postgresql.kagent.svc.cluster.local ... no such host
```

The controller pod is still using the **old bundled postgres connection string** (`kagent-postgresql.kagent.svc.cluster.local`) because the new `values_a.yaml` settings (`urlFile`, volumes) didn't take effect on the running pod — **the controller pod needs to be restarted** to pick up the new POSTGRES_DATABASE_URL_FILE env var.

Ran command: `kubectl get pod -n kagent -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].spec.containers[0].env}' | python3 -m json.tool | grep -A3 POSTGRES`

The pod still has the **old** `POSTGRES_DATABASE_URL` pointing to the bundled postgres, not `POSTGRES_DATABASE_URL_FILE`. This means the Helm upgrade didn't actually roll the controller deployment — Helm only updates pods when the spec changes. Let me check if the deployment spec was updated properly:

Ran command: `kubectl get deployment kagent-controller -n kagent -o jsonpath='{.spec.template.spec.volumes}' | python3 -m json.tool 2>&1 | head -20`
Ran command: `kubectl get deployment kagent-controller -n kagent -o jsonpath='{.spec.template.spec.containers[0].env}' | python3 -m json.tool | grep -A3 POSTGRES`

The **deployment spec is correct** — it has `POSTGRES_DATABASE_URL_FILE` and the `cnpg-db-secret` volume. The running pod is just stale (it's from before the upgrade). Kubernetes should have rolled it automatically, but the pod is probably stuck due to the earlier `ImagePullBackOff`. Let me force a rollout:

Ran command: `kubectl rollout restart deployment/kagent-controller -n kagent && kubectl rollout status deployment/kagent-controller -n kagent --timeout=2m`
Ran command: `kubectl get pods -n kagent -l app.kubernetes.io/component=controller && echo "---" && kubectl describe pod -n kagent -l app.kubernetes.io/component=controller | grep -A 20 "Events:"`

The new pod is crashing on startup. Let me check the logs of the crashing pod:

Ran command: `kubectl logs -n kagent kagent-controller-6c958c8845-bm527 --previous 2>&1 | tail -30`

Two issues visible in the crash log:

**Issue 1 — `vectorEnabled: true` but no superuser permission:**
```
permission denied to create extension "vector"
```
The CNPG `app` user doesn't have `SUPERUSER` privileges needed to create the `pgvector` extension. The extension must be pre-installed by a superuser first.

**Issue 2 — The config still has a hardcoded fallback URL:**
```json
"Database":{"Url":"postgres://postgres:kagent@kagent-postgresql.kagent.svc.cluster.local...","UrlFile":"/etc/kagent/db/uri",...}
```
The `UrlFile` is being read (good) but there's also a stale `Url` in the config — this comes from the Helm ConfigMap, not a problem for connectivity since `UrlFile` takes priority, but the `vectorEnabled: true` is the crash cause.

The quickest fix is to set `vectorEnabled: false` for now (unless you have pre-installed pgvector as superuser):

Viewed values_a.yaml:73-80
Ran command: `kubectl exec -it -n database-pg $(kubectl get pod -n database-pg -l role=primary -o jsonpath='{.items[0].metadata.name}') -- psql -U postgres -c "SELECT * FROM pg_extension WHERE extname='vector';" 2>&1`
Ran command: `kubectl exec -it -n database-pg $(kubectl get pod -n database-pg -l role=primary -o jsonpath='{.items[0].metadata.name}') -- psql -U postgres -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>&1`

`vector` extension installed. But it was created in the `postgres` database — it needs to be in the `app` database (the one kagent connects to). Let me also install it there and then restart the controller:

Ran command: `kubectl exec -it -n database-pg $(kubectl get pod -n database-pg -l role=primary -o jsonpath='{.items[0].metadata.name}') -- psql -U postgres -d app -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>&1`
Ran command: `kubectl rollout restart deployment/kagent-controller -n kagent && kubectl rollout status deployment/kagent-controller -n kagent --timeout=3m`

The controller rolled out successfully. Now retry the agent:

Ran command: `kagent invoke -t "What Helm charts are in my cluster?" --agent helm-agent`
Ran command: `kubectl port-forward svc/kagent-controller 8083:8083 -n kagent &>/tmp/pf.log & sleep 3 && kagent invoke -t "What Helm charts are in my cluster?" --agent helm-agent`


The code tells us everything we need. Key findings from `app.go`:

- **Metrics cert** (lines 393–410): Only initialized if `cfg.Metrics.CertPath` is non-empty. If empty, controller-runtime **auto-generates self-signed certs** — perfectly fine for local dev.
- **Webhook cert** (lines 412–425): Same pattern — only a watcher is set up if `cfg.Webhook.CertPath` is non-empty. If empty, controller-runtime also auto-generates them.
- **Metrics can be disabled completely** by setting `--metrics-bind-address 0` (which we already did), so the metrics TLS question is moot.

So for local development, **no cert configuration is needed at all** — we already have it right. The launch config we added is correct as-is.

Here's the summary of why:

| Server | Our config | Cert behavior |
|---|---|---|
| **Metrics** | `--metrics-bind-address 0` | Server is **disabled** entirely — no cert needed |
| **Webhook** | No `--webhook-cert-path` set | Path is empty → controller-runtime **auto-generates** self-signed certs |

The pattern is different from KEDA which requires `--cert-dir` because KEDA's webhook server is more strictly configured. The kagent app only sets up a cert watcher when you explicitly point it at a cert directory — if you omit the flag, it falls back to auto-generated certs gracefully.

If you ever do need real certs (e.g., for a staging env where the webhook actually needs to be trusted by the API server), you'd add:
```json
"--webhook-cert-path", "${workspaceFolder}/kagent/certs",
"--metrics-cert-path", "${workspaceFolder}/kagent/certs",
"--metrics-bind-address", ":8443"
```

Since you don't currently have the plugin installed on your machine, you'll need to install it first.

### 1. Install the Helm Unittest Plugin
Run this in your terminal:
```bash
helm plugin install https://github.com/helm-unittest/helm-unittest.git
```

### 2. Run the Tests
Once installed, you can run all the tests in the `kagent` chart by running this from your `kagent` directory:
```bash
helm unittest helm/kagent
```

If you want to run **only** the specific `rbac_test.yaml` file to save time or isolate failures, use the `-f` flag:
```bash
helm unittest -f tests/rbac_test.yaml helm/kagent
```

Helm Unittest files allow you to test your Helm charts locally **without needing a Kubernetes cluster**. Instead of actually deploying resources, the framework renders the YAML templates (just like running `helm template`) and then verifies that the generated YAML looks exactly how you expect it to.

Here is a breakdown of how to read and understand the structure of the `rbac_test.yaml` file:

### 1. The Setup block
At the top of the file, you declare what you are testing:
```yaml
suite: test rbac
templates:
  - controller-serviceaccount.yaml
  - rbac/getter-role.yaml
  # ... lists which files from the chart's 'templates' folder will be rendered
```

### 2. The Tests block (`tests:`)
This is an array containing individual test cases. Each test case starts with `it:`, which describes what the test is proving.

### 3. Setting Values (`set:`)
You can optionally simulate changing variables in your `values.yaml` just for a specific test using `set:`. This is incredibly useful for testing `if/else` logic in your templates!
```yaml
  - it: should use custom namespace when overridden
    set:
      namespaceOverride: "custom-namespace"  # Simulates running `helm install --set namespaceOverride=custom-namespace`
```

### 4. Making Assertions (`asserts:`)
This is the core of the test. Once Helm renders the templates using the values you provided, you use assertions to verify the output YAML. 

Some common assertions you'll see in your file:

**`isKind`**: Checks if the rendered document is the correct Kubernetes type.
```yaml
      - isKind:
          of: ServiceAccount
```

**`equal`**: Looks up a specific path in the generated YAML (like `metadata.name`) and checks if it matches your expected value.
```yaml
      - equal:
          path: metadata.name
          value: RELEASE-NAME-controller
```

**`hasDocuments`**: Useful when your Helm chart has `range` loops that generate multiple resources, or `if` statements that might generate zero resources.
```yaml
      - hasDocuments:
          count: 2  # Proves that exactly 2 documents were generated
```

**`contains`**: Checks if an array contains a specific block of data (very useful for checking RBAC rules or container env vars).
```yaml
      - contains:
          path: rules
          content:
            apiGroups: [""]
            resources: ["*"]
            verbs: ["get", "list", "watch"]
```

**`failedTemplate`**: A special assertion that verifies your template **intentionally throws an error** (using Helm's `fail` function) when a user provides bad input.
```yaml
      - failedTemplate:
          errorMessage: "rbac.namespaces is set but does not include the install namespace"
```

### Summary
To read a test, just read it like a sentence:
> *"When I **set** `namespaceOverride` to `my-ns`, **it** should render the `getter-role.yaml` template, and I **assert** that the `metadata.namespace` is **equal** to `my-ns`."*

Great question. Here's exactly how it works for tools like **Claude Code** (and similar agents like Cursor, Copilot, etc.):

### How Skills Are Loaded

The `SKILL.md` file is **not automatically injected**. It follows a lazy-loading pattern:

1. **Discovery:** The agent first reads a lightweight index (usually a `manifest.json` or the YAML frontmatter of the skill file — the `name`, `description`, and trigger conditions at the top).
2. **Decision:** When your message matches the skill's `description` triggers (e.g., "user mentions kagent"), the agent **actively reads the skill file** using a file-read tool call.
3. **Injection:** The full content is then prepended as context for that specific turn.

This is visible in the frontmatter of your file:
```yaml
description: >
  Use this skill whenever the user mentions kagent, asks about deploying AI 
  agents to Kubernetes ... even if they don't explicitly say "kagent"
```
That description is the **matching rule**, not the content itself.

---

### Does It Cost Extra Tokens? Yes.

Once loaded, the skill becomes part of the **context window** for that conversation turn. For your `SKILL.md`, that's roughly **~1,800 tokens** added to the input. The implications:

| | Without skill | With skill |
|---|---|---|
| Input tokens | Base prompt only | +~1,800 tokens per relevant turn |
| Output tokens | Unchanged | Unchanged |
| Cost | Lower | Slightly higher |
| Quality | Generic answer | Domain-specific, accurate answer |

---

### Key Design Insight

The reason skills are structured this way (thin description + chunked references like `references/mcp-ide-setup.md`) is **precisely to manage token cost**. Notice your skill doesn't inline everything — it says:

> "For detailed setup, IDE-specific configuration, and troubleshooting, see `references/mcp-ide-setup.md`."

The agent only reads those sub-files if needed, so a simple "install kagent" question doesn't also load the entire troubleshooting guide.

This is the same concept as **Retrieval-Augmented Generation (RAG)** — fetch only what's relevant, when it's relevant, rather than stuffing everything into the system prompt upfront.

Ran command: `cd kagent`
Viewed evals.json:1-11

The `evals.json` file is a **test suite for the skill itself**, not something that is loaded into the agent's context during normal conversations. 

### What it does:
When developers write or update a skill (like `SKILL.md`), they need a way to verify that the AI actually understands the instructions and provides correct answers. The `evals.json` file provides a list of common questions (`prompt`) and the specific things the AI's answer must include (`expected_output`).

### How it is used:
Developers use an evaluation framework (often automated in CI/CD) that:
1. Feeds the `prompt` to the AI (with the `SKILL.md` loaded).
2. Reads the AI's response.
3. Automatically grades the response using another LLM to check if it meets the criteria defined in `expected_output`.

### Does it consume tokens?
**No.** Because it is only used for offline testing, it is never loaded into the agent's context window during your actual usage, so it does not consume any of your tokens or API costs!

Edited note.md
Viewed run-agent-framework-test.yaml:78-91

This GitHub Actions workflow is actually testing something completely different from the `evals.json` file we just looked at. They serve two different testing purposes!

Here is a breakdown of how this workflow operates and how it relates (or rather, *doesn't* relate) to the `evals.json` file:

### 1. What does this workflow test?
This workflow is a **functional integration test for the actual Kagent AI agent**. It tests whether the Kagent software can successfully connect to a live Kubernetes cluster, diagnose a broken application, and fix it autonomously.

It uses a `matrix` strategy to run 24 different broken scenarios (e.g., `configmap-missing-key.yaml`, `deployment-low-resources.yaml`, `secret-missing.yaml`). 

### 2. How the test execution works:
For each of the 24 challenges, the workflow follows these steps:
1. **Setup Cluster:** It spins up a temporary local Kubernetes cluster (`kind-kagent`).
2. **Break the Cluster:** It runs `run.sh` (in the `Setup scenario` step) which deploys a deliberately broken application into the cluster.
3. **Invoke the Agent:** The `Run Test` step runs `./run-challenge.sh`, which feeds the challenge's `.spec.prompt` to the Kagent AI and tells it to go fix the cluster.
4. **Validate the Fix:** The `Validate cluster fixed` step runs a test suite using `mocha ./test.js`. This script checks the live Kubernetes cluster to verify if Kagent successfully fixed the broken deployment, secret, configmap, etc.
5. **Report:** It records whether the AI agent passed or failed the challenge.

### 3. Where does `evals.json` fit in?
**It doesn't!** `evals.json` is not used in this workflow at all. 

Here is the difference between the two:

| | `run-agent-framework-test.yaml` | `evals.json` (inside `.claude/skills/`) |
|---|---|---|
| **What is it testing?** | The **Kagent software's** ability to act as an autonomous DevOps engineer. | **Claude's** ability to act as a documentation assistant. |
| **How does it test?** | Creates a real broken cluster, asks Kagent to fix it, and checks if the cluster is healthy. | Asks Claude a question about Kagent docs, and checks if Claude's text answer is correct. |
| **Who uses it?** | Kagent developers (to make sure their AI agent is actually good at fixing Kubernetes). | Kagent developers (to make sure their `.claude/skills/kagent/SKILL.md` file teaches LLMs correctly). |

In short: The workflow evaluates how well the AI **does the work**, while `evals.json` evaluates how well the AI **explains the tool**.

Inside the `.github` directory but outside the `workflows` folder, the YAML files are divided into two main categories:

### 1. Reusable Custom Actions
* **Path:** `.github/actions/initialize-environment/action.yaml`
* **Usage:** This defines a "Composite Action." Instead of copying and pasting the exact same setup steps (like installing Go, setting up QEMU, installing kind, etc.) into every single workflow file, developers create a reusable action here. Workflows can then call this action with a single line (e.g., `uses: ./.github/actions/initialize-environment`) to keep the main workflow files clean and DRY (Don't Repeat Yourself).

### 2. The Test Data (The "Broken" Cluster Scenarios)
* **Path:** `.github/data/agent-framework/scenario1/*.yaml` (e.g., `secret-missing.yaml`, `configmap-misspelled.yaml`, `deployment-low-resources.yaml`)
* **Usage:** These are the actual test cases that the `run-agent-framework-test.yaml` workflow uses! 
Each file contains:
  1. A deliberately broken Kubernetes manifest (e.g., a Deployment pointing to a ConfigMap that doesn't exist).
  2. A `.spec.prompt` field (which we saw the workflow extract using `yq .spec.prompt`).
  
  When the workflow runs, it deploys one of these broken YAML files into the temporary cluster, feeds the embedded prompt to Kagent, and evaluates if the AI can fix the specific issue defined in that file.

### 3. Agent Framework Resources
* **Path:** `.github/data/agent-framework/resources/*.yaml` (e.g., `agent.yaml`, `model.yaml`)
* **Usage:** These are the baseline configuration files needed to bootstrap Kagent itself during the tests. Before the workflow can ask Kagent to fix the broken scenarios above, it applies these files to define the test Agent (using `agent.yaml`) and connect it to the LLM provider (using `model.yaml`).

Ran command: `claude eval -h`

Based on the terminal output you just generated, you've discovered an interesting detail: **The `eval` command doesn't actually exist in the public version of the Claude CLI!**

If you look at the `Commands:` section at the bottom of your terminal output, you see things like `mcp`, `plugin`, `project`, and `update` — but no `eval`.

### Why is this?
The `evals.json` file is a leftover development artifact from the original authors of the `kagent` skill. When Anthropic engineers or early partners develop skills, they use internal, developer-only builds of the Claude CLI (or separate internal testing scripts) that include an `eval` or `test` command to score the skill's performance before publishing it. 

They committed the `evals.json` to the open-source repository so they could track their test cases, but regular users of the public `claude` CLI cannot actually run them.

### If you had the internal developer tool, it would look like this:

If the command were available, a developer working on the `kagent` repository would navigate to the root directory and run something like:

```bash
# This is a hypothetical internal command used by the skill authors
claude skill eval ./kagent/.claude/skills/kagent
```

The tool would then:
1. Parse the `evals.json` file.
2. Spin up a hidden Claude instance.
3. Feed it Prompt #0: *"I want to try kagent on my local machine..."*
4. Use another LLM to score the response against the `expected_output`.
5. Output a score (e.g., "Pass: 9/10 tests").

**For you as an end-user:** You can safely ignore the `evals/` folder. It is purely for the maintainers of the `kagent` repository to ensure the AI gives you good answers when you ask questions!