import asyncio
import socket

import httpx
import pytest

from extractors import public_page


ARTICLE = """
<!doctype html><html><head><title>Campus recruitment</title></head><body>
<nav>Menu navigation</nav><form>Newsletter signup</form>
<main><article><h1>Applications open</h1>
<p>Current students may apply by 20 November using the admissions form.</p>
<p>A short cover letter and a current transcript are required.</p>
<script>alert("script text")</script><p hidden>hidden text</p>
<div style="display: none">concealed text</div><aside>sidebar noise</aside>
</article></main><footer>Footer noise</footer></body></html>
"""


def html(body, status=200, **headers):
    return httpx.Response(
        status, headers={"Content-Type": "text/html; charset=utf-8", **headers},
        stream=httpx.ByteStream(body.encode()),
    )


@pytest.fixture
def request_page(monkeypatch):
    def fetch(handler, url="https://campus.example/start", addresses=("8.8.8.8",)):
        calls = []

        def transport(request):
            calls.append(request)
            return handler(request)

        def direct_transport(*, trust_env):
            assert trust_env is False
            return httpx.MockTransport(transport)

        async def resolve(hostname, port, **kwargs):
            return [
                (socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", (address, port))
                for address in addresses
            ]

        async def exercise():
            monkeypatch.setattr(asyncio.get_running_loop(), "getaddrinfo", resolve)
            return await public_page.extract_public_page(url)

        monkeypatch.setattr(httpx, "AsyncHTTPTransport", direct_transport)
        return asyncio.run(exercise()), calls

    return fetch


def test_extracts_title_and_article_after_vetted_redirect(request_page):
    def handle(request):
        if request.url.path == "/robots.txt":
            return httpx.Response(404)
        if request.url.path == "/start":
            return httpx.Response(302, headers={"location": "https://apply.example/notice"})
        return html(ARTICLE)

    page, requests = request_page(handle)
    assert page.coverage == "full_text" and len(page.limitations) == 1
    assert page.text.startswith("Campus recruitment\n\nApplications open")
    assert "20 November" in page.text and "current transcript" in page.text
    for noise in ("navigation", "Newsletter", "script text", "hidden text", "concealed text", "sidebar", "Footer"):
        assert noise not in page.text
    assert [request.headers["host"] for request in requests] == [
        "campus.example", "campus.example", "apply.example", "apply.example",
    ]
    for request in requests:
        assert request.url.host == "8.8.8.8"
        assert request.extensions["sni_hostname"] == request.headers["host"]
        assert not {"authorization", "cookie", "referer"} & request.headers.keys()


@pytest.mark.parametrize("url", [
    "http://127.0.0.1/",
    "http://192.168.1.8/",
    "http://[::1]/",
    "https://[::ffff:127.0.0.1]/",
    "https://campus.example:8443/notice",
    "https://campus.example/notice?access_token=placeholder",
    "https://user:password@campus.example/notice",
])
def test_rejects_private_destinations_and_credentials_before_connecting(request_page, url):
    page, requests = request_page(lambda _: pytest.fail("Unexpected connection"), url)
    assert page.coverage == "unsupported" and page.text == "" and requests == []


def test_rejects_dns_with_private_and_public_answers(request_page):
    page, requests = request_page(lambda _: pytest.fail("Unexpected connection"), addresses=("8.8.8.8", "10.0.0.1"))
    assert page.coverage == "unsupported" and requests == []


def test_rechecks_redirect_destination(request_page):
    def handle(request):
        if request.url.path == "/robots.txt":
            return httpx.Response(404)
        return httpx.Response(302, headers={"location": "https://127.0.0.1/notice"})

    page, requests = request_page(handle)
    assert page.coverage == "unsupported" and not page.text
    assert [request.url.path for request in requests] == ["/robots.txt", "/start"]


@pytest.mark.parametrize(("reply", "failure"), [
    (lambda: httpx.Response(401), "access_restricted"),
    (lambda: html("<title>Sign in to campus</title><main><h1>Log in</h1><form></form></main>"), "access_restricted"),
    (lambda: html(ARTICLE, **{"X-Robots-Tag": "nosnippet"}), "content_policy"),
    (lambda: html(ARTICLE.replace("</head>", '<script type="application/ld+json">'
                                              '{"isAccessibleForFree":false}</script></head>')), "access_restricted"),
])
def test_restricted_page_has_only_metadata(request_page, reply, failure):
    page, _ = request_page(lambda req: httpx.Response(404) if req.url.path == "/robots.txt" else reply())
    assert page.text == "" and page.coverage == "metadata_only"
    assert page.failure == failure and page.limitations[-1] == public_page.SHARE_FALLBACK


def test_robots_exclusion_prevents_page_request(request_page):
    def handle(request):
        assert request.url.path == "/robots.txt"
        return httpx.Response(
            200, headers={"Content-Type": "text/plain"},
            stream=httpx.ByteStream(b"User-agent: *\nDisallow: /sta*\n"),
        )

    page, requests = request_page(handle)
    assert page.text == "" and page.coverage == "metadata_only" and len(requests) == 1
    assert page.failure == "robots_disallowed" and page.limitations[-1] == public_page.SHARE_FALLBACK


def test_unavailable_robots_policy_never_probes_the_detail(request_page):
    page, requests = request_page(lambda _: httpx.Response(403))
    assert page.failure == "robots_unavailable"
    assert [request.url.path for request in requests] == ["/robots.txt"]


@pytest.mark.parametrize(("robots_status", "page_status", "failure"), [
    (503, None, "robots_unavailable"),
    (404, 429, "rate_limited"),
    (404, 503, "server_error"),
])
def test_temporary_errors_keep_the_specific_reason_and_fallback(request_page, robots_status, page_status, failure):
    def handle(request):
        if request.url.path == "/robots.txt":
            return httpx.Response(robots_status)
        assert page_status is not None
        return httpx.Response(page_status)

    with pytest.raises(public_page.PageTemporarilyUnavailable) as error:
        request_page(handle)
    assert error.value.failure == failure
    assert error.value.limitations[-1] == public_page.SHARE_FALLBACK


def test_javascript_shell_and_missing_opportunity_layout_are_not_access_gates(request_page):
    shell = """<title>Public contest</title><header>Site menu</header><div id="__next"></div>
           <script src="/page.js"></script><noscript>Please enable JavaScript.</noscript>"""
    url = "https://linkareer.com/activity/1"
    for body, failure in [(shell, "javascript_required"), (ARTICLE, "parse_error")]:
        page, _ = request_page(lambda req: httpx.Response(404) if req.url.path == "/robots.txt" else html(body), url)
        assert not page.text and page.coverage == "metadata_only" and page.failure == failure


def test_linkareer_isolates_the_notice_and_keeps_the_labeled_application_link(request_page):
    document = """
    <title>Recruitment site</title><main><header><h1>캠퍼스 에디터 모집</h1></header>
    <div class="activity-info"><dl><dt>접수기간</dt><dd>2026.09.10 ~ 2026.09.17</dd></dl></div>
    <header class="organization-info"><h2 class="organization-name">에디터 운영팀</h2></header>
    <article id="DETAIL"><section><h2 class="detail-title">상세내용</h2>
    <p>지원 자격: 대학 재학생</p><p>제출서류: 신청서</p>
    <p>지원폼 : <a href="https://registration.example/form">온라인 양식</a></p>
    <p>참고 <a href="https://organization.example/">홈페이지</a></p>
    <a href="https://registration.example/form?access_token=fixture">신청하기</a>
    </section><section><h2>합격스펙</h2><p>개별 사용자 경험</p></section></article>
    <h2>다른 공고</h2></main>
    """
    page, _ = request_page(lambda req: httpx.Response(404) if req.url.path == "/robots.txt" else html(document),
                           "https://linkareer.com/activity/1")
    assert page.coverage == "full_text" and page.failure is None and page.text.startswith("캠퍼스 에디터 모집\n")
    for value in ("주최: 에디터 운영팀", "접수기간: 2026.09.10 ~ 2026.09.17", "대학 재학생", "제출서류: 신청서"):
        assert value in page.text
    assert "공고의 지원 링크: https://registration.example/form" in page.text
    for other in ("합격스펙", "개별 사용자 경험", "다른 공고", "organization.example", "access_token"):
        assert other not in page.text


@pytest.mark.parametrize(("url", "document"), [
    ("https://www.wevity.com/?c=find&gbn=viewok&ix=1", """
    <main>다른 공고</main><div class="contest-detail"><h6 class="tit">공개 공모전</h6>
    <ul class="cd-info-list"><li><span class="tit">주최/주관</span>문화재단</li>
    <li><span class="tit">접수기간</span>2026-11-20 17:00<span class="cil-dday">D-1</span></li></ul>
    <div id="viewContents"><p>접수방법: 이메일로 참가 신청서 제출</p></div></div>
    """),
    ("https://thinkcontest.com/thinkgood/user/contest/view.do?contest_pk=1", """
    <main>다른 공고</main><form id="detailForm"><h3>팀원 모집</h3>
    <div class="view-header"><span class="contest-view__title">공개 공모전</span></div>
    <div class="content-detail__top"><div class="info">
    <div><div class="tit">주최</div><div class="txt">문화재단</div></div>
    <div><div class="tit">접수기간</div><div class="txt">2026-11-20 17:00</div></div></div></div>
    <div id="tab01" class="current"><div id="contest_content" style="display: none">
    <p>접수방법: 이메일로 참가 신청서 제출</p><p style="display: none">숨겨진 별도 문구</p></div>
    <naver-content content-id="contest_content"></naver-content></div></form>
    """),
])
def test_contest_extracts_the_notice_outside_the_generic_main(request_page, url, document):
    page, _ = request_page(lambda req: httpx.Response(404) if req.url.path == "/robots.txt" else html(document), url)
    assert page.coverage == "full_text" and page.text.startswith("공개 공모전\n")
    assert "문화재단" in page.text and "접수기간: 2026-11-20 17:00" in page.text
    assert "이메일로 참가 신청서 제출" in page.text
    for noise in ("다른 공고", "D-1", "숨겨진 별도 문구", "팀원 모집"):
        assert noise not in page.text


def test_thinkgood_template_without_public_display_is_not_read(request_page):
    document = """
    <form id="detailForm"><h3>공개 공모전</h3><div id="tab01" class="current">
    <div id="contest_content" style="display:none"><p>표시되지 않는 문구</p></div>
    <naver-content content-id="unrelated"></naver-content></div></form>
    """
    url = "https://thinkcontest.com/thinkgood/user/contest/view.do?contest_pk=1"
    page, _ = request_page(lambda req: httpx.Response(404) if req.url.path == "/robots.txt" else html(document), url)
    assert page.coverage == "metadata_only" and page.failure == "parse_error" and not page.text


def test_public_job_posting_json_ld_is_partial_and_keeps_expiration_distinct(request_page):
    document = r"""<title>Careers</title><div id="root"></div><script src="/app.js"></script>
    <script type="application/ld+json">{"@graph":[{"@type":"Organization","name":"Site host"},
    {"@type":"JobPosting","title":"Research assistant","hiringOrganization":{"name":"Library"},
    "validThrough":"2026-11-25","qualifications":"Enrolled students",
    "description":"<p>Submit a short CV.</p>\u003cscript>other context\u003c/script>",
    "url":"https://campus.example/posting",
    "potentialAction":{"@type":"ApplyAction","target":"https://application.example/form"}}]}</script>
    """
    page, _ = request_page(lambda req: httpx.Response(404) if req.url.path == "/robots.txt" else html(document))
    assert page.coverage == "partial_text" and page.failure is None
    assert "채용 기관: Library" in page.text and "지원 자격: Enrolled students" in page.text
    assert "공고 게시 유효기간: 2026-11-25" in page.text and "접수마감" not in page.text
    assert "공고의 지원 링크: https://application.example/form" in page.text
    assert "Submit a short CV." in page.text and "Site host" not in page.text and "campus.example/posting" not in page.text


def test_raw_response_size_and_text_limits_are_independent(monkeypatch, request_page):
    large = ARTICLE.replace("</article>", "<p>" + "visible notice " * 2500 + "</p></article>")
    handler = lambda req: httpx.Response(404) if req.url.path == "/robots.txt" else html(large)
    page, _ = request_page(handler)
    assert page.coverage == "partial_text" and len(page.text) == public_page.MAX_SOURCE_CHARS
    monkeypatch.setattr(public_page, "MAX_PAGE_BYTES", 4096)
    page, _ = request_page(handler)
    assert page.coverage == "metadata_only" and not page.text


def test_total_timeout_includes_dns(monkeypatch):
    async def exercise():
        async def slow_dns(*args, **kwargs):
            await asyncio.sleep(2)

        monkeypatch.setattr(asyncio.get_running_loop(), "getaddrinfo", slow_dns)
        with pytest.raises(public_page.PageTemporarilyUnavailable):
            await public_page.extract_public_page("https://campus.example/start")

    monkeypatch.setattr(public_page, "FETCH_TIMEOUT", 0.05)
    asyncio.run(exercise())
