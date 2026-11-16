# Korean opportunity URL audit

The PR #17 worktree verified these public detail URLs on 2026-11-16
(Asia/Seoul). The fetcher used the ITDA user agent and checked robots.txt for
each destination before requesting its detail page. The byte counts are the
final observed detail response sizes.

| Case | DNS and TLS | Robots policy | Detail response | Public body and JavaScript | Extraction |
| --- | --- | --- | --- | --- | --- |
| [Linkareer activity](https://linkareer.com/activity/349663) | Two vetted IPv4 addresses, verified HTTPS | HTTP 200, allowed | HTTP 200, no redirects, text/html, 231,116 bytes | The HTML contains the announcement. The Next.js scripts were unnecessary for extraction. | **PASS**, 1,400 characters |
| [Wevity video contest](https://www.wevity.com/?c=find&s=1&gbn=view&gp=1&ix=107425) | One vetted IPv4 address, verified HTTPS on both hops | HTTP 200, allowed on both hops | Same-host HTTP 302 from view to viewok, then HTTP 200, text/html, 55,741 bytes | The HTML contains the announcement and application instructions. | **PASS**, 723 characters |
| [Thinkgood design contest](https://thinkcontest.com/thinkgood/user/contest/view.do?contest_pk=112004) | One vetted IPv4 address, verified HTTPS | HTTP 200, allowed | HTTP 200, no redirects, text/html, 147,314 bytes | The browser displays the public default tab through its renderer. Its title, fields, and published body are already in the HTML. | **PASS**, 4,018 characters |

The baseline Linkareer and Wevity results mixed the notice with unrelated page
content. Thinkgood's generic body selection omitted its notice. Its detail
form wraps the whole notice, and its renderer references the public
announcement body by content ID. The extractor preserves that source for the
current tab when the renderer identifies it and filters other hidden content.

## Source evidence

### Linkareer

- The visible heading names the 28th Linkareer Content Editor recruitment.
  The organization heading identifies Linkareer. The notice describes eligible
  student statuses and requires both a Naver Blog and an Instagram account.
- The application period row ends on September 17, 2026. The verified cutoff
  is date-only. The required assignment is a card-news post and
  its blog link, submitted through the online form. The posted heading and
  form label establish the [application link](https://vo.la/JVnkaO2). The
  audit verified the page's link label. [Source notice](https://linkareer.com/activity/349663)
- **Gemini PASS.** One bounded request used the extracted notice with
  Gemini 3.6 Flash. It returned HTTP 200, a structured summary with the
  notice title and closing date, and seven recommendations. The response
  reported 1,295 prompt tokens, 655 completion tokens, and 1,950 total.

### Wevity

- The visible heading and organizer row identify the 2026 Korea Hydro &
  Nuclear Power short-video contest. The body permits individual entrants
  excluding company employees. The deadline shown in the body is July 30,
  2026, at 17:00.
- Entrants upload an unlisted YouTube video of up to 58 seconds, then enter
  their concept and video URL through the organizer's event page. The
  announcement describes a participation button and gives no direct form
  URL. It specifies the submission material without a separate document list.
  [Source notice](https://www.wevity.com/?c=find&s=1&gbn=viewok&gp=1&ix=107425)
- Gemini was untested for this case. The audit used its one model request on
  Linkareer.

### Thinkgood

- The title region identifies the 21st Korea Spatial Design National
  Competition. The organizer row names the Korea Spatial Design Association.
  The eligibility grid lists undergraduate students, graduate students, and
  the public. The body describes related-field professionals and students
  in relevant majors.
- The first deadline is November 21, 2026, at 17:00 for the email submission.
  The second stage is an in-person submission on November 30 from 10:00
  to 17:00. The notice describes the application form and PDF email
  submission, and lists a work statement and a second-stage entry form.
  The association homepage provides the form. The notice gives no direct
  online submission URL. [Source notice](https://thinkcontest.com/thinkgood/user/contest/view.do?contest_pk=112004)
- Gemini was untested for this case. The audit used its one model request on
  Linkareer.

## Fallback verification

The targeted parser and Worker suite passed 34 tests. It distinguishes robots
denial and unavailable policies, content restrictions, access gates,
JavaScript shells, missing detail layouts, rate limits, and transient server
errors. An unreadable URL retains the original receipt, skips model analysis,
and returns the specific limitation plus the option to share text or a
screenshot. Existing detail screens display those limitations. A single public
JobPosting JSON-LD record can provide partial coverage when present.
