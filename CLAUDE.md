# Project: Lemonade Stand Assistant

AI-powered customer service chatbot with guardrails on Red Hat OpenShift.

## Git

- **Push remote**: Always use `custom` remote (`agiertli/lemonade-custom`). Never push to `origin`.
- English demo: `automated-fixes` branch
- Multilingual demo (SK/CZ): `translation` branch (current)
- Slovak demo (translation, legacy): `itapa-sk-v2` branch
- Slovak demo (native, abandoned): `itapa-sk` branch

## Installation

```bash
# English version
git checkout automated-fixes
PROD_MODE=true ./scripts/install.sh

# Multilingual version (after base install)
git checkout translation
PROD_MODE=true ./scripts/install.sh
HF_TOKEN=$(cat ~/.cache/huggingface/token)

# Slovak (default)
helm upgrade lemonade-stand-assistant ./chart -n lemonade-stand-assistant \
  -f ./chart/values-prod.yaml \
  --set translateService.enabled=true \
  --set "translateService.hfToken=$HF_TOKEN"

# Czech
helm upgrade lemonade-stand-assistant ./chart -n lemonade-stand-assistant \
  -f ./chart/values-prod.yaml -f ./chart/values-cs.yaml \
  --set translateService.enabled=true \
  --set "translateService.hfToken=$HF_TOKEN"
```

## Switching Language

Language is fully configurable via Helm values — no code changes or image rebuilds needed.

**Quick switch** (SK default → CZ): add `-f ./chart/values-cs.yaml` to the helm command.

**What's configured per language** (`chart/values.yaml` / `chart/values-cs.yaml`):
- `language.code` — ISO 639-1 code (sk, cs) for TranslateGemma
- `language.name` — display name (slovensky, česky)
- `language.alsoAcceptLanguages` — comma-separated close languages the lingua detector also accepts
- `language.messages.*` — all detector/error messages in the target language
- `language.ui.*` — all frontend strings (header, examples, placeholder, footer)

**Adding a new language**: copy `chart/values-cs.yaml` to `chart/values-XX.yaml`, translate all strings, set `language.code` and `language.name`, then deploy with `-f ./chart/values-XX.yaml`. The lingua detector supports: sk, cs, de, fr, es, it, pl, hu, pt, nl, ro, bg, hr, sl, uk, ru. TranslateGemma must also support the language.

## Architecture (itapa-sk-v2)

```
User (Slovak) → FastAPI App
  1. Lingua SK: is it Slovak? (0.01s) → NOT Slovak → block 🇸🇰
  2. TranslateGemma 4B (vLLM): SK→EN (~1s)
  3. Local regex check on English text
  4. Orchestrator NON-STREAMING (fixes empty response bug):
     - Input: HAP, Prompt Injection
     - Output: HAP, Regex Competitor
     - LLaMA 3.2 3B → English response
  5. Check for blocks/warnings in response
  6. TranslateGemma 4B (vLLM): EN→SK (~3s)
  7. Fake word-by-word streaming to user
  Total: ~5-7s per request
```

**Critical**: Orchestrator MUST be called with `stream: false` when translation
is enabled. Streaming + output detectors = empty SSE responses (TrustyAI bug).
Non-streaming works perfectly with all detectors.

## GPU Allocation (7 x g6.4xlarge L4)

- LLaMA 3.2 3B: 3 replicas (3 GPUs)
- TranslateGemma 4B: 2 replicas (2 GPUs) — vLLM v0.14.1
- HAP detector: 2 replicas (CPU, tolerates GPU taint)
- PI detector: 2 replicas (CPU, tolerates GPU taint)
- Total: 5/7 GPUs used

## TranslateGemma vLLM Setup

- Image: `vllm/vllm-openai:v0.14.1` (NOT rhoai, too old for Gemma3)
- Model: `Infomaniak-AI/vllm-translategemma-4b-it` (vLLM-optimized)
- API format: `<<<source>>>sk<<<target>>>en<<<text>>>...` in user message
- Requires `HOME=/tmp` env var (permission fix for /.cache)
- Requires `mkdir -p /tmp/.cache/vllm /tmp/.cache/flashinfer` before start
- Model downloads at startup via HF_TOKEN (~2 min, emptyDir volume)
- max-model-len=2048, max-num-seqs=32

## Key Files

- `chart/templates/translate-service.yaml` — TranslateGemma vLLM deployment
- `chart/templates/lemonade-stand-app.yaml` — App + system prompt + locale ConfigMap + env vars
- `chart/templates/lingua.yaml` — Lingua detector (language via ACCEPTED_LANGUAGE env var)
- `chart/templates/ibm-hap-detector.yaml` — HAP (CPU, GPU taint toleration always on)
- `chart/templates/prompt-injection-detector.yaml` — PI (CPU, GPU taint toleration always on)
- `chart/templates/llm-llama32.yaml` — LLaMA 3.2 3B
- `chart/values-prod.yaml` — Prod config (GPU off for detectors)
- `lemonade-stand-app/app_fastapi.py` — Main app with translation logic
- `lemonade-stand-app/static/index.html` — UI (locale loaded dynamically from /api/locale)
- `chart/values-cs.yaml` — Czech language overlay
- `translate-service/` — (legacy FastAPI wrapper, not used with vLLM approach)
- `lingua-detector/` — Language-agnostic lingua detector source

## Container Images (quay.io/agiertli)

| Image | Purpose |
|-------|---------|
| `lemon-fastapi-translate:1.0.12` | App with translation + non-streaming orchestrator |
| `lingua-language-detector:2.0.0` | Lingua detector (language-agnostic, configured via ACCEPTED_LANGUAGE env var) |

## Known Issues

- Orchestrator streaming + output detectors = empty responses. Fixed by using non-streaming.
- TranslateGemma EN→SK takes ~3-10s depending on response length.
- vLLM v0.14.1 needs writable HOME dir (set HOME=/tmp).
- Grafana dashboard disappears after pod restart. Fix: run `./scripts/fix-grafana-dashboard.sh`.

## Tracing

App logs `[TRACE]` lines showing timing per phase:
```
[TRACE] Language check: 0.01s
[TRACE] SK→EN translation: 1.19s
[TRACE] Orchestrator+LLM: 2.15s
[TRACE] EN→SK translation: 3.41s
```
