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


@pytest.mark.parametrize("reply", [
    lambda: httpx.Response(401),
    lambda: html("<title>Sign in to campus</title><main><h1>Log in</h1><form></form></main>"),
    lambda: html(ARTICLE, **{"X-Robots-Tag": "nosnippet"}),
    lambda: html(ARTICLE.replace("</head>", '<script type="application/ld+json">'
                                              '{"isAccessibleForFree":false}</script></head>')),
])
def test_restricted_page_has_only_metadata(request_page, reply):
    page, _ = request_page(lambda req: httpx.Response(404) if req.url.path == "/robots.txt" else reply())
    assert page.text == "" and page.coverage == "metadata_only"
    assert page.limitations == (public_page.RESTRICTED,)


def test_robots_exclusion_prevents_page_request(request_page):
    def handle(request):
        assert request.url.path == "/robots.txt"
        return httpx.Response(
            200, headers={"Content-Type": "text/plain"},
            stream=httpx.ByteStream(b"User-agent: *\nDisallow: /sta*\n"),
        )

    page, requests = request_page(handle)
    assert page.text == "" and page.coverage == "metadata_only" and len(requests) == 1


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
