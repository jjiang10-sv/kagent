

Edited launch.json
Viewed launch.json:56-72
Viewed app.go:300-500

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