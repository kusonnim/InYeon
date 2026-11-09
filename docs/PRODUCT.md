# Product contract

## Identity and problem

People save links, screenshots, and notes across social media, websites, messaging
apps, videos, and documents. They forget these items or lose the reason they saved
them. ITDA turns passive storage into a personalized connection between useful
content and what a person might do or learn next.

The product promise is **Connect what you save with what comes next.** It combines
content understanding with contextual recommendations while minimizing effort.
It is not merely a bookmark manager, generic summarizer, or to-do list. Saving
content creates a library item; it does not imply a task or obligation.

## Confirmed primary journey

1. The user shares text, a URL, an image, or a document using Android's share sheet.
2. The app durably saves the payload and its retry identifier locally before
   acknowledging receipt. File URI access must be preserved or copied before it
   expires. No title, category, or prompt is required.
3. The share interface closes promptly so the user can return to the original app,
   as far as Android permits. Network access and AI are not prerequisites to close.
4. A retryable upload submits the content to the API. The server commits content
   and a background job before acknowledging the server receipt.
5. A worker extracts accessible information, summarizes it, produces optional
   recommendations, and persists results. Failures preserve the saved original.
6. Mobile updates the existing eligible notification. The user opens details or
   selects **Edit / 수정하기**, the sole quick action.
7. Mobile and web expose the same library, source reference, result, edits, and
   workflow state. Dismissed notification items remain in the library.

These are confirmed target behaviors. Their implementation status is tracked in
[STATUS](STATUS.md); the Phase 0 clients demonstrate fixtures.

## Analysis and recommendation policy

- Preserve and distinguish source content, AI interpretations, and user edits.
- Ground summaries in information actually obtained. Record coverage as
  `full_text`, `partial_text`, `metadata_only`, or `unsupported` with limitations.
- Never imply an inaccessible video was watched, or invent a date, deadline,
  price, quote, scene, source fact, or official link.
- `completed` means processing completed for the represented accessible source;
  it does not guarantee external facts are correct. `partial` records materially
  incomplete extraction/analysis. `failed` preserves the item and a failure reason.
- Recommendation kinds: `action` (something the user may do), `information`
  (helpful context), `resource` (a relevant source/document/reference).
- Zero recommendations is valid. A reflective note must not acquire an artificial
  task merely because the system can produce one.
- A generated recommendation is not user acceptance. Record explicit selections,
  corrections, or rejection separately; never turn generation into positive feedback.

## Examples

| Saved content | Grounded understanding | Possible recommendation |
| --- | --- | --- |
| University scholarship notice | Eligibility, deadline and documents only if present | Check eligibility; official application resource |
| Recipe | Available ingredients and instructions | Preparation suggestion, if useful |
| Restaurant review | Characteristics actually described | Relevant visit information with a verifiable source |
| Educational article | Main concepts in accessible text | Learning resource |
| Event announcement | Published date and participation requirements | Check requirements |
| Personal reflection | A factual summary of the note | None |
| Inaccessible video URL | Available metadata only, limitations stated | None unless independently supported |

The same announcement may result in different recommendation priorities for
different people. The source-grounded factual summary must remain consistent.
Example fixtures are synthetic and contain no real user data.

## Personalization

A short initial preference survey and optional MBTI can initialize weak signals.
Explicit preferences, actual selections, corrections, and relevant interaction
history take precedence over personality assumptions as evidence accumulates.
MBTI is optional and cannot override explicit feedback or source facts. Phase 0
defines storage and feedback contracts; it does not implement personalization.

## Notification contract

Each newly shared item is eligible for one automatic notification by default.
An analysis result updates that notification rather than creating a duplicate.
Tapping the body opens details; **Edit / 수정하기** is the only quick-action button.
Dismissal never completes, archives, or deletes content. A dismissed notification
must not automatically reappear after analysis, sync, process restart, or app restart.
Only explicit restoration can reactivate it, under a new generation. A dismissal
from an older generation must not hide the restored notification.

Notification permission denial or OS delivery restrictions do not delete the
library item. Exactly-once visible delivery across OS crashes cannot be promised;
the implementation must use persistent suppression and stable identities to avoid
duplicates as far as the OS permits. Web does not require desktop notifications.

## State vocabulary and privacy

| Concern | Values | Meaning |
| --- | --- | --- |
| Analysis | pending, processing, completed, partial, failed | Processing progress |
| Workflow | pending, completed, archived | User's organization of the content |
| Notification visibility | active, dismissed | Independent presentation/suppression state |
| Recommendation | action, information, resource | Suggestion category, not workflow state |

Private content requires authenticated, ownership-checked access and database RLS.
Uploaded objects remain private. Service credentials must never appear in mobile
or web bundles. See [ARCHITECTURE](ARCHITECTURE.md) for the authorization model.

## Scope and open product decisions

Android is the MVP platform. Flutter/Dart, Kotlin, Next.js, TypeScript, Tailwind,
shadcn/ui, FastAPI, Pydantic, a Python worker, hosted multimodal LLM API, Supabase,
PostgreSQL jobs and FCM are confirmed technology choices. Deployment targets are
Vercel and Railway. GitHub PRs and automated checks support three developers.

Phase 0 excludes complete recommendations, sophisticated personalization, full
native notification behavior, polished production screens, iOS, custom training,
Redis, Celery, and vector databases. Upload limits, retry budgets, retention,
multi-device notification delivery policy, and provider/model selection need
further decisions; provisional contract defaults are documented in ADRs and STATUS.
