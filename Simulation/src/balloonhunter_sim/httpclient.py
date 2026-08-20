"""HTTP access to the SondeHub and Tawhiri APIs.

Stdlib only. Two traps this module exists to handle, both measured (§4.3):

* ``/sonde/{serial}`` answers **302**; a client that does not follow the redirect
  silently receives zero bytes and no error.
* Responses are **gzip-encoded regardless of request headers**, so a naive UTF-8
  decode fails at byte 1.
"""

from __future__ import annotations

import gzip
import json
import logging
import urllib.error
import urllib.parse
import urllib.request
import zlib
from typing import Protocol

log = logging.getLogger(__name__)

#: gzip magic. Content-Encoding cannot be trusted here, so sniff the body.
_GZIP_MAGIC = b"\x1f\x8b"


class RateLimiter(Protocol):
    """Politeness gate applied before every request (R-13)."""

    def acquire(self) -> None: ...

    def penalise(self, seconds: float) -> None: ...


class HttpError(Exception):
    """A request failed after exhausting retries."""

    def __init__(self, url: str, cause: str, status: int | None = None) -> None:
        super().__init__(f"{url}: {cause}")
        self.url = url
        self.status = status


class PermanentError(HttpError):
    """The server answered, and the answer will not change if we ask again.

    Retrying a rejected parameter wastes requests against a free service.
    """


class TooManyRequests(HttpError):
    """HTTP 429. Carries the server's Retry-After if it supplied one."""

    def __init__(self, url: str, retry_after: float | None) -> None:
        super().__init__(url, "429 Too Many Requests", status=429)
        self.retry_after = retry_after


def _decode(body: bytes) -> str:
    if body[:2] == _GZIP_MAGIC:
        return gzip.decompress(body).decode("utf-8")
    try:
        return body.decode("utf-8")
    except UnicodeDecodeError:
        # Some responses arrive deflate-wrapped rather than gzip-wrapped.
        return zlib.decompress(body, -zlib.MAX_WBITS).decode("utf-8")


def _retry_after(headers: object) -> float | None:
    get = getattr(headers, "get", None)
    if get is None:
        return None
    raw = get("Retry-After")
    if raw is None:
        return None
    try:
        return float(raw)
    except (TypeError, ValueError):
        return None


class HttpClient:
    """A small, polite, retrying JSON client."""

    def __init__(
        self,
        user_agent: str,
        limiter: RateLimiter,
        timeout_s: float = 40.0,
        max_retries: int = 4,
        sleep: object = None,
    ) -> None:
        self._user_agent = user_agent
        self._limiter = limiter
        self._timeout_s = timeout_s
        self._max_retries = max_retries
        # Injected so tests never sleep.
        import time as _time

        self._sleep = sleep if callable(sleep) else _time.sleep

    def get_json(self, url: str, params: dict[str, str | float] | None = None) -> object:
        """GET a URL and parse JSON, retrying transient failures (R-15)."""
        if params:
            url = f"{url}?{urllib.parse.urlencode(params)}"
        last: Exception | None = None
        for attempt in range(self._max_retries):
            self._limiter.acquire()
            try:
                text = _decode(self._fetch(url))
                try:
                    return json.loads(text)
                except json.JSONDecodeError:
                    if text.strip():
                        # SondeHub answers 200 with a plain-text complaint for a
                        # bad parameter, e.g. "Duration must be either 3d, 1d,
                        # 12h, 6h, 3h, 1h, 30m, 1m, 15s, 0". Retrying that is
                        # impolite (R-13) and buries the real cause.
                        raise PermanentError(url, f"non-JSON response: {text[:200]}") from None
                    raise  # empty body: could be truncation, worth a retry
            except PermanentError:
                raise
            except TooManyRequests as exc:
                # R-13: respect Retry-After, else back off exponentially.
                delay = exc.retry_after if exc.retry_after is not None else 2.0**attempt
                log.warning("429 from %s, backing off %.1fs", url, delay)
                self._limiter.penalise(delay)
                self._sleep(delay)
                last = exc
            except (HttpError, urllib.error.URLError, TimeoutError, ValueError) as exc:
                delay = 2.0**attempt
                log.warning("%s failed (%s), retry in %.1fs", url, exc, delay)
                self._sleep(delay)
                last = exc
        raise HttpError(url, f"giving up after {self._max_retries} attempts: {last}")

    def _fetch(self, url: str) -> bytes:
        request = urllib.request.Request(
            url,
            headers={
                "User-Agent": self._user_agent,
                "Accept": "application/json",
                "Accept-Encoding": "gzip, deflate",
            },
        )
        try:
            # urlopen follows the 302 that /sonde/{serial} answers with.
            with urllib.request.urlopen(request, timeout=self._timeout_s) as response:
                return bytes(response.read())
        except urllib.error.HTTPError as exc:
            if exc.code == 429:
                raise TooManyRequests(url, _retry_after(exc.headers)) from exc
            raise HttpError(url, f"HTTP {exc.code}", status=exc.code) from exc
