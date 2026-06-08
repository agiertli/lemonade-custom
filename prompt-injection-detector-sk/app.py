import asyncio
import logging
import os
from contextlib import asynccontextmanager
from typing import Any, Dict, List, Optional

from fastapi import FastAPI, Request
from pydantic import BaseModel, Field
from transformers import pipeline

log_level = os.getenv("LOG_LEVEL", "INFO").upper()
logging.basicConfig(level=getattr(logging, log_level, logging.INFO))
logger = logging.getLogger(__name__)

MODEL_NAME = os.getenv("MODEL_NAME", "proventra/mdeberta-v3-base-prompt-injection")

classifier = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global classifier
    logger.info(f"Loading model: {MODEL_NAME}")
    classifier = pipeline("text-classification", model=MODEL_NAME)
    # Warm up
    classifier("ahoj")
    logger.info("Model loaded, ready to accept requests")
    yield


app = FastAPI(title="Multilingual Prompt Injection Detector", lifespan=lifespan)


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


def detect_injection(text: str) -> List[ContentAnalysisResponse]:
    if not text or not text.strip():
        return []

    try:
        result = classifier(text)
        label = result[0]["label"]
        score = result[0]["score"]

        logger.debug(f"Text: '{text}' | Label: {label} | Score: {score:.4f}")

        if label == "INJECTION" and score > 0.5:
            return [ContentAnalysisResponse(
                start=0,
                end=len(text),
                text=text,
                detection="prompt_injection",
                detection_type="INJECTION",
                score=score,
                evidences=[],
                metadata={"model": MODEL_NAME, "label": label}
            )]

        return []
    except Exception as e:
        logger.error(f"Error detecting injection for '{text}': {e}")
        return []


@app.get("/health")
def health():
    return "ok"


@app.post("/api/v1/text/contents", response_model=List[List[ContentAnalysisResponse]])
async def analyze_contents(request: ContentAnalysisHttpRequest):
    tasks = [
        asyncio.to_thread(detect_injection, content)
        for content in request.contents
    ]
    results = await asyncio.gather(*tasks, return_exceptions=True)

    processed_results = []
    for i, result in enumerate(results):
        if isinstance(result, Exception):
            logger.error(f"Error processing '{request.contents[i]}': {result}")
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
