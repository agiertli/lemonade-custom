# Project: Lemonade Stand Assistant

AI-powered customer service chatbot with guardrails, deployed on Red Hat OpenShift (OCP).
Slovak translation branch (`itapa-sk`) for ITAPA conference.

## Git

- **Push remote**: Always use `custom` remote (`agiertli/lemonade-custom`) for `git push`. Never push to `origin` (`rh-ai-quickstart/lemonade-stand-assistant`).
- Main branch: `main`
- Slovak branch: `itapa-sk`

## Installation

- Single entry point: `./scripts/install.sh`
- Production mode: `PROD_MODE=true ./scripts/install.sh`
- Namespace: `lemonade-stand-assistant`

## Architecture (itapa-sk branch)

```
┌─────────────────────────────────────────────────────────────────┐
│                        User (Browser)                          │
│                    lemonade-stand Route                         │
└────────────────────────┬────────────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────────────┐
│  FastAPI App (quay.io/agiertli/lemon-fastapi-sk)               │
│  - Slovak UI, error messages, system prompt                    │
│  - Local regex check (Slovak fruit names)                      │
│  - Streams SSE to browser                                      │
│  - max_tokens=100 (concise), max_input_chars=100               │
└────────┬───────────────────────────────────────┬────────────────┘
         │ INPUT detectors                       │ No output detectors
         ▼                                       │ (streaming incompatible)
┌────────────────────────────────────────────────▼────────────────┐
│  GuardrailsOrchestrator (TrustyAI)                             │
│  Config: fms-orchestr8-config-nlp ConfigMap                    │
└──┬──────────┬──────────────┬──────────────┬────────────────────┘
   │          │              │              │
   ▼          ▼              ▼              ▼
┌──────┐ ┌────────┐ ┌──────────────┐ ┌──────────────────────────┐
│ HAP  │ │Language │ │   Prompt     │ │     LLM: Qwen3-8B       │
│Detect│ │Detect   │ │  Injection   │ │ (vLLM, /no_think mode)  │
│      │ │(Slovak) │ │ (multilingual│ │                          │
│Granite│ │Lingua  │ │  mDeBERTa)  │ │ modelcar OCI image       │
│Guard │ │ SK     │ │             │ │ quay.io/redhat-ai-services│
│125M  │ │        │ │ proventra/  │ │ /modelcar-catalog:qwen3-8b│
│      │ │quay.io/│ │ mdeberta-v3 │ │                          │
│KServe│ │agiertli│ │             │ │ 3 replicas, GPU (L4)     │
│      │ │/lingua-│ │quay.io/     │ │ --max-model-len=2048     │
│2 repl│ │lang-   │ │agiertli/    │ │ --served-model-name=     │
│GPU   │ │detect- │ │prompt-inj-  │ │   qwen3-8b               │
│      │ │sk:1.0.0│ │detect-sk    │ │                          │
│port  │ │        │ │:1.0.0       │ │                          │
│8000  │ │port    │ │             │ │                          │
│      │ │8080    │ │port 8000    │ │ port 8080                │
└──────┘ └────────┘ └─────────────┘ └──────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│  Grafana Dashboard (Slovak labels)                           │
│  - Folder: "Stánok s citrónadou"                             │
│  - Panels: Detekcie, Celkové požiadavky, Blokovaný vstup,   │
│    Blokované odpovede, Schválené požiadavky                  │
│  - Prometheus datasource via thanos-querier                  │
└──────────────────────────────────────────────────────────────┘
```

## Guardrails (input-side, all work with Slovak)

| Guardrail | Model | Language Support | Image |
|-----------|-------|-----------------|-------|
| HAP (swearing) | Granite Guardian 125M | Works with Slovak | KServe (original) |
| Language Detection | Lingua (custom SK) | Accepts Slovak, blocks others | `quay.io/agiertli/lingua-language-detector-sk:1.0.0` |
| Prompt Injection | mDeBERTa-v3 (multilingual) | Tested on Slovak | `quay.io/agiertli/prompt-injection-detector-sk:1.0.0` |
| Regex Competitor | Local pattern matching | Slovak fruit names included | Built into FastAPI app |

## Key files

- `chart/` — Main Helm chart (app, models, orchestrator)
- `chart/values-prod.yaml` — Production overrides (3x Qwen3, 2x HAP, 2x Prompt Injection, 7 GPU nodes)
- `chart/templates/llm-llama32.yaml` — Qwen3-8B ServingRuntime + InferenceService (name kept for compatibility)
- `chart/templates/prompt-injection-detector.yaml` — Multilingual PI detector (Deployment, not KServe)
- `chart/templates/lingua.yaml` — Slovak language detector
- `chart/templates/lemonade-stand-app.yaml` — FastAPI app + Slovak system prompt ConfigMap
- `chart/templates/fms-orchestr8-config-nlp.yaml` — Orchestrator detector topology
- `grafana/` — Grafana Helm chart (dashboard, datasource, RBAC)
- `grafana/templates/grafana.yaml` — Single source of truth for Grafana CRs
- `lingua-detector/` — Source for Slovak lingua detector image
- `prompt-injection-detector-sk/` — Source for multilingual PI detector image
- `lemonade-stand-app/` — Source for Slovak FastAPI app image

## Custom container images (quay.io/agiertli)

| Image | Purpose | Source |
|-------|---------|--------|
| `lemon-fastapi-sk` | Slovak FastAPI app | `lemonade-stand-app/` |
| `lingua-language-detector-sk` | Slovak lingua detector | `lingua-detector/` |
| `prompt-injection-detector-sk` | Multilingual PI detector | `prompt-injection-detector-sk/` |
