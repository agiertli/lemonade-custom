# Multilingual Support

The Lemonade Stand Assistant supports multilingual operation via [TranslateGemma](https://huggingface.co/Infomaniak-AI/vllm-translategemma-4b-it). Users interact in their native language while all guardrail processing happens in English under the hood.

## How it works

```
User (native language) → FastAPI App
  1. Lingua detector: validates user input is in the configured language
  2. TranslateGemma: translates input → English
  3. Guardrails + LLM process the English text
  4. TranslateGemma: translates English response → native language
  5. Response streamed back to user
```

Only **one language is active at a time**. Switching language is a pure configuration change — no code modifications or image rebuilds required.

## Quick start

```bash
# Deploy with Slovak (default)
helm upgrade lemonade-stand-assistant ./chart -n lemonade-stand-assistant \
  -f ./chart/values-prod.yaml \
  --set translateService.enabled=true

# Switch to Czech — just add the overlay file
helm upgrade lemonade-stand-assistant ./chart -n lemonade-stand-assistant \
  -f ./chart/values-prod.yaml -f ./chart/values-cs.yaml \
  --set translateService.enabled=true
```

## Adding a new language

### Step 1: Verify language support

Before starting, confirm your target language is supported by both components:

**Lingua detector** — supports 63 languages. Full list of ISO 639-1 codes:

`af` Afrikaans, `ar` Arabic, `az` Azerbaijani, `be` Belarusian, `bg` Bulgarian, `bn` Bengali, `bs` Bosnian, `ca` Catalan, `cs` Czech, `cy` Welsh, `da` Danish, `de` German, `el` Greek, `es` Spanish, `et` Estonian, `eu` Basque, `fa` Persian, `fi` Finnish, `fr` French, `ga` Irish, `gu` Gujarati, `he` Hebrew, `hi` Hindi, `hr` Croatian, `hu` Hungarian, `hy` Armenian, `id` Indonesian, `is` Icelandic, `it` Italian, `ja` Japanese, `ka` Georgian, `kk` Kazakh, `ko` Korean, `lt` Lithuanian, `lv` Latvian, `mk` Macedonian, `mn` Mongolian, `mr` Marathi, `ms` Malay, `nb` Norwegian Bokmål, `nl` Dutch, `nn` Norwegian Nynorsk, `pl` Polish, `pt` Portuguese, `ro` Romanian, `ru` Russian, `sk` Slovak, `sl` Slovene, `so` Somali, `sq` Albanian, `sr` Serbian, `sv` Swedish, `sw` Swahili, `ta` Tamil, `te` Telugu, `th` Thai, `tl` Tagalog, `tr` Turkish, `uk` Ukrainian, `ur` Urdu, `vi` Vietnamese, `yo` Yoruba, `zh` Chinese, `zu` Zulu

**TranslateGemma** — check the [model card](https://huggingface.co/Infomaniak-AI/vllm-translategemma-4b-it) for the full list of supported language pairs. The model must support `your_language ↔ English` translation.

### Step 2: Create a values file

Copy the Czech example and translate all strings:

```bash
cp chart/values-cs.yaml chart/values-XX.yaml   # XX = your ISO 639-1 code
```

Edit `chart/values-XX.yaml` — the file has this structure:

```yaml
language:
  code: "XX"          # ISO 639-1 language code
  name: "your_name"   # Display name shown to users

  messages:
    # Detector block messages — shown when guardrails trigger
    hap_input: "..."              # User's message flagged as harmful
    hap_output: "..."             # LLM response blocked as harmful
    prompt_injection_input: "..."  # User tried to bypass rules
    prompt_injection_output: "..." # Response contained suspicious instructions
    regex_competitor_input: "..."  # User mentioned non-lemon fruit
    regex_competitor_output: "..." # LLM almost mentioned non-lemon fruit
    language_detection_input: "..."  # User wrote in wrong language
    language_detection_output: "..." # LLM almost responded in wrong language

    # General messages
    followup: "..."           # "Can I help you with something else?"
    message_too_long: "..."   # Input exceeds 100 characters
    language_rejection: "..."  # Must contain {language_name} placeholder (used dynamically)
    no_response: "..."        # Empty response from LLM
    truncation: "..."         # Response hit max token limit

  ui:
    header: "..."       # Main page header
    example1: "..."     # First example question button
    example2: "..."     # Second example question button
    example3: "..."     # Third example question button
    placeholder: "..."  # Chat input placeholder text
    footer: "..."       # Footer text (appears before "Red Hat OpenShift AI" link)
```

**Important**: The `language_rejection` message must include `{language_name}` — it gets replaced at runtime with the value of `language.name`.

### Step 3: Deploy

```bash
helm upgrade lemonade-stand-assistant ./chart -n lemonade-stand-assistant \
  -f ./chart/values-prod.yaml -f ./chart/values-XX.yaml \
  --set translateService.enabled=true
```

### Step 4: Verify

After the pods restart (about 1-2 minutes), check that everything works:

```bash
# Get the app URL
APP_URL=$(oc get route/lemonade-stand -n lemonade-stand-assistant --template='https://{{.spec.host}}')

# Check the UI strings are in your language
curl -s "$APP_URL/api/locale" | python3 -m json.tool

# Check lingua detector accepted your language
oc logs deployment/lingua-detector | grep "Language config"
# Should show: primary=XX, also_accept=(none)

# Check the app loaded the locale
oc logs deployment/lemonade-stand | grep "Translation"
# Should show: Translation: enabled (language=XX, name=your_name)

# Send a test message in your language
curl -s -X POST "$APP_URL/api/chat" \
  -H "Content-Type: application/json" \
  -d '{"message": "your test question here"}' | head -5

# Verify English is rejected
curl -s -X POST "$APP_URL/api/chat" \
  -H "Content-Type: application/json" \
  -d '{"message": "Tell me about lemons"}'
# Should return an error message in your language
```

## Switching back

To switch back to Slovak (default), simply remove the `-f ./chart/values-XX.yaml` overlay from the helm command and run `helm upgrade` again.

## Existing language files

| File | Language | Code |
|------|----------|------|
| `chart/values.yaml` | Slovak (default) | `sk` |
| `chart/values-cs.yaml` | Czech | `cs` |

## Architecture details

- **Lingua detector** (`lingua-language-detector:2.1.0`): A single language-agnostic container image supporting 63 languages. The accepted language is configured via the `ACCEPTED_LANGUAGE` environment variable, which is set automatically from `language.code` in Helm values.
- **TranslateGemma** (`vllm/vllm-openai:v0.14.1`): Uses the prompt format `<<<source>>>XX<<<target>>>en<<<text>>>...` where `XX` is the language code from `language.code`.
- **FastAPI app** (`lemon-fastapi-translate:1.0.13`): Loads all user-facing strings from a ConfigMap-mounted JSON file at `/locale/locale.json`. The frontend fetches UI strings from the `/api/locale` endpoint on page load.
- **Locale ConfigMap**: Rendered by Helm from the `language.messages` and `language.ui` values. Mounted as a volume into the app pod.
- **`ENABLE_TRANSLATION`** env var (set automatically from `translateService.enabled`): Switches the app between English-only mode and translation mode. When `true`: lingua check runs first, input/output are translated via TranslateGemma, orchestrator uses non-streaming mode, and the orchestrator's built-in language_detection detector is skipped (lingua handles it instead).
