import asyncio
import ipaddress
import re
import socket
from contextlib import aclosing
from dataclasses import dataclass
from urllib.parse import unquote_plus

import httpx
from bs4 import BeautifulSoup
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
    r"you (?:need to|must) enable javascript|로그인|접근 권한|접근이 제한).{0,100}$",
    re.I,
)
BLOCKED = "공개 웹 접근 조건을 충족하는 주소만 가져올 수 있습니다."
RESTRICTED = "페이지가 로그인 또는 접근 확인을 요구하거나 본문 사용을 제한합니다."
PUBLIC_TEXT_ONLY = "공개 HTTP 응답에서 추출할 수 있는 텍스트만 포함합니다."


@dataclass(frozen=True)
class PublicPage:
    text: str
    coverage: Coverage
    limitations: tuple[str, ...]


@dataclass(frozen=True)
class _Response:
    status: int
    headers: httpx.Headers
    body: bytes = b""
    charset: str | None = None


class _PageUnavailable(Exception):
    def __init__(self, limitation: str, coverage: Coverage = "metadata_only"):
        super().__init__(limitation)
        self.coverage = coverage


class PageTemporarilyUnavailable(Exception):
    pass


def _public_url(value: str) -> httpx.URL:
    if len(value) > 2083 or re.search(r"[\x00-\x20\x7f\\]", value):
        raise _PageUnavailable(BLOCKED, "unsupported")
    try:
        url = httpx.URL(value)
    except (httpx.InvalidURL, ValueError):
        raise _PageUnavailable(BLOCKED, "unsupported") from None
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
        raise _PageUnavailable(BLOCKED, "unsupported")
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
                raise _PageUnavailable("공개 웹 주소를 찾을 수 없습니다.") from None
            raise PageTemporarilyUnavailable from None
        if any(len(record[4]) == 4 and record[4][3] for record in records):
            raise _PageUnavailable(BLOCKED, "unsupported")
        addresses = tuple(ipaddress.ip_address(record[4][0]) for record in records)

    if not addresses or any(not _is_public(address) for address in addresses):
        raise _PageUnavailable(BLOCKED, "unsupported")
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
                        raise _PageUnavailable(RESTRICTED)
                    if headers.get("content-encoding", "identity").lower() != "identity":
                        raise _PageUnavailable("공개 응답의 압축 방식은 분석 범위에 포함되지 않습니다.")
                    if headers.get("content-type", "").split(";", 1)[0].strip().lower() not in media_types:
                        raise _PageUnavailable("공개 응답에서 읽을 수 있는 웹 페이지 또는 텍스트를 찾지 못했습니다.")
                    declared_size = headers.get("content-length", "")
                    if declared_size and (
                        not declared_size.isdecimal() or len(declared_size) > 10 or int(declared_size) > max_bytes
                    ):
                        raise _PageUnavailable("공개 응답이 다운로드 한도를 초과했습니다.")
                    body = bytearray()
                    async for chunk in response.aiter_raw(chunk_size=65536):
                        if len(body) + len(chunk) > max_bytes:
                            raise _PageUnavailable("공개 응답이 다운로드 한도를 초과했습니다.")
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
        raise _PageUnavailable("안전하게 따라갈 수 있는 페이지 이동 주소가 없습니다.")
    try:
        next_url = _public_url(str(url.join(location)))
    except (httpx.InvalidURL, ValueError):
        raise _PageUnavailable(BLOCKED, "unsupported") from None
    if url.scheme == "https" and next_url.scheme == "http":
        raise _PageUnavailable(BLOCKED, "unsupported")
    return next_url


def _check_status(status: int) -> None:
    if status in {401, 403, 407, 451}:
        raise _PageUnavailable(RESTRICTED)
    if status == 429 or status >= 500:
        raise PageTemporarilyUnavailable
    if status not in {200, 206}:
        raise _PageUnavailable(f"공개 페이지에서 본문을 가져올 수 없습니다 (HTTP {status}).")


async def _check_robots(url: httpx.URL, addresses: tuple[str, ...]) -> None:
    robots = url.copy_with(path="/robots.txt", query=None)
    for _ in range(MAX_REDIRECTS + 1):
        result = await _get(
            robots, addresses, media_types={"text/plain", ""}, max_bytes=MAX_ROBOTS_BYTES
        )
        if result.status in REDIRECTS:
            robots = _redirect(robots, result)
            addresses = await _public_addresses(robots)
            continue
        if result.status in {404, 410}:
            return
        _check_status(result.status)
        if result.status != 200 or not Protego.parse(
            result.body.decode("utf-8-sig", errors="replace")
        ).can_fetch(str(url), USER_AGENT):
            raise _PageUnavailable(RESTRICTED)
        return
    raise _PageUnavailable("사이트 접근 정책의 페이지 이동 한도를 초과했습니다.")


def _body_text(response: _Response) -> PublicPage:
    if response.headers.get("content-type", "").split(";", 1)[0].strip().lower() == "text/plain":
        try:
            body = response.body.decode(response.charset or "utf-8-sig", errors="replace")
        except LookupError:
            body = response.body.decode("utf-8", errors="replace")
        body, title = " ".join(body.split()), ""
    else:
        soup = BeautifulSoup(response.body, "html.parser", from_encoding=response.charset)
        title = " ".join(soup.title.stripped_strings) if soup.title else ""
        for tag in soup.find_all("meta"):
            if str(tag.get("name", "")).lower() in {"robots", "itda"} and RESTRICTED_METADATA.search(
                str(tag.get("content", ""))
            ):
                raise _PageUnavailable(RESTRICTED)
        if any(
            re.search(r'"isAccessibleForFree"\s*:\s*(?:false\b|"false")', tag.string or "", re.I)
            for tag in soup.find_all("script", type="application/ld+json")
        ):
            raise _PageUnavailable(RESTRICTED)
        for element in soup.select(
            "head, script, style, template, noscript, nav, aside, footer, form, dialog, iframe, svg, "
            "[hidden], [inert], [aria-hidden='true' i], [role='navigation'], [role='banner'], "
            "[role='complementary'], [role='contentinfo'], .skip-link, .visually-hidden, "
            ".cookie-banner, #cookie-banner, #onetrust-banner-sdk, .advertisement"
        ):
            if not element.decomposed:
                element.decompose()
        for element in soup.find_all(style=HIDDEN_STYLE):
            if not element.decomposed:
                element.decompose()
        root = soup.find("main") or soup.find(attrs={"role": "main"}) or soup.body or soup
        articles = root.find_all("article", limit=2)
        main = articles[0] if len(articles) == 1 else root
        headline = main.find("h1")
        heading = " ".join(headline.stripped_strings) if headline else ""
        if any(ACCESS_GATE.fullmatch(part) for part in (title, heading)):
            raise _PageUnavailable(RESTRICTED)
        title = title or heading
        body = " ".join(main.get_text(" ", strip=True).split())

    if ACCESS_GATE.fullmatch(body):
        raise _PageUnavailable(RESTRICTED)
    if len(body) < 5 or body == title:
        raise _PageUnavailable("공개 응답에서 분석할 만한 본문을 찾지 못했습니다.")
    title = title[:500]
    text = body if not title or body.startswith(title) else f"{title}\n\n{body}"
    limitations = [PUBLIC_TEXT_ONLY]
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
                    return await asyncio.to_thread(_body_text, response)
                url = _redirect(url, response)
            raise _PageUnavailable("공개 페이지의 이동 횟수 한도를 초과했습니다.")
    except TimeoutError:
        raise PageTemporarilyUnavailable from None
    except _PageUnavailable as exc:
        return PublicPage("", exc.coverage, (str(exc),))
