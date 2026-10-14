"""Enrich only on-disk, approved snapshots; never connect to Microsoft Graph."""

import argparse
import asyncio
import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

ROOT = Path(__file__).resolve().parents[1]
ENDPOINT = "https://learn.microsoft.com/api/mcp"
STATES = {"not_researched", "no_verified_document", "fetch_failed", "verified"}


def now():
    return datetime.now(timezone.utc).isoformat()


def read(path, default):
    return json.loads(path.read_text(encoding="utf-8-sig")) if path.exists() else default


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def digest(message):
    values = [message["id"], message["title"], message.get("bodyText", ""),
              "\n".join(message.get("services", [])), "\n".join(message.get("tags", [])),
              "\n".join(message.get("officialDocumentUrls", []))]
    return hashlib.sha256("\x1f".join(values).encode()).hexdigest()


def learn_url(value, locale=None):
    parts = urlsplit(value)
    if (parts.scheme != "https" or parts.netloc != "learn.microsoft.com"
            or parts.username or parts.password):
        raise ValueError("Only HTTPS Microsoft Learn article URLs are allowed")
    path = re.sub(r"^/(?:[a-z]{2}-[a-z]{2})/", "/", parts.path)
    if len(path.strip("/").split("/")) < 2:
        raise ValueError("Product landing pages are not supporting articles")
    if path.startswith(("/answers/", "/search")):
        raise ValueError("Q&A/search results are not official supporting documentation")
    if parts.query and not re.fullmatch(r"view=[A-Za-z0-9._-]+(?:&preserve-view=true)?", parts.query):
        raise ValueError("Only public documentation version parameters are allowed")
    return urlunsplit(("https", "learn.microsoft.com",
                       f"/{locale}{path}" if locale else path, parts.query, parts.fragment))


def snapshots(root):
    found = {}
    paths = sorted(root.glob("history/*/messages.json")) + [root / "latest/messages.json"]
    paths += [path for path in sorted(root.glob("history/*/index.html"))
              if not (path.parent / "messages.json").exists()]
    for path in paths:
        if not path.exists():
            continue
        if path.suffix == ".html":
            content = path.read_text(encoding="utf-8-sig")
            data = json.JSONDecoder().raw_decode(content.split("const DATA = ", 1)[1])[0]
        else:
            data = read(path, {})
        if data.get("meta", {}).get("source") not in {"Microsoft Graph", "fixture"}:
            raise ValueError(f"Not an exported public snapshot: {path}")
        for message in data["messages"]:
            identifier = message["id"]
            if not re.fullmatch(r"MC\d+", identifier):
                raise ValueError("Invalid public message ID")
            entry = found.setdefault(identifier, {"message": message, "hashes": set(), "snapshots": []})
            entry["message"] = message
            entry["hashes"].add(digest(message))
            entry["snapshots"].append(path.parent.name)
    return found


def explicit_urls(message):
    text = message.get("bodyText", "") + "\n" + "\n".join(
        str(detail.get("value", "")) for detail in message.get("details", []))
    text += "\n" + "\n".join(message.get("officialDocumentUrls", []))
    urls = []
    for match in re.findall(r"https://learn\.microsoft\.com/[^\s<>\"']+", text):
        try:
            normalized = learn_url(match.rstrip(").,;]")).split("#")[0]
        except ValueError:
            continue
        if normalized not in urls:
            urls.append(normalized)
    return urls


async def call(session, cache, key, tool, arguments, delay):
    timestamps = cache.setdefault("_checkedAt", {})
    if (key in cache and key in timestamps and
            (datetime.now(timezone.utc) - datetime.fromisoformat(timestamps[key])).days < 30):
        return cache[key]
    for attempt in range(4):
        await asyncio.sleep(delay * (2 ** attempt))
        try:
            result = await session.call_tool(tool, arguments)
            if result.isError:
                text = "\n".join(getattr(item, "text", "") for item in result.content)
                if ("429" in text or "rate limit" in text.lower()) and attempt < 3:
                    continue
                raise RuntimeError(f"{tool}: {text[:300]}")
            text = "\n".join(getattr(item, "text", "") for item in result.content)
            try:
                value = json.loads(text)
            except json.JSONDecodeError:
                value = {"markdown": text}
            cache[key] = value
            timestamps[key] = now()
            return value
        except httpx.HTTPStatusError as error:
            if error.response.status_code not in {429, 502, 503, 504} or attempt == 3:
                raise
            retry_after = error.response.headers.get("Retry-After", "")
            if retry_after.isdigit():
                await asyncio.sleep(min(int(retry_after), 120))
    raise RuntimeError("MCP rate limit retry budget exhausted")


async def article(session, cache, url, delay):
    """GET verifies locale/redirects; MCP fetch verifies the actual article body."""
    key = "article:" + learn_url(url)
    if key in cache and (datetime.now(timezone.utc) -
                         datetime.fromisoformat(cache[key]["checkedAt"])).days < 30:
        return cache[key]
    failures = []
    for locale in ("ja-jp", "en-us"):
        candidate = learn_url(url, locale)
        async with httpx.AsyncClient(follow_redirects=True, timeout=60) as client:
            response = await client.get(candidate)
        if response.status_code == 404 and locale == "ja-jp":
            failures.append("ja-jp: HTTP 404 (localized article unavailable)")
            continue
        response.raise_for_status()
        final_url = str(response.url)
        learn_url(final_url)
        html = response.text
        page_locale = re.search(r'<meta\s+name="locale"\s+content="([^"]+)"', html, re.I)
        if not page_locale or page_locale[1].lower() != locale:
            failures.append(f"{locale}: returned a different article locale")
            continue
        fetched = await call(session, cache, "fetch:" + final_url, "microsoft_docs_fetch",
                             {"url": final_url}, delay)
        body = fetched.get("markdown", json.dumps(fetched, ensure_ascii=False))
        title = re.search(r"^#\s+(.+)", body, re.M)
        if not title or len(body) < 500:
            raise ValueError("Article body/title could not be verified")
        # A localized shell around an English article is not a Japanese article.
        if locale == "ja-jp" and len(re.findall(r"[ぁ-んァ-ヶ一-龠]", body)) < 100:
            failures.append("ja-jp: article body is not Japanese")
            continue
        value = {"url": final_url, "title": title[1].strip().removesuffix(" | Microsoft Learn"),
                 "locale": locale, "checkedAt": now(),
                 "bodySha256": hashlib.sha256(body.encode()).hexdigest(),
                 "localeEvidence": "GET locale metadata and fetched article body",
                 "localeFallback": failures}
        cache[key] = value
        return value
    raise ValueError("No confirmed article body: " + "; ".join(failures))


async def run(args):
    root = args.snapshot_root.resolve()
    messages = snapshots(root)
    queries = read(args.queries, {})
    reviews = read(args.reviews, {})
    cache = read(args.cache, {})
    timestamps = cache.setdefault("_checkedAt", {})
    for key in cache:
        if key != "_checkedAt" and key not in timestamps:
            timestamps[key] = now()
    output = read(args.output, {"schemaVersion": 1, "messages": {}})
    selected = sorted(messages)
    if args.ids:
        selected = args.ids.split(",")
        if set(selected) - messages.keys():
            raise ValueError("Requested ID is absent from approved snapshots")
    audit = {
        "uniqueMessages": len(messages),
        "snapshotOccurrences": sum(len(entry["snapshots"]) for entry in messages.values()),
        "snapshots": len({str(path) for path in root.glob("history/*/messages.json")})
        + int((root / "latest/messages.json").exists())
        + sum(not (path.parent / "messages.json").exists()
              for path in root.glob("history/*/index.html")),
        "publicationStart": min(entry["message"]["startDateTime"] for entry in messages.values()),
        "publicationEnd": max(entry["message"]["startDateTime"] for entry in messages.values()),
    }
    if args.audit:
        print(json.dumps(audit, indent=2))
        return
    async with streamable_http_client(ENDPOINT) as (reader, writer, _):
        async with ClientSession(reader, writer) as session:
            await session.initialize()
            available = {tool.name for tool in (await session.list_tools()).tools}
            if not {"microsoft_docs_search", "microsoft_docs_fetch"} <= available:
                raise RuntimeError("Public Learn MCP tool contract unavailable")
            for identifier in selected:
                source = messages[identifier]
                previous = output["messages"].get(identifier)
                review = reviews.get(identifier)
                query = queries.get(identifier)
                review_hash = hashlib.sha256(json.dumps(review, sort_keys=True).encode()).hexdigest()
                recent = previous and (datetime.now(timezone.utc) -
                                      datetime.fromisoformat(previous["checkedAt"])).days < 30
                if (recent and previous["sourceHashes"] == sorted(source["hashes"])
                        and previous.get("reviewHash") == review_hash
                        and previous.get("query") == query
                        and previous["status"] != "fetch_failed" and not args.refresh and not args.ids):
                    continue
                entry = {"sourceHashes": sorted(source["hashes"]), "status": "not_researched",
                         "checkedAt": now(), "documents": [], "reviewHash": review_hash,
                         "query": query, "explicitUrls": explicit_urls(source["message"]),
                         "searchProvider": "Microsoft Learn public MCP", "errors": []}
                try:
                    if query:
                        # Queries are an operator-maintained product/feature-only allowlist.
                        result = await call(session, cache, "search:" + query,
                                            "microsoft_docs_search", {"query": query}, args.delay)
                        entry["searchEvidenceKey"] = "search:" + query
                        entry["status"] = "no_verified_document"
                        entry["rationale"] = "Learn search completed; no feature/platform-specific article has been approved. Similar names, Q&A answers and unrelated product pages are not adopted."
                        if args.search_only:
                            results = result.get("results", [])
                            print(identifier, json.dumps(
                                [{"title": r.get("title"), "url": r.get("contentUrl")}
                                 for r in results[:4]], ensure_ascii=False), flush=True)
                    if review:
                        entry["reviewedAt"] = now()
                        entry["rationale"] = review["rationale"]
                        urls = list(dict.fromkeys(entry["explicitUrls"] + review["urls"]))
                        for url in urls[:3]:
                            canonical = learn_url(url, "en-us")
                            english = await call(session, cache, "fetch:" + canonical, "microsoft_docs_fetch",
                                                 {"url": canonical}, args.delay)
                            english_body = english.get("markdown", json.dumps(english, ensure_ascii=False))
                            if any(term.lower() not in english_body.lower()
                                   for term in review.get("requiredTerms", [])):
                                entry["rationale"] += " Full article did not confirm the required feature/platform terms."
                                continue
                            document = await article(session, cache, url, args.delay)
                            entry["documents"].append({
                                **document, "source": "explicit_message_link"
                                if learn_url(url) in entry["explicitUrls"] else "learn_mcp_search",
                                "rationale": review["rationale"],
                                "featureEvidence": {
                                    "canonicalArticle": canonical,
                                    "bodySha256": hashlib.sha256(english_body.encode()).hexdigest(),
                                    "confirmedTerms": review.get("requiredTerms", []),
                                    "reviewedAt": entry["reviewedAt"],
                                },
                            })
                        entry["status"] = "verified" if entry["documents"] else "no_verified_document"
                    elif entry["explicitUrls"] and not args.search_only:
                        for url in entry["explicitUrls"][:3]:
                            document = await article(session, cache, url, args.delay)
                            entry["documents"].append({**document, "source": "explicit_message_link",
                                "rationale": "Official article explicitly linked by this approved message."})
                        entry["status"] = "verified"
                except (httpx.HTTPError, RuntimeError, ValueError, TimeoutError) as error:
                    entry["status"] = "fetch_failed"
                    entry["errors"].append({"type": type(error).__name__, "message": str(error)[:500]})
                    print(f"{identifier}: fetch_failed: {error}", flush=True)
                output["messages"][identifier] = entry
                output["audit"] = {**audit, "checkedAt": now()}
                save(args.cache, cache)
                save(args.output, output)
                if not args.search_only:
                    print(f'{identifier}: {entry["status"]} ({len(entry["documents"])} documents)', flush=True)
    counts = {state: sum(e["status"] == state for i, e in output["messages"].items()
                         if i in messages) for state in sorted(STATES)}
    output["audit"] = {**audit, "checkedAt": now()}
    output["audit"]["counts"] = counts
    save(args.output, output)
    print(json.dumps(counts))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot-root", type=Path, default=ROOT / "reports/m365")
    parser.add_argument("--queries", type=Path, default=ROOT / "scripts/document-queries.json")
    parser.add_argument("--reviews", type=Path, default=ROOT / "scripts/document-reviews.json")
    parser.add_argument("--output", type=Path, default=ROOT / "reports/m365/related-documents.json")
    parser.add_argument("--cache", type=Path, default=ROOT / ".cache/m365-documents.json")
    parser.add_argument("--ids")
    parser.add_argument("--delay", type=float, default=1.0)
    parser.add_argument("--audit", action="store_true")
    parser.add_argument("--search-only", action="store_true")
    parser.add_argument("--refresh", action="store_true")
    args = parser.parse_args()
    if args.refresh:
        save(args.cache, {})
    asyncio.run(run(args))


if __name__ == "__main__":
    main()
