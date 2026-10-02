### [   vfrcommon.py || AIRAC maths, HTTP and file helpers shared by the aerocheck.app/data scripts   ] ###
"""
Shared by extract_ofm.py and charts_registry.py. Standard library only (Python 3.11+), so the weekly job needs
nothing but a Python.
"""

## [ IMPORTS be imports ]
import gzip
import hashlib
import json
import os
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone

## [ CONSTANTS are the new vars ]
# OFM's Cloudflare answers 403 to "Python-urllib/3.x", so every request says who we are
USER_AGENT = "AeroCheck-data/1.0 (+https://aerocheck.app)"
# AIRAC 2001 took effect on 2 January 2020; every cycle since is exactly 28 days after the previous one
AIRAC_ANCHOR = date(2020, 1, 2)
AIRAC_DAYS = 28
# Root of the website checkout (scripts/vfrdata/ is two levels down)
REPOROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), "..", ".."))


## [ AIRAC maths ]
@dataclass(frozen=True)
class Airac:
    """One AIRAC cycle: its four-digit ident (YYNN) and its validity, start included and end excluded."""
    ident: str
    valid_from: date
    valid_to: date

    def previous(self):
        return airac_for(self.valid_from - timedelta(days=1))

    def next(self):
        return airac_for(self.valid_to)


def airac_for(day):
    """
    Returns the AIRAC cycle in force on a date, computed the way OFM's own site does (an anchor plus 28-day
    steps). The NN of YYNN counts the cycles that start in that year, so a cycle starting on day-of-year d is
    number (d - 1) // 28 + 1 (the first cycle of a year always starts within its first 28 days).
    """
    steps = (day - AIRAC_ANCHOR).days // AIRAC_DAYS
    start = AIRAC_ANCHOR + timedelta(days=AIRAC_DAYS * steps)
    number = (start.timetuple().tm_yday - 1) // AIRAC_DAYS + 1
    return Airac(f"{start.year % 100:02d}{number:02d}", start, start + timedelta(days=AIRAC_DAYS))


def airac_by_ident(ident):
    """Returns the cycle with a given YYNN ident, e.g. "2610" (raises ValueError on a malformed or impossible one)."""
    if len(ident) != 4 or not ident.isdigit():
        raise ValueError(f"not an AIRAC ident: {ident!r}")
    year, number = 2000 + int(ident[:2]), int(ident[2:])
    # Find the first cycle of that year, then walk forward
    cycle = airac_for(date(year, 1, 1))
    if cycle.valid_from.year < year:
        cycle = cycle.next()
    for _ in range(number - 1):
        cycle = cycle.next()
    if number < 1 or cycle.valid_from.year != year:
        raise ValueError(f"AIRAC {ident} does not exist")
    return cycle


def today_utc():
    return datetime.now(timezone.utc).date()


def now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


## [ HTTP ]
@dataclass
class Response:
    """What a GET returns: the status, the response headers (lower-case names) and, on a 2xx, an open stream."""
    status: int
    headers: dict
    stream: object = None

    def close(self):
        if self.stream is not None:
            self.stream.close()


def lower_keys(headers):
    return {str(k).lower(): v for k, v in dict(headers).items()}


def http_get(url, etag=None, accept_gzip=True, timeout=120, retries=3):
    """
    GETs a URL with our User-Agent, asking for gzip, and returns a Response. A 2xx comes back with a readable
    stream (gunzipped on the fly when the server compressed it); 304, 404 and other HTTP errors come back as a
    status without a stream, never as an exception. Network failures and 5xx are retried with a back-off, then
    raised. `etag`, when given, is sent as If-None-Match.
    """
    headers = {"User-Agent": USER_AGENT}
    if accept_gzip is True:
        headers["Accept-Encoding"] = "gzip"
    if etag:
        headers["If-None-Match"] = etag
    for attempt in range(retries):
        try:
            response = urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=timeout)
            encoding = (response.headers.get("Content-Encoding") or "identity").strip().lower()
            if encoding in ("gzip", "x-gzip"):
                stream = gzip.GzipFile(fileobj=response)
            elif encoding in ("br", "deflate", "compress", "zstd"):
                # Never asked for, so never expected
                response.close()
                raise IOError(f"{url}: unexpected Content-Encoding {encoding}")
            else:
                # identity, or not a compression at all: OpenAIP's bucket labels its GeoJSON "utf-8" (2026-10-02)
                stream = response
            return Response(response.status, lower_keys(response.headers), stream)
        except urllib.error.HTTPError as error:
            # 5xx is worth another try; anything else is the answer
            if error.code >= 500 and attempt < retries - 1:
                time.sleep(5 * (attempt + 1))
                continue
            return Response(error.code, lower_keys(error.headers or {}))
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            if attempt < retries - 1:
                time.sleep(5 * (attempt + 1))
                continue
            raise


def http_status(url, timeout=30, retries=2):
    """
    Returns the final HTTP status of a URL after redirects: a HEAD first, and a GET of the first byte when the
    server doesn't do HEAD (405/501). 0 means the host could not be reached at all.
    """
    for method in ("HEAD", "GET"):
        headers = {"User-Agent": USER_AGENT}
        if method == "GET":
            headers["Range"] = "bytes=0-0"
        status = 0
        for attempt in range(retries):
            try:
                with urllib.request.urlopen(urllib.request.Request(url, headers=headers, method=method),
                                            timeout=timeout) as response:
                    status = response.status
                break
            except urllib.error.HTTPError as error:
                status = error.code
                if error.code < 500:
                    break
            except (urllib.error.URLError, TimeoutError, ConnectionError):
                status = 0
            if attempt < retries - 1:
                time.sleep(3)
        if status not in (405, 501):
            return status
    return status


def strong_etag(etag):
    """
    Drops the weak-validator prefix. OFM's Cloudflare turns the bucket's strong ETag into W/"…" when it
    gzips, and then only answers 304 to the strong form (checked 2026-10-02).
    """
    if not etag:
        return None
    etag = etag.strip()
    return etag[2:] if etag.startswith("W/") else etag


## [ FILE HANDLING ]
def dump_compact(obj):
    """The published form of a data file: compact UTF-8 JSON with a final newline."""
    return (json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")


def dump_pretty(obj):
    """The form for the small index files a human may read in a diff."""
    return (json.dumps(obj, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def read_json(path):
    """Returns the parsed JSON file, or None when it doesn't exist (or isn't JSON any more)."""
    try:
        with open(path, "rb") as handle:
            return json.loads(handle.read().decode("utf-8"))
    except (FileNotFoundError, ValueError):
        return None


def write_atomic(path, data):
    """Writes bytes next to the target, then renames: a crash never leaves half a file for the site to serve."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    handle, temp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp-")
    try:
        with os.fdopen(handle, "wb") as out:
            out.write(data)
        # mkstemp makes the file private; the site serves it to everyone
        os.chmod(temp, 0o644)
        os.replace(temp, path)
    except BaseException:
        if os.path.exists(temp):
            os.unlink(temp)
        raise


def write_if_changed(path, data):
    """Writes the file only when its bytes differ, so an unchanged week makes no commit. Returns True if written."""
    try:
        with open(path, "rb") as handle:
            if handle.read() == data:
                return False
    except FileNotFoundError:
        pass
    write_atomic(path, data)
    return True
