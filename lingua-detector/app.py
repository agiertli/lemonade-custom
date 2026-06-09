import asyncio
import logging
import os
import re
from contextlib import asynccontextmanager
from typing import Any, Dict, List, Optional

from fastapi import FastAPI, Request
from fast_langdetect import detect as fast_detect
from lingua import Language, LanguageDetectorBuilder
from pydantic import BaseModel, Field

log_level = os.getenv("LOG_LEVEL", "INFO").upper()
logging.basicConfig(level=getattr(logging, log_level, logging.INFO))
logger = logging.getLogger(__name__)

# =============================================================================
# Language Configuration (from environment)
# =============================================================================

ACCEPTED_LANGUAGE = os.getenv("ACCEPTED_LANGUAGE", "sk")
ALSO_ACCEPT_LANGUAGES = os.getenv("ALSO_ACCEPT_LANGUAGES", "")

ISO_TO_LINGUA = {
    "sk": Language.SLOVAK,
    "cs": Language.CZECH,
    "de": Language.GERMAN,
    "fr": Language.FRENCH,
    "es": Language.SPANISH,
    "it": Language.ITALIAN,
    "pl": Language.POLISH,
    "hu": Language.HUNGARIAN,
    "pt": Language.PORTUGUESE,
    "nl": Language.DUTCH,
    "ro": Language.ROMANIAN,
    "bg": Language.BULGARIAN,
    "hr": Language.CROATIAN,
    "sl": Language.SLOVENE,
    "uk": Language.UKRAINIAN,
    "ru": Language.RUSSIAN,
}


def _build_accepted_set():
    primary = ISO_TO_LINGUA.get(ACCEPTED_LANGUAGE)
    if primary is None:
        raise ValueError(
            f"Unsupported ACCEPTED_LANGUAGE: {ACCEPTED_LANGUAGE}. "
            f"Supported: {', '.join(sorted(ISO_TO_LINGUA))}"
        )
    accepted = {primary}
    if ALSO_ACCEPT_LANGUAGES:
        for code in ALSO_ACCEPT_LANGUAGES.split(","):
            code = code.strip()
            if code and code in ISO_TO_LINGUA:
                accepted.add(ISO_TO_LINGUA[code])
            elif code:
                logger.warning(f"Unknown language code in ALSO_ACCEPT_LANGUAGES: {code}")
    return accepted


ACCEPTED_LANGS = _build_accepted_set()
PRIMARY_LANG = ISO_TO_LINGUA[ACCEPTED_LANGUAGE]
ACCEPTED_FAST_CODES = {ACCEPTED_LANGUAGE} | {
    code for code in (ALSO_ACCEPT_LANGUAGES.split(",") if ALSO_ACCEPT_LANGUAGES else [])
    if code.strip()
}
DETECTION_LABEL = f"non_{ACCEPTED_LANGUAGE}"

logger.info(
    f"Language config: primary={ACCEPTED_LANGUAGE}, "
    f"also_accept={ALSO_ACCEPT_LANGUAGES or '(none)'}, "
    f"detection_label={DETECTION_LABEL}"
)

# =============================================================================
# Lingua Detector Setup
# =============================================================================

EXCLUDED_LANGUAGES = [
    Language.SHONA,
    Language.XHOSA,
    Language.SOTHO,
    Language.TSONGA,
    Language.TSWANA,
    Language.GANDA,
    Language.LATIN,
    Language.ESPERANTO,
]

supported_languages = [lang for lang in Language.all() if lang not in EXCLUDED_LANGUAGES]
detector = (
    LanguageDetectorBuilder
    .from_languages(*supported_languages)
    .with_preloaded_language_models()
    .build()
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Warming up language detection models...")
    fast_detect("ahoj", k=1)
    detector.detect_language_of("ahoj")
    logger.info("Models loaded, ready to accept requests")
    yield


app = FastAPI(title=f"Lingua Language Detector ({ACCEPTED_LANGUAGE})", lifespan=lifespan)

MIN_CONFIDENCE_THRESHOLD = 0.15
MIN_CONFIDENCE_RATIO = 2.5


class ContentAnalysisHttpRequest(BaseModel):
    contents: List[str] = Field(min_length=1)
    detector_params: Optional[Dict[str, Any]] = None


class ContentAnalysisResponse(BaseModel):
    start: int
    end: int
    text: str
    detection: str
    detection_type: str
    score: float
    evidences: List[Any] = []
    metadata: Dict[str, Any] = {}


def detect_language(text: str) -> List[ContentAnalysisResponse]:
    """
    Detect the primary language of text.
    Returns empty list if text matches the accepted language(s).
    Returns detection if text is in a non-accepted language.
    """
    try:
        if not text or not text.strip():
            return []

        words = re.findall(r'\b\w+\b', text)
        if len(words) == 1:
            word = words[0]

            try:
                lingua_conf = detector.compute_language_confidence_values(word)
                lingua_accepted_prob = 0
                for c in lingua_conf:
                    if hasattr(c, 'language') and hasattr(c, 'value'):
                        if c.language in ACCEPTED_LANGS:
                            lingua_accepted_prob = max(lingua_accepted_prob, c.value)
            except Exception as e:
                logger.error(f"Error computing lingua confidence for '{word}': {e}")
                lingua_accepted_prob = 0.5

            try:
                fast_result = fast_detect(word, k=10)
                fast_accepted_prob = 0
                for r in fast_result:
                    if r.get('lang') in ACCEPTED_FAST_CODES:
                        fast_accepted_prob = max(fast_accepted_prob, r.get('score', 0))
            except Exception as e:
                logger.error(f"Error in fast_detect for '{word}': {e}")
                fast_accepted_prob = 0.5

            avg_accepted_prob = (lingua_accepted_prob + fast_accepted_prob) / 2

            logger.debug(f"avg_accepted_prob: '{avg_accepted_prob}'")

            if avg_accepted_prob >= 0.1:
                logger.debug(f"Allowing '{text}'")
                return []
            else:
                logger.debug(f"Blocking '{text}'")
                try:
                    detected_lang = detector.detect_language_of(text)
                except Exception as e:
                    logger.error(f"Error detecting language for '{text}': {e}")
                    return []

                if detected_lang is None:
                    logger.debug(f"Text: '{text}' | No language detected")
                    return []
                score = 1.0 - avg_accepted_prob
                resp = [ContentAnalysisResponse(
                    start=0,
                    end=len(text),
                    text=text,
                    detection=DETECTION_LABEL,
                    detection_type="language_detection",
                    score=score,
                    evidences=[],
                    metadata={
                        "detected_language": detected_lang.name,
                        "accepted_confidence": avg_accepted_prob
                    }
                )]
                logger.debug(f"Sending: {resp}")
                return resp

        try:
            detected_lang = detector.detect_language_of(text)
        except Exception as e:
            logger.error(f"Error detecting language for '{text}': {e}")
            return []

        if detected_lang is None:
            logger.debug(f"Text: '{text}' | No language detected")
            return []

        if detected_lang in ACCEPTED_LANGS:
            logger.debug(f"Text: '{text}' | {detected_lang.name} detected, allowing")
            return []

        try:
            detected_confidence = detector.compute_language_confidence(text, detected_lang)
            primary_confidence = detector.compute_language_confidence(text, PRIMARY_LANG)
        except Exception as e:
            logger.error(f"Error computing confidence scores for '{text}': {e}")
            return []

        ratio = detected_confidence / primary_confidence if primary_confidence > 0 else float('inf')
        logger.debug(f"Text: '{text}' | Detected: {detected_lang.name} ({detected_confidence:.3f}) vs {PRIMARY_LANG.name} ({primary_confidence:.3f}) | Ratio: {ratio:.2f}x")

        if detected_confidence < MIN_CONFIDENCE_THRESHOLD:
            logger.debug(f"  -> Ignored: confidence {detected_confidence:.3f} < {MIN_CONFIDENCE_THRESHOLD}")
            return []

        if primary_confidence > 0 and detected_confidence < (primary_confidence * MIN_CONFIDENCE_RATIO):
            logger.debug(f"  -> Ignored: ratio < {MIN_CONFIDENCE_RATIO}x")
            return []

        logger.debug(f"  -> Flagged as {DETECTION_LABEL}")

        score = 1.0 - primary_confidence
        return [ContentAnalysisResponse(
            start=0,
            end=len(text),
            text=text,
            detection=DETECTION_LABEL,
            detection_type="language_detection",
            score=score,
            evidences=[],
            metadata={
                "detected_language": detected_lang.name,
                "primary_confidence": primary_confidence
            }
        )]
    except Exception as e:
        logger.error(f"Unexpected error in detect_language for '{text}': {e}")
        return []


@app.get("/health")
def health():
    return "ok"


@app.post("/api/v1/text/contents", response_model=List[List[ContentAnalysisResponse]])
async def analyze_contents(request: ContentAnalysisHttpRequest):
    tasks = [
        asyncio.to_thread(detect_language, content)
        for content in request.contents
    ]

    results = await asyncio.gather(*tasks, return_exceptions=True)

    processed_results = []
    for i, result in enumerate(results):
        if isinstance(result, Exception):
            logger.error(f"Critical error processing content '{request.contents[i]}': {result}")
            processed_results.append([])
        else:
            processed_results.append(result)

    return processed_results


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE"])
async def catch_all(path: str, request: Request):
    body = await request.body()
    logger.warning(f"Unhandled route: {request.method} /{path} - body: {body}")
    return {"error": f"Unknown endpoint: /{path}"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)
