import os
import logging
from typing import List, Literal
from pydantic import BaseModel, Field
from openai import AsyncOpenAI
from dotenv import load_dotenv

load_dotenv()

api_key = os.getenv("ITDA_LLM_API_KEY")
if not api_key:
    raise ValueError("ITDA_LLM_API_KEY is missing from .env")


logger = logging.getLogger(__name__)

# Pydantic Schemas for Strict Type Safety &amp; Zero Parsing Errors
class RecommendationItem(BaseModel):
    title: str = Field(description="Recommendation title in natural, fluent Korean")
    why: str = Field(description="One sentence rationale strictly derived from source text in Korean")

class Recommendations(BaseModel):
    action: List[RecommendationItem] = Field(
        default_factory=list,
        description="Direct actionable steps for the user. Return empty array if no explicit action exists."
    )
    info: List[RecommendationItem] = Field(
        default_factory=list,
        description="Background knowledge, caveats, or comparison tips."
    )
    material: List[RecommendationItem] = Field(
        default_factory=list,
        description="Reference materials, links, or official forms."
    )

class ExtractionResult(BaseModel):
    status: Literal["SUCCESS", "INSUFFICIENT_CONTENT", "ERROR"]
    summary: str = Field(description="2-3 sentence core summary in Korean")
    recommendations: Recommendations


# High-Performance System Prompt (English Instructions, Korean Outputs)
SYSTEM_PROMPT = """ You are the core AI analysis engine for 'ITDA', a personalized smart content assistant for university students. Analyze the user-provided text/notices/articles and produce concise summaries and 3-category recommendations.
[STRICT GROUNDING &amp; BEHAVIOR RULES]
1. Zero Hallucination: Synthesize ONLY facts explicitly stated in the source text. Never invent unmentioned dates, fees, eligibility criteria, or URLs.
2. Content Type Distinction (Promotional vs General):
    - Promotional / Commercial Content (광고성/이벤트 정보):
    * Detect commercial marketing, referral links, affiliate ads, sponsored reviews, or clickbait promotional events.
    * DO NOT generate artificial 'action' items urging the user to buy products, register for clickbait events, or sign up for commercial services. Set 'action' to an empty array ([]).
    * Strip away marketing hype and extract only objective facts (e.g., event period, discount conditions) in the summary and 'info' section.
    - General Informative Content (일반 정보):
    * University notices, academic posts, IT/tech guides, news, and genuine reviews.
    * Extract key takeaways into 'summary', background knowledge into 'info', and official actionable steps (e.g., submit form, check eligibility) into 'action'.
3. Recommendation Categorization:
    - action: Direct tasks for the user (e.g., submit official application, verify qualification). If no explicit action or deadline exists, return an EMPTY array ([]). NEVER force artificial tasks for casual/emotional posts or commercial ads.
    - info: Critical caveats, income thresholds, background knowledge, or unbiased comparison tips.
    - material: Directly referenced links, forms, or official portals.
4. Language Constraint: All generated output fields ('summary', 'title', 'why') MUST be written in natural, fluent Korean.
5. Edge Case Handling:
    - Insufficient/Access Restricted Content (e.g., "ㅋㅋ", "대박", login walls, deleted posts): Set status to "INSUFFICIENT_CONTENT", summary to "분석할 내용이 부족하거나 접근 권한이 없습니다.", and return empty arrays for all recommendation categories.
    - Casual / Emotional Posts &amp; Pure Commercial Spam: Set action to an empty array ([]). """

# Initialize Async Client
client = AsyncOpenAI(
    api_key=api_key,
    base_url="https://generativelanguage.googleapis.com/v1beta/openai/"
)

async def analyze_content_async(content_text: str, user_profile: dict = None) -> ExtractionResult:
    """ Asynchronously analyzes content text and returns a strictly typed ExtractionResult. """
    if not content_text or len(content_text.strip()) < 5:
        return ExtractionResult(
            status="INSUFFICIENT_CONTENT",
            summary="분석할 내용이 부족합니다.",
            recommendations=Recommendations()
        )

    user_context = f"\n[User Profile]: {user_profile}" if user_profile else ""
    user_prompt = f"{user_context}\n\n[Source Content]:\n{content_text}"

    try:
        # Utilizing Structured Outputs for guaranteed schema adherence
        response = await client.beta.chat.completions.parse(
            model="gemini-3.8-flash",
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": user_prompt}
            ],
            response_format=ExtractionResult,
            temperature=0.1
        )
        parsed = response.choices[0].message.parsed

        if parsed is None:
            raise ValueError("AI response parsing failed.")

        return parsed

    except Exception as e:
        logger.error(f"AI Extraction error: {str(e)}", exc_info=True)

        return ExtractionResult(
            status="ERROR",
            summary="AI 분석 중 오류가 발생했습니다. 잠시 후 다시 시도해 주세요.",
            recommendations=Recommendations()
    )