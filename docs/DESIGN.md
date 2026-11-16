# ITDA — Mobile Design System

- **Status** Draft 0.5.2 for the Android pebble palette refinement
- **Target** Android mobile app (Flutter + Kotlin)
- **Baseline** Phase A7.4 mixed pebble physics and the A7.3 full-height detail card

> This document governs presentation and interaction, not authoritative product, API, or persistence semantics. If it conflicts with `docs/PRODUCT.md`, `contracts/openapi.yaml`, privacy rules, or established account boundaries, resolve the conflict explicitly rather than silently changing data behavior.

## 1. Design Intent

ITDA is a quiet place for things people save and may want to revisit. Its character comes from rigid, matte circles and rounded triangles falling into an angular open tray. The reading, editing, and account screens use the same understated typography and surfaces.

The interface pairs matte, tactile pebbles with a saturated blue Home header, prominent search, and a title-led information feed.

### Core principles

1. **A recognizable Home.** The solid header establishes blue as the brand color. The tray and pebbles give Home its tactile identity. Detail, list, editing, and account screens use quieter surfaces.
2. **Use surfaces deliberately.** The detail screen groups the saved content and its actions in one large card. Other screens separate content through hierarchy, spacing, and alignment.
3. **Prioritize, then disclose.** Show the most useful information first. Keep secondary material available without presenting every field at once.
4. **Do not manufacture significance.** No invented summaries, actions, resources, preview images, source facts, dates, or task obligations.
5. **Keep ordinary actions ordinary.** Opening a link, reading a note, editing a title, or managing an account should require familiar mobile interactions.
6. **Minimize copy.** Prefer functional labels: “보관함”, “원본”, “요약”, “추천”, “내 메모”, “보관하기”, “수정”. Do not add greetings, motivational statements, promotional explanations, or AI-themed microcopy.
7. **Preserve trust.** Distinguish original content, generated interpretations, and user edits. An analysis result never means that a user has finished an action.
8. **Design for iteration.** Centralize tokens and keep the physics scene, visual components, and workflow adapters independently replaceable.

## 2. Visual Character

### 2.1 Color palette

Use solid blue across the Home status bar, wordmark, and search region. Keep the tray field softly tinted and the recent feed on the main surface. Repeat the accent in selected destinations, primary actions, links, focus, and drop feedback. The design tokens live in `apps/mobile/lib/widgets/itda_theme.dart`.

| Role | Light | Dark | Usage |
| --- | --- | --- | --- |
| Canvas | `#F8FAFD` | `#111923` | Screen background |
| Main surface | `#FFFFFF` | `#1B2635` | Recent feed, navigation, library, and detail card |
| Secondary surface | `#F1F5FA` | `#253346` | Library search field and subdued surfaces |
| Home header | `#0D70DF` | `#144B9E` | Status bar, wordmark, and search surround |
| Header wordmark and system status icons | `#FFFFFF` | `#FFFFFF` | Light foreground on blue |
| Home search surface | `#FFFFFF` | `#102440` | Full-width search entry within the header |
| Tray field | `#E8F4FF` | `#142D49` | Background behind the pebbles and archive drop target |
| Accent and tray stroke | `#0D70DF` | `#92C9FF` | Primary actions, focus, and solid selection indicator |
| Accent surface | `#E8F4FF` | `#213E60` | Source icon backgrounds |
| Accent ink on tinted surfaces | `#075BBA` | `#92C9FF` | Source icons, archive outline control text, and retry |
| Bright blue detail | `#1598FF` | `#1598FF` | Small marker beside the recent section title |
| Primary text | `#18263A` | `#F4F7FC` | Titles and body |
| Pebble labels | `#18263A` | `#111923` | Ink on matte pebble fills |
| Secondary text | `#5C6C83` | `#B3C0D0` | Metadata and inactive navigation |
| Dividers and borders | `#E3E9F2` | `#39495C` | Row rules and surface edges |
| Neutral control outline | `#75859B` | `#8193AA` | Resting input boundaries |
| Positive status | `#2F8067` | `#88CCB4` | Completed analysis |
| Error status | `#B84646` | `#FFA8A8` | Analysis or upload failure and input feedback |

| Matte pebble | Light | Dark |
| --- | --- | --- |
| Mist Blue | `#BFD7F2` | `#6E8FB3` |
| Soft Sky | `#D6E6F8` | `#7C93B3` |
| Sage Mint | `#BFD8C8` | `#738F82` |
| Sand Beige | `#DCC8B3` | `#9A836E` |
| Dusty Lavender | `#CECBE3` | `#8883A3` |
| Soft Olive | `#C8D3B2` | `#7F8B66` |

- The identity hash keeps the same palette positions in both themes. Soft Sky occupies the former Slate position.
- Dark ink on the matte fills gives minimum pebble text contrast ratios of 9.41:1 in light mode and 4.87:1 in dark mode, rounded to two decimals. Focus uses the theme's foreground color so the outline remains visible against the tray.
- White wordmark text has 4.77:1 contrast on the light header and 8.30:1 on the dark header. Use the deeper blue ink for text on the light tray field.
- Do not make the rest of the app a patchwork of pastel panels.
- Avoid gradients, gloss, neon, glassmorphism, glow, ornamental shadows, and decorative illustrations.
- Functional error, warning, and success indicators may depart from the muted palette as needed for accessibility.
- Pair status colors with text. Keep normal text contrast at 4.5:1 or above and use a stronger outline for interactive boundaries.

### 2.2 Typography

Use SUIT Regular and SemiBold.

| Role | Size | Weight | Guidance |
| --- | --- | --- | --- |
| Screen heading | 24–26 sp | SemiBold | The Home wordmark uses 30 sp |
| Detail title | 26 sp | SemiBold | Readable across multiple lines |
| Section heading | 18 sp | SemiBold | Short, functional labels |
| Body | 14–16 sp | Regular | 1.5 line height |
| List title | 16 sp | SemiBold | Use up to two lines at standard scaling and allow full wrapping at larger text sizes |
| Secondary metadata | 13 sp | Regular | Source and relevant status |
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
- Reserve distinct surfaces for the detail card and functional controls such as a drop target, input, selection, or critical feedback.
- The archive is a plain list, not a stack of rounded cards.

## 3. Information Architecture and Progressive Disclosure

The bottom bar has three destinations. **Home / 홈** shows the tray and recent
saves. **Library / 보관함** shows the complete All saved collection. **Account /
내 정보** contains identity, language, notification settings, samples, and licenses.
Each destination retains its state while the user switches tabs. Android Back
returns from a secondary destination to Home. A solid blue selection indicator
and contrasting icon mark the current destination. Inactive icons and labels
use neutral secondary ink on the main surface.

**Archived items / 보관된 항목** open from the Library archive action or the
Home drop target. Detail, archive, editing, and sign-in open above the tab bar
as dedicated routes. The signed-out Home and Account can each open sign-in.
The Account settings shortcut in sign-in selects the Account destination.

### Screen information budget

- One primary purpose per screen.
- At most one prominent primary action in the initial detail viewport.
- No repeated status chips for values already obvious from the current screen.
- Avoid showing an item's title, source domain, type, date, upload state, analysis state, and recommendation count all at equal visual weight.
- Use small status copy only where it changes what the user can do or needs to know.
- Extra information must remain accessible by scrolling, expanding, or opening a secondary section; never discard data for visual simplicity.

### Detail content hierarchy

Use three regions in order. The app bar sits above one full-height content card, followed by a fixed action area on the page background. The card fills the available space, and its content starts at the top. Only the content inside the card scrolls.

The collapsed card emphasizes these elements in order.

1. **Title**, with direct editing for authorized items.
2. **Primary content**, using a real image, original writing, or a grounded summary. Label a generated lead as **AI summary / AI 요약**. Use the original excerpt when a link has no summary and an excerpt is available. A pending, partial, or failed analysis has a concise state label.
3. **One useful recommendation** when available, in the existing order.

Place **Show details / 상세히 보기** directly above **Archive / 보관하기** in the fixed action area. Pin Archive above the Android bottom inset and keep the same position for the restore action on archived items. Use page margins and safe-area padding.

The disclosure changes to **Show less / 접기** and reveals the following information inside the card. Its position and height stay the same.

- Content type, source, and saved date.
- The original link or local PDF action and source-copy controls.
- Source coverage, limitations, and plain-language provenance for generated summaries.
- Additional recommendations under **More recommendations / 추천 더 보기**.
- User notes and applicable notification information.

Present the primary summary after the title and keep its coverage and provenance in the expanded section. Mock, sample, and staging context labels are visible from the first detail view. Expand long excerpts in the same position and avoid repeating primary text or previews in the secondary sections.

Keep the original accessible during analysis or failure. Omit the recommendation area when the list is empty.

### Content-specific emphasis

| Content type | Leading content | Secondary content |
| --- | --- | --- |
| Image | Actual private original preview, when available | Short summary, notes, recommendations |
| Link/article | Title and grounded summary or saved excerpt | Open original, coverage, more recommendations, notes |
| Personal text | Original text or a readable excerpt | Optional summary and recommendations, notes |
| Document/PDF | Real filename/title and a grounded summary when available | Local PDF opening, limitations, relevant notes |

Do not use generated stock imagery as a substitute for unavailable originals. Do not claim a server-only private image is visible until an authenticated download implementation exists.

## 4. Home tray and wordmark

Set **잇다** in white SUIT SemiBold on the full-width blue app bar. Extend the
same surface behind the search entry beneath it. In mock and staging modes,
place the environment label at the far side of the wordmark. Keep the status
bar blue and the wordmark visible as the body scrolls.

The search entry is a button styled as a field. It opens Library and focuses
the editable search field for loaded items. Keep Home ordered as header and
search, tray, archive drop target, and **Recently saved / 최근 저장**. Search
scrolls with the tray and rows so the drop target and feed remain reachable in
short viewports. Show any offline and retry state above the tray.

### Tray

- Three straight sides only: left, bottom, and right; fully open at the top.
- Draw the angular U silhouette with a 2 dp blue stroke over the tinted tray field.
- Tray height follows 28% of the window height, bounded to 232–252 dp. Viewports narrower than 360 dp keep at least 244 dp for legible pebble labels. The existing packing rules determine pebble size and capacity.
- A separate **보관된 항목** drop target sits beneath the tray. Its outlined surface fills with blue when an eligible pebble reaches it. A drag that begins on a pebble keeps control of that pebble inside the scrollable Home.
- Keep an obvious path to **all saved items**, since the physics view deliberately caps the number of visible objects.
- Show an explicit, discoverable sign-in affordance in mock/live modes when signed out; an isolated account icon must not make sign-in effectively invisible.

### Pebble shape

Assign roughly **70% softly rounded triangles and 30% circles** by stable
content identity. Small trays reflect the mix of the items they contain.

- Triangles retain the five A7.3 variants, three recognizable rounded corners,
  and three outward-bowing sides. Draw tangent side and corner arcs, and use the
  same corner radius around the three corners and three side midpoints in Box2D.
- Circles use a constant radius of half the pebble width in the painter and a
  native Box2D circle fixture with the same center and radius.
- Both forms share the rigid matte palette and the same viewport-based width.
- Shape, variant, and color stay stable across navigation and sync. A local
  receipt keeps its identity when the matching server acknowledgment arrives.
- Upright, readable title labels even while the objects rotate; long labels use intelligent clipping or abbreviation without corrupting stored titles.

### Physics and touch

Use the existing Forge2D simulation and archive destination with the compact viewport.

- On the first home entry of an app session, existing items fall from above in a short cascade, collide, roll, and settle in the U-tray.
- Modest damping and low restitution soften collisions as the scene settles.
- Stop stepping/rendering when bodies sleep.
- Returning from detail or another destination keeps resting positions. Pause tray ticks on other destinations.
- Newly shared items enter individually.
- Dragging moves a rigid object, respecting collision behavior.
- Tap opens the existing detail view.
- Reduced-motion users get a stable, settled arrangement instead of a cascade.
- Maintain physics bounds and performance limits on small and low-powered devices.
- The physics representation is not the only way to find or organize an item.

### Recent saves

Show up to three recent visible, unarchived saves from the same account-scoped
library. For a local receipt, use its original receipt time and stable identity
before and after acknowledgment. For a catalog-only save, use its creation time
and stable ID. Use a small blue marker by the section title and blue source
icons on flat, divided rows. Keep titles prominent and put source and actual
status in the secondary line. A row opens the existing detail.
**View all / 전체 보기** selects the full Library.

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
- Secondary text includes source and the actual upload or analysis status. Expanded duplicate saves can also show their saved date and time.
- Use quiet row spacing and fine dividers.
- Repeated identical URLs can be grouped visually, but each independent saved record remains accessible with its own ID and state.
- Pin the search field above the results. Search matches the titles and source labels of loaded items. Pagination expands the set being searched.
- Preserve the query across tabs and detail navigation. Opening a saved item's detail dismisses the search keyboard and keeps it closed when the user returns to the list.
- Archive list is straightforward and does not use pebble physics.
- Support dynamic type, scrolling, account scope changes, and large data sets.

## 7. Detail, Editing, and Settings

### Detail

- Use one large, low-contrast card with a clear title and top-aligned content.
- Keep the disclosure and archive or restore controls below the card, outside its scroll view. Expanded source information uses a single quiet divider and restrained headings.
- Keep source URL opening/copying, private local image preview/zoom, recommendation source actions, and user notes functional.
- Original source, AI summary, and user edits remain distinguishable even when labels are visually quiet.
- Respect the existing analysis coverage/limitations and avoid invented claims.

### Editing

- Tap on a title or notes area to focus the corresponding field in the existing editor.
- Keep the form scrollable above the Android keyboard. Pin Save and Cancel above the keyboard, using app bar actions when vertical space is limited.
- Preserve prefilled saved values, field-level PATCH, version conflict handling, and unsaved-draft protection.
- Use minimal input boundaries with clear focus and error indicators.
- Never autosave every keystroke or send an edit when nothing changed.

### Account and settings

- Ordinary native-feeling list layout with plain headings and controls.
- Show the active account identity and sign-out, or a short entry to the dedicated sign-in page.
- The dedicated page has a title, email and password fields, a primary button, and localized progress and errors. Android Back returns to the previous screen. Successful sign-in returns to the previous context with the refreshed account scope.
- Keep language choice (Korean default and English optional), notification permission, licenses, and applicable environment information in Account settings.
- Hide testing-only technical detail from production-facing screens.
- Do not bury essential sign-in or recovery behind undiscoverable icons.

## 8. Motion, Interaction, and Accessibility

- Use gentle acceleration and deceleration. A pebble opens details with a small scale and fade over 200 ms and returns over 160 ms. Reduced motion opens and closes the route immediately.
- Animate content height inside the detail card over 180 ms. Update the contents immediately with reduced motion. Keep the current scroll offset when possible and clamp it to the available range when collapsing.
- Let the tray sleep at rest and confine the analysis loop to the visible processing indicator.
- Minimum practical Android touch target: 48 dp.
- Support screen readers with full titles and meaningful button labels, including for visually truncated pebble text.
- Keyboard/accessibility alternatives exist for actions performed by dragging.
- Support light/dark theme, Android text scaling, small viewport widths, landscape, gesture navigation insets, and reduced motion.
- Preserve scroll and editor state when temporarily opening another application and returning.
- Show concise, contextual error messages with an actionable recovery path when possible.

### Connecting Pebbles analysis indicator

A small matte circle and rounded triangle approach over a few points, pause
with a thin line between them, and return to their starting positions after the
line fades. The 2.6-second Flutter loop repaints the drawing inside the main
card. A static connected pair accompanies the same status label with reduced
motion. The loop pauses offscreen, on a covered route, and in the background.

| State | Detail presentation |
| --- | --- |
| Local receipt awaiting upload | Existing save and upload status alongside the original |
| Acknowledged and pending | Quiet analysis waiting label |
| Processing | Connecting Pebbles and **정리 중 / Organizing**, with the original and ordinary actions available |
| Completed | Available summary and recommendations in their existing places |
| Partial | Available result and a partial status, with actual coverage and limitations in the disclosure |
| Failed | Existing analysis failure label and access to the original |

The visible state follows the received content version, including when an
open detail receives a newer account-scoped sync snapshot. The card and
footer keep their bounds as the inner content changes. The animation cycle
only drives the drawing.

## 9. Copy and Content Policy

Preferred Korean labels (illustrative):

| Concept | Label |
| --- | --- |
| Library (all saved) | 보관함 |
| Archived items | 보관된 항목 |
| Recently saved | 최근 저장 |
| Archive action | 보관하기 |
| Restore | 다시 꺼내기 |
| Original | 원본 |
| Open original | 원본 열기 |
| Generated summary | AI 요약 |
| Recommendations | 추천 |
| Notes | 내 메모 |
| Show details | 상세히 보기 |
| Show less | 접기 |
| Edit | 수정 |
| Processing in details | 정리 중 |

- Avoid “Welcome back,” “Your journey,” “AI magic,” “Your personal assistant has found…,” or other promotional filler in operational screens.
- Avoid unnecessary counts, duplicate badges, and redundant confirmation copy.
- Keep user-supplied language intact; switching the app locale must not translate source text or generated summaries automatically.
- If information is absent, omit the module unless an explicit empty state is necessary to explain an available action.

## 10. Design Reference Interpretation

Use external guides as *selective inspiration*, not pasted requirements:

- Reference for discoverable search, clear section hierarchy, and title-led opportunity rows. [Linkareer recruitment home](https://linkareer.com/recruit-home)
- [Content First](https://github.com/TrustOtc/awesome-mobile-design-md/blob/main/design-md/content-first.md): primary reference for hierarchy, uncluttered reading, minimal cards, and calm lists.
- [Nova Mobile](https://github.com/TrustOtc/awesome-mobile-design-md/blob/main/design-md/nova-mobile-design-md.md): reference for touch targets, practical mobile navigation, spacing rhythm, and adaptive behavior.
- [Playful Color](https://github.com/TrustOtc/awesome-mobile-design-md/blob/main/design-md/playful-color.md): reference only for friendly tactile forms and measured color in the pebble scene; do not import its colorful card-heavy controls or continuous spring animations.
- [Material Clean](https://github.com/TrustOtc/awesome-mobile-design-md/blob/main/design-md/material-clean.md): reference for familiar Android controls, semantics, input focus, and feedback.

Priority order: **ITDA product rules → this DESIGN.md → native Android usability → external aesthetic references**. Do not merge external design systems literally or copy brand-specific styles and assets.

## 11. Implementation Boundaries and Acceptance Checklist

This design revision must not rewrite durable sharing, upload/outbox, authenticated sync, notification dismissal/restoration, account isolation, AI processing contracts, or private asset permissions.

Review matched A7.5 and A7.5.1 Home captures with the same Android emulator,
light theme, display settings, and mock catalog. Check the blue status bar
and header, search focus, and the tray and feed at 320 dp with 200% text in both
themes. Exercise tab and scroll state, pebble drag and archive restoration,
and offline access to saved copies. Record the Flutter and Android checks and
device evidence in [STATUS](STATUS.md).

Capture the full collapsed and expanded detail layout. Verify fixed card bounds and actions while scrolling, short and long content, light and dark themes, both app languages, narrow and landscape viewports, large text, and keyboard and system insets. Review the image detail, personal note, dedicated sign-in, and dark tray.

**Acceptance questions:**

- Do matte circles and rounded triangles look solid within the three straight tray lines?
- Can a user recognize and act on an item without a wall of text?
- Is any surface boxed for decoration rather than function?
- Do image, link, and personal-note details emphasize the right content?
- Can an uncompleted item go straight to archive with one intentional action?
- Does every previously working action still work, including when the network is offline?
- Does the full-width blue header make Home recognizable and put search in view on first entry?

**This is a reversible visual baseline, not final design approval.** Evaluate real screenshots and device behavior, then revise the document based on observed problems rather than defending an initial mockup.
