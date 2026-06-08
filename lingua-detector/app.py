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


app = FastAPI(title="Lingua Language Detector (Slovak)", lifespan=lifespan)

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
    Returns empty list if text is Slovak.
    Returns detection only if text is non-Slovak.
    """
    try:
        if not text or not text.strip():
            return []

        words = re.findall(r'\b\w+\b', text)
        if len(words) == 1:
            word = words[0]

            try:
                lingua_conf = detector.compute_language_confidence_values(word)
                lingua_slovak_prob = 0
                for c in lingua_conf:
                    if hasattr(c, 'language') and hasattr(c, 'value'):
                        if c.language == Language.SLOVAK:
                            lingua_slovak_prob = c.value
                            break
            except Exception as e:
                logger.error(f"Error computing lingua confidence for '{word}': {e}")
                lingua_slovak_prob = 0.5

            try:
                fast_result = fast_detect(word, k=10)
                fast_slovak_prob = 0
                for r in fast_result:
                    if r.get('lang') == 'sk':
                        fast_slovak_prob = r.get('score', 0)
                        break
            except Exception as e:
                logger.error(f"Error in fast_detect for '{word}': {e}")
                fast_slovak_prob = 0.5

            avg_slovak_prob = (lingua_slovak_prob + fast_slovak_prob) / 2

            logger.debug(f"avg_slovak_prob: '{avg_slovak_prob}'")

            if avg_slovak_prob >= 0.1:
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
                score = 1.0 - avg_slovak_prob
                resp = [ContentAnalysisResponse(
                    start=0,
                    end=len(text),
                    text=text,
                    detection="non_slovak",
                    detection_type="language_detection",
                    score=score,
                    evidences=[],
                    metadata={
                        "detected_language": detected_lang.name,
                        "slovak_confidence": avg_slovak_prob
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

        if detected_lang == Language.SLOVAK:
            logger.debug(f"Text: '{text}' | Slovak detected, allowing")
            return []

        # Also allow Czech — very close to Slovak and often detected interchangeably
        if detected_lang == Language.CZECH:
            logger.debug(f"Text: '{text}' | Czech detected, allowing (close to Slovak)")
            return []

        try:
            detected_confidence = detector.compute_language_confidence(text, detected_lang)
            slovak_confidence = detector.compute_language_confidence(text, Language.SLOVAK)
        except Exception as e:
            logger.error(f"Error computing confidence scores for '{text}': {e}")
            return []

        ratio = detected_confidence / slovak_confidence if slovak_confidence > 0 else float('inf')
        logger.debug(f"Text: '{text}' | Detected: {detected_lang.name} ({detected_confidence:.3f}) vs Slovak ({slovak_confidence:.3f}) | Ratio: {ratio:.2f}x")

        if detected_confidence < MIN_CONFIDENCE_THRESHOLD:
            logger.debug(f"  -> Ignored: confidence {detected_confidence:.3f} < {MIN_CONFIDENCE_THRESHOLD}")
            return []

        if slovak_confidence > 0 and detected_confidence < (slovak_confidence * MIN_CONFIDENCE_RATIO):
            logger.debug(f"  -> Ignored: ratio < {MIN_CONFIDENCE_RATIO}x")
            return []

        logger.debug(f"  -> Flagged as non-Slovak")

        score = 1.0 - slovak_confidence
        return [ContentAnalysisResponse(
            start=0,
            end=len(text),
            text=text,
            detection="non_slovak",
            detection_type="language_detection",
            score=score,
            evidences=[],
            metadata={
                "detected_language": detected_lang.name,
                "slovak_confidence": slovak_confidence
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
