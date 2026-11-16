import asyncio
import ipaddress
import json
import re
import socket
from contextlib import aclosing
from dataclasses import dataclass
from urllib.parse import unquote_plus

import httpx
from bs4 import BeautifulSoup, ParserRejectedMarkup, Tag
from protego import Protego

from app.models import Coverage


MAX_PAGE_BYTES = 1024 * 1024
MAX_ROBOTS_BYTES = 64 * 1024
MAX_SOURCE_CHARS = 32_000
MAX_REDIRECTS = 3
FETCH_TIMEOUT = 15
USER_AGENT = "ITDA"
PAGE_TYPES = {"text/html", "application/xhtml+xml", "text/plain"}
REDIRECTS = {301, 302, 303, 307, 308}
CREDENTIAL_PARAMETERS = {
    "access_token", "refresh_token", "id_token", "authorization", "auth",
    "api_key", "apikey", "password", "token", "signature", "sig", "key-pair-id",
    "x-amz-signature", "x-goog-signature",
}
PRIVATE_STORAGE_PATH = re.compile(
    r"/storage/v1/(?:object|render/image)/(?:upload/)?(?:sign|authenticated)(?:/|$)", re.I
)
RESTRICTED_METADATA = re.compile(r"\b(?:nosnippet|noai)\b", re.I)
HIDDEN_STYLE = re.compile(r"(?:^|;)\s*(?:display\s*:\s*none|visibility\s*:\s*hidden)\b", re.I)
ACCESS_GATE = re.compile(
    r"^(?:please\s+)?(?:sign[\s-]*in|log[\s-]*in|login|access denied|forbidden|just a moment|"
    r"verify (?:that )?you are human|checking your browser|subscribe to (?:continue|read)|"
    r"로그인|접근 권한|접근이 제한).{0,100}$",
    re.I,
)
JAVASCRIPT_NOTICE = re.compile(
    r"enable javascript|javascript (?:is required|is disabled|must be enabled)|"
    r"자바스크립트.{0,20}(?:활성화|필요|사용해야)", re.I
)
FAILURE_MESSAGES = {
    "unsupported_url": "공개 웹 접근 조건을 충족하는 주소만 가져올 수 있습니다.",
    "dns_not_found": "공개 웹 주소를 찾을 수 없습니다.",
    "network_error": "일시적인 연결 또는 응답 오류로 페이지 본문을 가져오지 못했습니다.",
    "timeout": "페이지에 연결하거나 응답을 기다리는 시간이 초과되었습니다.",
    "rate_limited": "사이트가 일시적으로 요청을 제한하여 본문을 가져오지 못했습니다.",
    "server_error": "사이트의 일시적인 서버 오류로 본문을 가져오지 못했습니다.",
    "robots_disallowed": "사이트의 robots.txt 정책이 이 페이지의 자동 수집을 허용하지 않습니다.",
    "robots_unavailable": "사이트의 robots.txt 정책을 확인할 수 없어 본문을 요청하지 않았습니다.",
    "content_policy": "사이트가 페이지에 표시한 정책에 따라 본문을 분석하지 않았습니다.",
    "access_restricted": "페이지가 로그인, 구독 또는 접근 확인을 요구하여 본문을 읽지 못했습니다.",
    "javascript_required": "공개 응답에 공고 본문이 없으며, 페이지가 JavaScript 실행을 요구합니다.",
    "no_body": "공개 응답에서 분석할 만한 공고 본문을 찾지 못했습니다.",
    "parse_error": "공개 응답에서 공고 상세 영역을 식별하거나 읽지 못했습니다.",
    "response_limit": "공개 응답이 다운로드 한도를 초과했습니다.",
    "response_type": "응답 형식이 지원하는 웹 페이지 또는 텍스트 형식이 아닙니다.",
    "response_encoding": "공개 응답의 압축 방식은 지원하지 않습니다.",
    "redirect_error": "페이지 이동 횟수 한도를 초과했거나 이동 주소를 확인할 수 없습니다.",
}
SHARE_FALLBACK = "저장된 링크를 열거나, 원문 텍스트 또는 스크린샷을 잇다에 공유해 분석할 수 있습니다."
PUBLIC_TEXT_ONLY = "공개 HTTP 응답에서 추출할 수 있는 텍스트만 포함합니다."
OPPORTUNITY_FIELDS = {
    "주최", "주최사", "주최/주관", "주관", "기업명",
    "대상", "모집대상", "응모대상", "지원대상", "참가자격", "응모자격", "공모자격", "지원자격",
    "접수기간", "모집기간", "지원기간", "신청기간", "접수마감", "지원마감", "마감일",
    "제출서류", "지원서류", "필요서류", "접수방법", "지원방법", "응모방법", "신청방법", "제출방법",
}
APPLICATION_LABEL = re.compile(
    r"(?:공식\s*|온라인\s*)*(?:응모|지원|신청|접수)\s*(?:서\s*)?"
    r"(?:폼|링크|페이지|바로가기|하기|제출하기)"
)
DETAIL_HEADINGS = {"상세내용", "공모전 공모요강", "공모요강"}
NON_CONTENT = (
    "head, script, style, template, noscript, nav, aside, footer, dialog, iframe, svg, "
    "[hidden], [inert], [aria-hidden='true' i], [role='navigation'], [role='banner'], "
    "[role='complementary'], [role='contentinfo'], .skip-link, .visually-hidden, "
    ".cookie-banner, #cookie-banner, #onetrust-banner-sdk, .advertisement"
)


@dataclass(frozen=True)
class PublicPage:
    text: str
    coverage: Coverage
    limitations: tuple[str, ...]
    failure: str | None = None


@dataclass(frozen=True)
class _Response:
    status: int
    headers: httpx.Headers
    body: bytes = b""
    charset: str | None = None


@dataclass(frozen=True)
class _OpportunityLayout:
    title: str
    fields: str
    description: str
    organizer: str = ""
    form: str = ""
    public_template: str = ""


class _PageUnavailable(Exception):
    def __init__(self, failure: str, coverage: Coverage = "metadata_only", *, detail: str | None = None):
        super().__init__(detail or FAILURE_MESSAGES[failure])
        self.failure = failure
        self.coverage = coverage


class PageTemporarilyUnavailable(Exception):
    def __init__(self, failure: str = "network_error"):
        super().__init__(FAILURE_MESSAGES[failure])
        self.failure = failure
        self.limitations = (str(self), SHARE_FALLBACK)


def _public_url(value: str) -> httpx.URL:
    if len(value) > 2083 or re.search(r"[\x00-\x20\x7f\\]", value):
        raise _PageUnavailable("unsupported_url", "unsupported")
    try:
        url = httpx.URL(value)
    except (httpx.InvalidURL, ValueError):
        raise _PageUnavailable("unsupported_url", "unsupported") from None
    ports = {"http": 80, "https": 443}
    credential_names = {
        unquote_plus(parameter.partition("=")[0]).lower()
        for component in (url.query.decode("ascii"), url.fragment)
        for parameter in re.split(r"[&;?]", component)
        if "=" in parameter
    }
    if (
        url.scheme not in ports or url.port not in (None, ports.get(url.scheme))
        or not url.host or url.userinfo or "%" in url.host
        or credential_names & CREDENTIAL_PARAMETERS or PRIVATE_STORAGE_PATH.search(url.path)
    ):
        raise _PageUnavailable("unsupported_url", "unsupported")
    return url.copy_with(fragment=None)


def _is_public(address: ipaddress.IPv4Address | ipaddress.IPv6Address) -> bool:
    if not address.is_global or address.is_multicast or address.is_reserved:
        return False
    if isinstance(address, ipaddress.IPv6Address):
        # Use native global IPv6 only. IPv4 transition ranges can route to private IPv4.
        return (
            address in ipaddress.IPv6Network("2000::/3")
            and address not in ipaddress.IPv6Network("2001::/23")
            and address not in ipaddress.IPv6Network("2002::/16")
        )
    return address not in ipaddress.IPv4Network("192.0.0.0/24")


async def _public_addresses(url: httpx.URL) -> tuple[str, ...]:
    host = url.raw_host.decode("ascii")
    port = 443 if url.scheme == "https" else 80
    try:
        addresses = (ipaddress.ip_address(host),)
    except ValueError:
        try:
            records = await asyncio.get_running_loop().getaddrinfo(
                host, port, type=socket.SOCK_STREAM, proto=socket.IPPROTO_TCP
            )
        except socket.gaierror as exc:
            if exc.errno in {socket.EAI_NONAME, getattr(socket, "EAI_NODATA", None)}:
                raise _PageUnavailable("dns_not_found") from None
            raise PageTemporarilyUnavailable from None
        if any(len(record[4]) == 4 and record[4][3] for record in records):
            raise _PageUnavailable("unsupported_url", "unsupported")
        addresses = tuple(ipaddress.ip_address(record[4][0]) for record in records)

    if not addresses or any(not _is_public(address) for address in addresses):
        raise _PageUnavailable("unsupported_url", "unsupported")
    # Keep DNS order with one fallback for hosts advertising both IPv4 and IPv6.
    return tuple(dict.fromkeys(str(address) for address in addresses))[:2]


async def _get(
    url: httpx.URL,
    addresses: tuple[str, ...],
    *,
    media_types: set[str],
    max_bytes: int,
) -> _Response:
    for address in addresses:
        request = httpx.Request(
            "GET",
            url.copy_with(host=address),
            headers={
                "Host": url.netloc.decode("ascii"),
                "User-Agent": USER_AGENT,
                "Accept": ", ".join(sorted(media_types - {""})),
                "Accept-Encoding": "identity",
            },
            extensions={
                "sni_hostname": url.raw_host.decode("ascii").removesuffix("."),
                "timeout": {"connect": 3, "read": 4, "write": 3, "pool": 3},
            },
        )
        try:
            # A direct connection to the vetted address avoids a second hostname lookup.
            # Host and TLS verification still use the original authority.
            async with httpx.AsyncHTTPTransport(trust_env=False) as transport:
                response = await transport.handle_async_request(request)
                async with aclosing(response):
                    headers = response.headers
                    result = _Response(response.status_code, headers)
                    if response.status_code not in (200, 206):
                        return result
                    if RESTRICTED_METADATA.search(headers.get("x-robots-tag", "")):
                        raise _PageUnavailable("content_policy")
                    if headers.get("content-encoding", "identity").lower() != "identity":
                        raise _PageUnavailable("response_encoding")
                    if headers.get("content-type", "").split(";", 1)[0].strip().lower() not in media_types:
                        raise _PageUnavailable("response_type")
                    declared_size = headers.get("content-length", "")
                    if declared_size and (
                        not declared_size.isdecimal() or len(declared_size) > 10 or int(declared_size) > max_bytes
                    ):
                        raise _PageUnavailable("response_limit")
                    body = bytearray()
                    async for chunk in response.aiter_raw(chunk_size=65536):
                        if len(body) + len(chunk) > max_bytes:
                            raise _PageUnavailable("response_limit")
                        body.extend(chunk)
                    return _Response(response.status_code, headers, bytes(body), response.charset_encoding)
        except (httpx.ConnectError, httpx.ConnectTimeout):
            continue
        except httpx.HTTPError:
            raise PageTemporarilyUnavailable from None
    raise PageTemporarilyUnavailable


def _redirect(url: httpx.URL, response: _Response) -> httpx.URL:
    location = response.headers.get("location", "")
    if not location or re.search(r"[\x00-\x20\x7f\\]", location):
        raise _PageUnavailable("redirect_error")
    try:
        next_url = _public_url(str(url.join(location)))
    except (httpx.InvalidURL, ValueError):
        raise _PageUnavailable("unsupported_url", "unsupported") from None
    if url.scheme == "https" and next_url.scheme == "http":
        raise _PageUnavailable("unsupported_url", "unsupported")
    return next_url


def _check_status(status: int) -> None:
    if status in {401, 403, 407, 451}:
        raise _PageUnavailable(
            "access_restricted", detail=f"사이트가 공개 접속을 허용하지 않아 본문을 읽지 못했습니다 (HTTP {status})."
        )
    if status == 429:
        raise PageTemporarilyUnavailable("rate_limited")
    if status >= 500:
        raise PageTemporarilyUnavailable("server_error")
    if status not in {200, 206}:
        raise _PageUnavailable("http_status", detail=f"공개 페이지에서 본문을 가져올 수 없습니다 (HTTP {status}).")


async def _check_robots(url: httpx.URL, addresses: tuple[str, ...]) -> None:
    robots = url.copy_with(path="/robots.txt", query=None)
    for _ in range(MAX_REDIRECTS + 1):
        try:
            result = await _get(
                robots, addresses, media_types={"text/plain", ""}, max_bytes=MAX_ROBOTS_BYTES
            )
            if result.status in REDIRECTS:
                robots = _redirect(robots, result)
                addresses = await _public_addresses(robots)
                continue
        except PageTemporarilyUnavailable:
            raise PageTemporarilyUnavailable("robots_unavailable") from None
        except _PageUnavailable as exc:
            raise _PageUnavailable("robots_unavailable", exc.coverage) from None
        if result.status in {404, 410}:
            return
        if result.status == 429 or result.status >= 500:
            raise PageTemporarilyUnavailable("robots_unavailable")
        if result.status != 200:
            raise _PageUnavailable("robots_unavailable")
        if not Protego.parse(
            result.body.decode("utf-8-sig", errors="replace")
        ).can_fetch(str(url), USER_AGENT):
            raise _PageUnavailable("robots_disallowed")
        return
    raise _PageUnavailable("robots_unavailable")


def _opportunity_layout(url: httpx.URL) -> _OpportunityLayout | None:
    host = url.host.removeprefix("www.")
    if host == "linkareer.com" and re.fullmatch(r"/activity/\d+/?", url.path):
        return _OpportunityLayout(
            "main h1", "main .activity-info", "main #DETAIL > section:has(> h2.detail-title)",
            "main header.organization-info .organization-name",
        )
    if host == "wevity.com" and url.params.get("c") == "find" and url.params.get("gbn") in {"view", "viewok"}:
        return _OpportunityLayout(
            ".contest-detail h6.tit", ".contest-detail .cd-info-list", ".contest-detail #viewContents",
        )
    if host == "thinkcontest.com" and url.path == "/thinkgood/user/contest/view.do":
        return _OpportunityLayout(
            "form#detailForm .view-header .contest-view__title", "form#detailForm .content-detail__top .info",
            "form#detailForm #tab01.current > #contest_content",
            form="form#detailForm",
            # Thinkgood supplies this public tab's content to its display component.
            public_template=(
                "form#detailForm #tab01.current > #contest_content"
                ":has(+ naver-content[content-id='contest_content'])"
            ),
        )
    return None


def _plain(node: Tag | None) -> str:
    return " ".join(node.get_text(" ", strip=True).split()) if node is not None else ""


def _remove_non_content(
    soup: BeautifulSoup, notice_form: Tag | None = None, public_template: Tag | None = None,
) -> None:
    for form in soup.find_all("form"):
        if form is not notice_form and not form.decomposed:
            form.decompose()
    for element in soup.select(NON_CONTENT):
        if not element.decomposed:
            element.decompose()
    for element in soup.find_all(style=HIDDEN_STYLE):
        if element is not public_template and not element.decomposed:
            element.decompose()


def _application_target(url: httpx.URL, href: str) -> str | None:
    if not href or href.startswith("#"):
        return None
    try:
        target = _public_url(str(url.join(href)))
    except (httpx.InvalidURL, ValueError, _PageUnavailable):
        return None
    try:
        address = ipaddress.ip_address(target.host)
    except ValueError:
        return str(target) if "." in target.host and not target.host.endswith(".local") else None
    return str(target) if _is_public(address) else None


def _application_links(scope: Tag, url: httpx.URL) -> list[str]:
    links = []
    for anchor in scope.select("a[href]"):
        previous = anchor.find_previous(string=lambda value: bool(value.strip()))
        inside = previous is not None and any(parent is scope for parent in previous.parents)
        adjacent = str(previous).strip(" \t\r\n:：*-●▶■") if inside else ""
        label = _plain(anchor).strip(" :：")
        if APPLICATION_LABEL.fullmatch(label) or APPLICATION_LABEL.fullmatch(adjacent):
            if target := _application_target(url, str(anchor["href"])):
                links.append(f"공고의 지원 링크: {target}")
    return links


def _visible_opportunity(
    soup: BeautifulSoup, layout: _OpportunityLayout, url: httpx.URL,
) -> tuple[str, str, bool]:
    title = _plain(soup.select_one(layout.title))
    fields = soup.select_one(layout.fields)
    description = soup.select_one(layout.description)
    lines = []
    if fields is not None:
        for badge in fields.select(".cil-dday"):
            badge.decompose()
        for node in fields.select("dt, .tit"):
            label = _plain(node)
            if re.sub(r"\s+", "", label) not in OPPORTUNITY_FIELDS:
                continue
            if node.name == "span" and node.parent.name == "li":
                value = _plain(node.parent).removeprefix(label).strip()
            else:
                value = _plain(node.find_next_sibling())
            if value and value != "-":
                lines.append(f"{label}: {value}")
    if layout.organizer and (organizer := _plain(soup.select_one(layout.organizer))):
        lines.insert(0, f"주최: {organizer}")
    for scope in (fields, description):
        if scope is not None:
            lines.extend(_application_links(scope, url))
    body_lines = [] if description is None else [
        text for value in description.stripped_strings
        if (text := " ".join(value.split())) not in DETAIL_HEADINGS and text != "-"
    ]
    description_text = "\n".join(body_lines)
    if len(description_text) < 200 and JAVASCRIPT_NOTICE.search(description_text):
        if not lines:
            raise _PageUnavailable("javascript_required")
        body_lines = []
    return title, "\n".join([*dict.fromkeys(lines), *body_lines]), bool(body_lines)


def _structured_posting(scripts: list[Tag]) -> dict | None:
    pending = []
    for script in scripts:
        try:
            pending.append(json.loads(script.string or ""))
        except (ValueError, RecursionError):
            continue
    posting = None
    while pending:
        value = pending.pop()
        if isinstance(value, list):
            pending.extend(value)
        elif isinstance(value, dict):
            kind = value.get("@type")
            if kind == "JobPosting" or (isinstance(kind, list) and "JobPosting" in kind):
                if posting is not None:
                    return None
                posting = value
            pending.extend(value[key] for key in ("@graph", "mainEntity") if key in value)
    return posting


def _posting_text(posting: dict, url: httpx.URL) -> tuple[str, str]:
    title = posting.get("title") if isinstance(posting.get("title"), str) else ""
    lines = []
    organizer = posting.get("hiringOrganization")
    if isinstance(organizer, dict) and isinstance(organizer.get("name"), str):
        lines.append(f"채용 기관: {organizer['name']}")
    for key, label in (("qualifications", "지원 자격"), ("validThrough", "공고 게시 유효기간")):
        if isinstance(value := posting.get(key), str) and value.strip():
            lines.append(f"{label}: {value.strip()}")
    action = posting.get("potentialAction")
    if isinstance(action, dict) and action.get("@type") == "ApplyAction":
        target = action.get("target")
        if isinstance(target, str) and (link := _application_target(url, target)):
            lines.append(f"공고의 지원 링크: {link}")
    if isinstance(text := posting.get("description"), str):
        description = BeautifulSoup(text, "html.parser")
        _remove_non_content(description)
        if value := _plain(description):
            lines.append(value)
    return title, "\n".join(lines)


def _body_text(response: _Response, url: httpx.URL) -> PublicPage:
    limitations = [PUBLIC_TEXT_ONLY]
    javascript_required = False
    layout = None
    posting = None
    if response.headers.get("content-type", "").split(";", 1)[0].strip().lower() == "text/plain":
        try:
            body = response.body.decode(response.charset or "utf-8-sig", errors="replace")
        except LookupError:
            body = response.body.decode("utf-8", errors="replace")
        body, title = " ".join(body.split()), ""
    else:
        soup = BeautifulSoup(response.body, "html.parser", from_encoding=response.charset)
        title = _plain(soup.title)
        for tag in soup.find_all("meta"):
            if str(tag.get("name", "")).lower() in {"robots", "itda"} and RESTRICTED_METADATA.search(
                str(tag.get("content", ""))
            ):
                raise _PageUnavailable("content_policy")
        scripts = soup.find_all("script", type="application/ld+json")
        if any(
            re.search(r'"isAccessibleForFree"\s*:\s*(?:false\b|"false")', tag.string or "", re.I)
            for tag in scripts
        ):
            raise _PageUnavailable("access_restricted")
        javascript_required = bool(JAVASCRIPT_NOTICE.search(title)) or any(
            JAVASCRIPT_NOTICE.search(_plain(tag)) for tag in soup.find_all("noscript")
        )
        has_scripts = soup.find("script", src=True) is not None
        layout = _opportunity_layout(url)
        posting = _structured_posting(scripts) if layout is None else None
        notice_form = soup.select_one(layout.form) if layout is not None and layout.form else None
        public_template = soup.select_one(layout.public_template) if layout is not None and layout.public_template else None
        if notice_form is not None and notice_form.select_one("input[type=password]") is not None:
            raise _PageUnavailable("access_restricted")
        if posting is not None and soup.select_one("main input[type=password]") is not None:
            raise _PageUnavailable("access_restricted")
        _remove_non_content(soup, notice_form, public_template)
        root = soup.find("main") or soup.find(attrs={"role": "main"}) or soup.body or soup
        articles = root.find_all("article", limit=2)
        main = articles[0] if len(articles) == 1 else root
        heading = _plain(main.find("h1"))
        body = _plain(main)
        if any(ACCESS_GATE.fullmatch(part) for part in (title, heading, body)):
            raise _PageUnavailable("access_restricted")
        shell = soup.select_one("#root, #app, #__next")
        empty_shell = has_scripts and shell is not None and not _plain(shell)
        javascript_required = javascript_required or empty_shell
        if layout is not None:
            title, body, has_description = _visible_opportunity(soup, layout, url)
            if body and not has_description:
                limitations.extend(("공개 응답에서 확인한 공고 항목만 포함하며, 상세 본문은 확인하지 못했습니다.", SHARE_FALLBACK))
        elif posting is not None:
            title, body = _posting_text(posting, url)
            if body:
                limitations.extend(("공개 페이지의 구조화된 채용 공고 정보만 포함합니다.", SHARE_FALLBACK))
        else:
            title = title or heading
            if empty_shell and soup.find("main") is None:
                body = ""

    if ACCESS_GATE.fullmatch(body):
        raise _PageUnavailable("access_restricted")
    if len(body) < 5 or body == title:
        if javascript_required or (len(body) < 200 and JAVASCRIPT_NOTICE.search(body)):
            raise _PageUnavailable("javascript_required")
        raise _PageUnavailable("parse_error" if layout is not None else "no_body")
    if len(body) < 200 and JAVASCRIPT_NOTICE.search(body) and not layout and not posting:
        raise _PageUnavailable("javascript_required")
    title = title[:500]
    text = body if not title or body.startswith(title) else f"{title}\n\n{body}"
    if response.status == 206:
        limitations.append("서버가 본문의 일부만 반환했습니다.")
    if "\ufffd" in text:
        limitations.append("일부 응답 문자를 읽을 수 없었습니다.")
    if len(text) > MAX_SOURCE_CHARS:
        limitations.append("본문이 분석 길이 한도를 초과하여 앞부분만 포함합니다.")
        text = text[:MAX_SOURCE_CHARS]
    coverage: Coverage = "partial_text" if len(limitations) > 1 else "full_text"
    return PublicPage(text, coverage, tuple(limitations))


async def extract_public_page(source_url: str) -> PublicPage:
    """Fetch one public page without sessions, browser execution, or proxy credentials."""
    try:
        async with asyncio.timeout(FETCH_TIMEOUT):
            url = _public_url(source_url)
            for _ in range(MAX_REDIRECTS + 1):
                addresses = await _public_addresses(url)
                await _check_robots(url, addresses)
                response = await _get(url, addresses, media_types=PAGE_TYPES, max_bytes=MAX_PAGE_BYTES)
                if response.status not in REDIRECTS:
                    _check_status(response.status)
                    try:
                        return await asyncio.to_thread(_body_text, response, url)
                    except (ParserRejectedMarkup, UnicodeError, RecursionError):
                        raise _PageUnavailable("parse_error") from None
                url = _redirect(url, response)
            raise _PageUnavailable("redirect_error")
    except TimeoutError:
        raise PageTemporarilyUnavailable("timeout") from None
    except _PageUnavailable as exc:
        return PublicPage("", exc.coverage, (str(exc), SHARE_FALLBACK), exc.failure)
