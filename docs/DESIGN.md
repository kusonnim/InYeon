# ITDA — Mobile Design System

**Status:** Draft 0.1 — for visual review and iteration  
**Target:** Android mobile app (Flutter + Kotlin)  
**Intended repository location:** `docs/DESIGN.md`  
**Baseline:** Phase A7.1 pebble tray; later UI refinement must preserve existing behavior

> This document governs presentation and interaction, not authoritative product, API, or persistence semantics. If it conflicts with `docs/PRODUCT.md`, `contracts/openapi.yaml`, privacy rules, or established account boundaries, resolve the conflict explicitly rather than silently changing data behavior.

## 1. Design Intent

ITDA is a quiet place for things people save and may want to revisit. Its character comes from one unusual interaction: rigid, rounded triangular objects falling into an angular open tray. Everything beyond that scene should feel like an ordinary, carefully made mobile app.

The interface should be **warm without being cute, tactile without being decorative, and simple without hiding useful functionality**.

### Core principles

1. **One memorable object, quiet surrounding UI.** The tray and pebbles carry the visual identity. Detail, list, editing, and account screens are understated.
2. **Do not put everything in boxes.** Separate content primarily through hierarchy, spacing, and alignment. Use surfaces or borders only when they communicate a real interactive boundary.
3. **Prioritize, then disclose.** Show the most useful information first. Keep secondary material available without presenting every field at once.
4. **Do not manufacture significance.** No invented summaries, actions, resources, preview images, source facts, dates, or task obligations.
5. **Keep ordinary actions ordinary.** Opening a link, reading a note, editing a title, or managing an account should require familiar mobile interactions.
6. **Minimize copy.** Prefer functional labels: “보관함”, “원본”, “요약”, “추천”, “내 메모”, “보관하기”, “수정”. Do not add greetings, motivational statements, promotional explanations, or AI-themed microcopy.
7. **Preserve trust.** Distinguish original content, generated interpretations, and user edits. An analysis result never means that a user has finished an action.
8. **Design for iteration.** Centralize tokens and keep the physics scene, visual components, and workflow adapters independently replaceable.

## 2. Visual Character

### 2.1 Color palette

Start from the existing Phase A7.1 warm neutrals; treat these as initial design tokens, not an immutable brand palette.

| Role | Light | Dark | Usage |
| --- | --- | --- | --- |
| Canvas | `#F8F6F0` | `#232220` | Main screen and reading surfaces |
| Primary ink | `#25231F` | `#F0EBE1` | Titles, body text, primary controls |
| Secondary ink | `#605B52` | `#C5BEB2` | Metadata and subordinate labels |
| Hairline | `#DDD6CA` | `#4E4942` | Optional, subtle separators only |
| Accent | `#4A5745` | `#C9CFBD` | Functional emphasis, sparingly |
| Soft accent | `#E1E7D8` | `#394338` | Selected/pressed states where necessary |
| Feedback surface | `#EEE9DF` | `#3C3934` | Real interaction feedback, not decorative cards |

- Pebbles are the principal colorful elements: matte sage, clay, sand, dusty blue, lavender, and similar low-saturation tones.
- Do not make the rest of the app a patchwork of pastel panels.
- Avoid gradients, gloss, neon, glassmorphism, glow, ornamental shadows, and decorative illustrations.
- Functional error, warning, and success indicators may depart from the muted palette as needed for accessibility.
- Meet WCAG contrast targets for normal text where feasible (at least 4.5:1); never rely on color alone to convey state.

### 2.2 Typography

**Provisional typeface:** SUIT. Keep it replaceable if real-device review shows that it does not fit.

| Role | Initial size | Weight | Guidance |
| --- | --- | --- | --- |
| Screen heading | 22–26 sp | SemiBold | One strong heading per screen at most |
| Content title | 20–24 sp | SemiBold | Readable across multiple lines |
| Section heading | 15–16 sp | SemiBold | Short, functional labels |
| Body | 15–16 sp | Regular | Approximately 1.45–1.6 line height |
| List title | 15–16 sp | Medium/SemiBold | Up to two lines in compact rows |
| Secondary metadata | 12–14 sp | Regular | Clear contrast and not overloaded |
| Pebble label | Responsive | Medium/SemiBold | Short and upright even if the pebble rotates |

- Avoid more than two strongly distinct type weights in a small region.
- Avoid tiny decorative text, excessive letter spacing, all-caps labels, and bold text used purely for ornament.
- Support Android text scaling. Do not clip headings or controls to preserve a screenshot layout.
- Respect Korean and English text wrapping and natural word boundaries.

### 2.3 Spacing and surfaces

- Use a 4 dp base scale: `4, 8, 12, 16, 24, 32`.
- Default horizontal content padding: approximately 18–20 dp; adjust for narrow screens and tablets.
- Prefer whitespace over dividers, and dividers over cards, when separating unrelated content.
- Do not wrap each summary, recommendation, note, and source field in its own rounded panel.
- Do not add containers just to fill empty space.
- Use a visually distinct surface only for a meaningful drop target, input field, modal, selection, or critical feedback.
- The archive is a plain list, not a stack of rounded cards.

## 3. Information Architecture and Progressive Disclosure

The app has four main experiences:

1. **Tray (home):** tactile selection and lightweight organization of unarchived saves.
2. **All saved:** accessible, searchable list of unarchived content, including items beyond the tray's physics capacity.
3. **Archive:** plain, searchable list of archived content.
4. **Detail:** understand and act on a saved item, then edit, open its source, or archive it.

Account and language controls live in a small, discoverable settings/account destination.

### Screen information budget

- One primary purpose per screen.
- At most one prominent primary action in the initial detail viewport.
- No repeated status chips for values already obvious from the current screen.
- Avoid showing an item's title, source domain, type, date, upload state, analysis state, and recommendation count all at equal visual weight.
- Use small status copy only where it changes what the user can do or needs to know.
- Extra information must remain accessible by scrolling, expanding, or opening a secondary section; never discard data for visual simplicity.

### Detail content hierarchy

The initial view should emphasize:

1. **Title** and a short, truthful source cue.
2. **Primary content**: a real image for an image save, original writing for a personal note, or a grounded short summary for a supported article/link.
3. **One useful recommendation**, if one exists and is relevant; do not force action recommendations to the top or create a recommendation merely to occupy space.
4. **One discoverable primary action**, generally “보관하기” for a non-archived, server-confirmed item.

Secondary content can be disclosed below or through a clear control:

- Full summary and limitations/coverage when applicable.
- Additional recommendations (action, information, or resource), in their existing order unless product logic explicitly provides a ranking.
- Original link, source text, or document reference.
- User notes and editing.
- Dates, sync details, and other metadata when useful.

A direct **“원본 열기”** action should remain easily discoverable for valid web URLs. Notes and titles remain directly tappable to edit when authorized. Long summaries must never hide relevant limitations or falsely imply complete access to a source.

When analysis is pending, show a small, neutral processing indication and keep the original accessible. When analysis fails, state that clearly without removing the original. If there are no recommendations, omit that section rather than displaying filler.

### Content-specific emphasis

| Content type | Leading content | Secondary content |
| --- | --- | --- |
| Image | Actual private original preview, when available | Short summary, notes, recommendations |
| Link/article | Title, grounded summary, clear source action | Full source reference, more recommendations, notes |
| Personal text | Original text or a readable excerpt | Optional summary and recommendations, notes |
| Document/PDF | Real filename/title and source access | Grounded summary, limitations, relevant notes |

Do not use generated stock imagery as a substitute for unavailable originals. Do not claim a server-only private image is visible until an authenticated download implementation exists.

## 4. Home: Angular U-Tray and Rounded Triangular Pebbles

### Tray

- Three straight sides only: left, bottom, and right; fully open at the top.
- Angular U silhouette, simple thin stroke, no rounded card or 3D box treatment.
- The tray is the visual focus; surrounding navigation is minimal.
- A separate, reachable “보관함” drop destination appears beneath the tray.
- Keep an obvious path to **all saved items**, since the physics view deliberately caps the number of visible objects.
- Show an explicit, discoverable sign-in affordance in mock/live modes when signed out; an isolated account icon must not make sign-in effectively invisible.

### Pebble shape

Replace the A7.1 irregular oval silhouettes with **nearly circular rounded triangles**:

- Three subtly perceptible rounded lobes/corners, approximately spaced around the form.
- Almost circular at a glance; not a sharp triangle or a standard rounded-rectangle triangle icon.
- Several distinct, deterministic variants with mild asymmetry.
- Solid, rigid, matte, and visually flat: no squash/stretch or jelly wobble.
- The rendered outline and the Box2D collision fixture must correspond, with a valid convex collision polygon.
- Stable color and shape for each content identity, including across local receipt → server acknowledgment.
- Upright, readable title labels even while the objects rotate; long labels use intelligent clipping or abbreviation without corrupting stored titles.

### Physics and touch

Preserve the A7.1 Forge2D interaction:

- On the first home entry of an app session, existing items fall from above in a short cascade, collide, roll, and settle in the U-tray.
- Stop stepping/rendering when bodies sleep.
- Returning from detail does not replay the cascade or randomly reposition settled objects.
- Newly shared items enter individually.
- Dragging moves a rigid object, respecting collision behavior.
- Tap opens the existing detail view.
- Reduced-motion users get a stable, settled arrangement instead of a cascade.
- Maintain physics bounds and performance limits on small and low-powered devices.
- The physics representation is not the only way to find or organize an item.

## 5. Archive and Completion Behavior

**The user action “place in archive” means they are done with that item for now.** A separate completion step is not required.

- A pending or completed pebble may be dropped into the archive destination.
- A non-archived server-confirmed item also exposes a **“보관하기”** action in details; this is the drag-free alternative.
- Archive directly using the authoritative version-checked `workflow_status = archived` PATCH when the backend permits the transition.
- Do **not** manufacture a separate `completed` save followed by an `archived` save. The existing enum has one workflow value at a time.
- In the UI, `archived` is treated as user-finished-and-stored; do not separately claim the stored enum is `completed`.
- Restore from the archive returns the item to the tray via `workflow_status = pending`, subject to the same version and ownership checks.
- Preserve the original, AI output, user edits, account/realm ownership, and notification visibility independently.
- For local-only items or unsupported transitions, keep the item where it is and show concise truthful feedback. Never fake a successful archive.
- If an existing client guard forbids `pending → archived`, replace that client-side restriction only after checking the server contract and mock behavior; coordinate a contract decision if necessary.
- If a network request fails or returns `409`, leave the item visible until the authoritative result is confirmed; retain the user's context.
- Do not implement notification “Clear all” protection as part of this visual redesign. It remains a separately planned feature requiring Android device verification.

## 6. Library and Archive Lists

- Plain rows with generous touch targets; avoid repeated card backgrounds.
- Leading: genuine thumbnail if safely available; otherwise a simple source-type icon.
- Main text: title (prefer at most two lines).
- Secondary text: source/domain and, when useful, date; do not show every status simultaneously.
- Use quiet row spacing and optional fine dividers.
- Repeated identical URLs can be grouped visually, but each independent saved record remains accessible with its own ID and state.
- Keep search and filtering discoverable; avoid crowding the first viewport with filters before they are needed.
- Archive list is straightforward and does not use pebble physics.
- Support dynamic type, scrolling, account scope changes, and large data sets.

## 7. Detail, Editing, and Settings

### Detail

- Read like a small, well-typeset document, not a dashboard assembled from cards.
- Use one clear title, short source metadata, natural body flow, restrained section headings, and occasional separators.
- Surface the most helpful real content rather than listing all metadata and recommendations.
- Keep source URL opening/copying, private local image preview/zoom, recommendation source actions, and user notes functional.
- Original source, AI summary, and user edits remain distinguishable even when labels are visually quiet.
- Respect the existing analysis coverage/limitations and avoid invented claims.

### Editing

- Tap on a title or notes area to focus the corresponding field in the existing editor.
- Preserve prefilled saved values, field-level PATCH, version conflict handling, and unsaved-draft protection.
- Use minimal input boundaries with clear focus and error indicators.
- Never autosave every keystroke or send an edit when nothing changed.

### Account and settings

- Ordinary native-feeling list layout with plain headings and controls.
- Account/sign-in, language choice (Korean default; English optional), notification permission, and applicable environment/debug information remain accessible.
- Hide testing-only technical detail from production-facing screens.
- Do not bury essential sign-in or recovery behind undiscoverable icons.

## 8. Motion, Interaction, and Accessibility

- Outside the U-tray, use restrained, fast transitions (typically about 150–250 ms).
- No bouncing cards, idle pulsing, ornamental spinners, or continuous motion.
- Minimum practical Android touch target: 48 dp.
- Support screen readers with full titles and meaningful button labels, including for visually truncated pebble text.
- Keyboard/accessibility alternatives exist for actions performed by dragging.
- Support light/dark theme, Android text scaling, small viewport widths, and reduced motion.
- Preserve scroll and editor state when temporarily opening another application and returning.
- Show concise, contextual error messages with an actionable recovery path when possible.

## 9. Copy and Content Policy

Preferred Korean labels (illustrative):

| Concept | Label |
| --- | --- |
| Archive | 보관함 |
| Archive action | 보관하기 |
| Restore | 다시 꺼내기 |
| Original | 원본 |
| Open original | 원본 열기 |
| Summary | 요약 |
| Recommendations | 추천 |
| Notes | 내 메모 |
| Edit | 수정 |
| Processing | 처리 중 |

- Avoid “Welcome back,” “Your journey,” “AI magic,” “Your personal assistant has found…,” or other promotional filler in operational screens.
- Avoid unnecessary counts, duplicate badges, and redundant confirmation copy.
- Keep user-supplied language intact; switching the app locale must not translate source text or generated summaries automatically.
- If information is absent, omit the module unless an explicit empty state is necessary to explain an available action.

## 10. Design Reference Interpretation

Use external guides as *selective inspiration*, not pasted requirements:

- [Content First](https://github.com/TrustOtc/awesome-mobile-design-md/blob/main/design-md/content-first.md): primary reference for hierarchy, uncluttered reading, minimal cards, and calm lists.
- [Nova Mobile](https://github.com/TrustOtc/awesome-mobile-design-md/blob/main/design-md/nova-mobile-design-md.md): reference for touch targets, practical mobile navigation, spacing rhythm, and adaptive behavior.
- [Playful Color](https://github.com/TrustOtc/awesome-mobile-design-md/blob/main/design-md/playful-color.md): reference only for friendly tactile forms and measured color in the pebble scene; do not import its colorful card-heavy controls or continuous spring animations.
- [Material Clean](https://github.com/TrustOtc/awesome-mobile-design-md/blob/main/design-md/material-clean.md): reference for familiar Android controls, semantics, input focus, and feedback.

Priority order: **ITDA product rules → this DESIGN.md → native Android usability → external aesthetic references**. Do not merge external design systems literally or copy brand-specific styles and assets.

## 11. Implementation Boundaries and Acceptance Checklist

This design revision must not rewrite durable sharing, upload/outbox, authenticated sync, notification dismissal/restoration, account isolation, AI processing contracts, or private asset permissions.

Recommended iteration:

1. Create and review this design system first; do not auto-merge it into unrelated work.
2. Change the pebble silhouettes and verify visual-to-physics collision parity.
3. Implement one-step archive behavior against the real existing API contract and mock; keep rollback/conflict behavior.
4. Refine the archive/list and detail hierarchy; reduce unnecessary card wrappers.
5. Apply consistent typography, spacing, and settings affordances.
6. Verify on emulator, then on a real Android phone before declaring visual acceptance.

Review screenshots in Korean and English, light and dark themes, and with large system text. Include: empty tray, mid-cascade, settled tray, large library, image detail, link/article detail, a personal text note, a note with no recommendation, editor, archive, and signed-out settings.

**Acceptance questions:**

- Does the home screen look like solid rounded-triangle stones within three straight tray lines?
- Can a user recognize and act on an item without a wall of text?
- Is any surface boxed for decoration rather than function?
- Do image, link, and personal-note details emphasize the right content?
- Can an uncompleted item go straight to archive with one intentional action?
- Does every previously working action still work, including when the network is offline?
- Is the interface warm and human without becoming childish or generically “AI-styled”?

**This is a reversible visual baseline, not final design approval.** Evaluate real screenshots and device behavior, then revise the document based on observed problems rather than defending an initial mockup.
