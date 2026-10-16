"""Enrich only on-disk, approved snapshots; never connect to Microsoft Graph."""

import argparse
import asyncio
import hashlib
import json
import re
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import unquote, urlsplit, urlunsplit

import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client
from mcp.shared.exceptions import McpError

from m365_document_matching import alternate_queries, public_query, relevance

ROOT = Path(__file__).resolve().parents[1]
ENDPOINT = "https://learn.microsoft.com/api/mcp"
STATES = {"not_researched", "no_verified_document", "fetch_failed", "verified"}
RESEARCH_VERSION = 4


def now():
    return datetime.now(timezone.utc).isoformat()


def read(path, default):
    return json.loads(path.read_text(encoding="utf-8-sig")) if path.exists() else default


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    # Windows indexers/scanners can briefly hold the destination; retry the atomic replace.
    for attempt in range(6):
        try:
            temporary.replace(path)
            return
        except PermissionError:
            if attempt == 5:
                raise
            time.sleep(1 + attempt)


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
    if re.search(r"""[\s<>"']""", unquote(path)):
        raise ValueError("HTML fragments or whitespace are not official article paths")
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
    paths = sorted(list(root.glob("history/*/messages.json")) + [
        path for path in root.glob("history/*/index.html")
        if not (path.parent / "messages.json").exists()])
    paths += [root / "latest/messages.json"]
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
            entry = found.setdefault(identifier, {"message": message, "hashes": set(),
                                                   "variants": {}, "snapshots": []})
            entry["message"] = message
            entry["hashes"].add(digest(message))
            entry["variants"][digest(message)] = message
            entry["snapshots"].append(path.parent.name)
    return found


def explicit_urls(message):
    text = message.get("bodyText", "") + "\n" + "\n".join(
        str(detail.get("value", "")) for detail in message.get("details", []))
    text += "\n" + "\n".join(message.get("officialDocumentUrls", []))
    urls = []
    for match in re.findall(r"https://learn\.microsoft\.com/[^\s<>\"']+", text):
        try:
            # Older public exports can contain percent-encoded HTML attribute tails.
            candidate = re.split(r"""[\s<>"']""", unquote(match))[0].rstrip(").,;]")
            normalized = learn_url(candidate).split("#")[0]
        except ValueError:
            continue
        if normalized not in urls:
            urls.append(normalized)
    return urls


async def call(session, cache, key, tool, arguments, delay, ttl_days=30):
    timestamps = cache.setdefault("_checkedAt", {})
    if (key in cache and key in timestamps and
            (datetime.now(timezone.utc) - datetime.fromisoformat(timestamps[key])).total_seconds() < ttl_days * 86400):
        return cache[key]
    for attempt in range(4):
        await asyncio.sleep(delay * (2 ** attempt))
        try:
            async with asyncio.timeout(90):
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
        except (httpx.HTTPError, McpError, TimeoutError) as error:
            if isinstance(error, httpx.HTTPStatusError) and error.response.status_code not in {429, 502, 503, 504}:
                raise
            if attempt == 3:
                raise
            retry_after = error.response.headers.get("Retry-After", "") if isinstance(error, httpx.HTTPStatusError) else ""
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
        async with httpx.AsyncClient(follow_redirects=False, timeout=60) as client:
            for _ in range(6):
                for attempt in range(4):
                    await asyncio.sleep(delay * (2 ** attempt))
                    try:
                        response = await client.get(candidate)
                    except (httpx.TimeoutException, httpx.TransportError):
                        if attempt == 3:
                            raise
                        continue
                    if response.status_code not in {429, 502, 503, 504} or attempt == 3:
                        break
                    retry_after = response.headers.get("Retry-After", "")
                    if retry_after.isdigit():
                        await asyncio.sleep(min(int(retry_after), 120))
                if response.status_code not in {301, 302, 303, 307, 308}:
                    break
                candidate = str(response.url.join(response.headers["location"]))
                learn_url(candidate)  # Validate every hop before making the next request.
            else:
                raise ValueError("Too many official article redirects")
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


def retry_days(entry):
    if entry.get("errors"):
        return 0.25
    return {"verified": 30, "no_verified_document": 3, "fetch_failed": 0.25,
            "not_researched": 0}[entry["status"]]


def due(entry, fingerprint, query, review_hash, force=False):
    if force or not entry:
        return True
    if (entry.get("researchVersion") != RESEARCH_VERSION or
            fingerprint not in entry.get("sourceHashes", []) or
            entry.get("query") != query or entry.get("reviewHash") != review_hash):
        return True
    age = (datetime.now(timezone.utc) - datetime.fromisoformat(entry["checkedAt"])).total_seconds()
    return age >= retry_days(entry) * 86400


def failed_attempt(message, query, review, reason):
    return {
        "sourceHashes": [digest(message)], "status": "fetch_failed", "checkedAt": now(),
        "documents": [], "query": query,
        "reviewHash": hashlib.sha256(json.dumps(review, sort_keys=True).encode()).hexdigest(),
        "researchVersion": RESEARCH_VERSION, "searchProvider": "Microsoft Learn public MCP",
        "errors": [{"type": "TimeoutError", "message": reason}],
        "nextAttemptAt": (datetime.now(timezone.utc) + timedelta(hours=6)).isoformat(),
    }


def validate_catalog(catalog, sources=None, complete=False):
    if catalog.get("schemaVersion") != 1 or not isinstance(catalog.get("messages"), dict):
        raise ValueError("Invalid documentation catalog schema")
    if complete and set(catalog["messages"]) != set(sources):
        raise ValueError("Catalog does not cover all approved message IDs")
    for identifier, entry in catalog["messages"].items():
        entries = [entry] + list(entry.get("variants", {}).values())
        for variant in entries:
            if variant["status"] not in STATES or len(variant["documents"]) > 3:
                raise ValueError(f"Invalid annotation state: {identifier}")
            if variant["status"] == "verified" and not variant["documents"]:
                raise ValueError(f"Empty verified annotation: {identifier}")
            if len({document["url"] for document in variant["documents"]}) != len(variant["documents"]):
                raise ValueError(f"Duplicate official article links: {identifier}")
            datetime.fromisoformat(variant["checkedAt"])
            for document in variant["documents"]:
                canonical = learn_url(document["url"], document["locale"])
                if (not document["title"] or not document["rationale"] or
                        document["locale"] not in {"ja-jp", "en-us"} or
                        canonical != document["url"] or
                        not re.fullmatch(r"[a-f0-9]{64}", document["bodySha256"])):
                    raise ValueError(f"Invalid article evidence: {identifier}")
                datetime.fromisoformat(document["checkedAt"])
                text = document["title"] + " " + document["rationale"]
                if re.search(r"<\s*(script|iframe|object|embed|style|svg)\b|javascript:|data:text/html",
                             text, re.I):
                    raise ValueError(f"Unsafe article evidence: {identifier}")
                if variant.get("researchVersion") == RESEARCH_VERSION:
                    evidence = document.get("featureEvidence", {})
                    if (not evidence.get("canonicalArticle") or
                            not re.fullmatch(r"[a-f0-9]{64}", evidence.get("bodySha256", ""))):
                        raise ValueError(f"Missing fetched article evidence: {identifier}")
                    if document["source"] == "automatic_learn_search" and (
                            not evidence.get("matchedTerms") or not evidence.get("articleExcerpt") or
                            evidence.get("coverage", 0) < 0.7):
                        raise ValueError(f"Insufficient automatic relevance evidence: {identifier}")
        if complete:
            covered = set(entry["sourceHashes"])
            for variant in entry.get("variants", {}).values():
                covered.update(variant["sourceHashes"])
            if covered != sources[identifier]["hashes"]:
                raise ValueError(f"Catalog is missing a changed snapshot variant: {identifier}")
    if complete and "audit" in catalog:
        audit = catalog["audit"]
        counts = {state: sum(entry["status"] == state for entry in catalog["messages"].values())
                  for state in sorted(STATES)}
        if audit.get("counts") != counts:
            raise ValueError("Published research counts do not match the actual annotations")
        if audit.get("coverage") == "complete" and (
                audit.get("pendingAttempts", 0) or counts["not_researched"] or counts["fetch_failed"]):
            raise ValueError("Incomplete research queue must not claim complete coverage")


async def research(session, cache, message, query, review, delay):
    """Research unseen IDs without any manually registered query/review prerequisite."""
    fingerprint = digest(message)
    review_hash = hashlib.sha256(json.dumps(review, sort_keys=True).encode()).hexdigest()
    entry = {"sourceHashes": [fingerprint], "status": "not_researched", "checkedAt": now(),
             "documents": [], "reviewHash": review_hash, "query": query,
             "explicitUrls": explicit_urls(message), "searchProvider": "Microsoft Learn public MCP",
             "researchVersion": RESEARCH_VERSION, "errors": [], "candidates": []}
    candidates = {url: "explicit_message_link" for url in entry["explicitUrls"]}
    for url in (review or {}).get("urls", []):
        try:
            candidates.setdefault(learn_url(url).split("#")[0], "reviewed_candidate")
        except ValueError:
            entry["errors"].append({"type": "invalid_review_url", "message": "Rejected non-article URL"})
    searched = False
    try:
        # Even a new/unknown feature always gets a safe product/feature-only query.
        searched_queries = [query]
        for current in [query] + alternate_queries(message, query):
            if current != query and any(source != "explicit_message_link" for source in candidates.values()):
                break
            result = await call(session, cache, "search:" + current, "microsoft_docs_search",
                                {"query": current}, delay, ttl_days=3)
            if not isinstance(result.get("results"), list):
                raise ValueError("Learn search returned an invalid results schema")
            searched = True
            if current != query:
                searched_queries.append(current)
            for item in result["results"]:
                try:
                    url = learn_url(item["contentUrl"]).split("#")[0]
                except (KeyError, ValueError):
                    continue
                if url in candidates:
                    continue
                # Rank snippets locally before fetching; source text never leaves the process.
                match = relevance(message, url, "# " + item.get("title", "") + "\n" + item.get("content", ""))
                if match:
                    candidates[url] = "automatic_learn_search"
        entry["searchEvidenceKey"] = "search:" + query
        entry["searchedQueries"] = searched_queries
    except (httpx.HTTPError, McpError, RuntimeError, ValueError, TimeoutError) as error:
        entry["errors"].append({"type": type(error).__name__, "message": "Public Learn search failed"})
        print(f'{message["id"]}: public Learn search: {type(error).__name__}', flush=True)
    entry["searchSucceeded"] = searched
    # One broken explicit URL must not prevent checking the next article.
    for url, source in list(candidates.items())[:6]:
        evidence = {"url": url, "source": source}
        try:
            canonical = learn_url(url, "en-us")
            english = await call(session, cache, "fetch:" + canonical, "microsoft_docs_fetch",
                                 {"url": canonical}, delay, ttl_days=3)
            body = english.get("markdown", json.dumps(english, ensure_ascii=False))
            match = relevance(message, url, body)
            # An explicit link establishes the association; reviewed candidates still
            # require local matching when source content changes, like automatic results.
            if source != "explicit_message_link" and not match:
                evidence["decision"] = "rejected_feature_or_platform_mismatch"
                entry["candidates"].append(evidence)
                continue
            if review and url in review.get("urls", []) and any(
                    term.lower() not in body.lower() for term in review.get("requiredTerms", [])):
                evidence["decision"] = "rejected_required_feature_terms"
                entry["candidates"].append(evidence)
                continue
            document = await article(session, cache, url, delay)
            if any(existing["url"] == document["url"] for existing in entry["documents"]):
                evidence["decision"] = "duplicate_after_official_redirect"
                entry["candidates"].append(evidence)
                continue
            rationale = ("Explicit official article from this approved notification."
                         if source == "explicit_message_link" else
                         "Automatic local product/feature/platform match against a fetched official article; "
                         "rollout dates and stage remain authoritative in the notification.")
            entry["documents"].append({
                **document, "source": source, "rationale": rationale,
                "featureEvidence": {**(match or {}), "canonicalArticle": canonical,
                                    "bodySha256": hashlib.sha256(body.encode()).hexdigest(),
                                    "reviewedAt": now()},
            })
            evidence["decision"] = "adopted"
            if match:
                evidence["score"] = match["score"]
        except (httpx.HTTPError, McpError, RuntimeError, ValueError, TimeoutError) as error:
            evidence["decision"] = "fetch_failed"
            entry["errors"].append({"type": type(error).__name__, "url": url,
                                    "message": "Public official article could not be verified"})
            print(f'{message["id"]}: article {url}: {type(error).__name__}', flush=True)
        entry["candidates"].append(evidence)
        if len(entry["documents"]) == 3:
            break
    entry["status"] = ("verified" if entry["documents"] else
                       "fetch_failed" if entry["errors"] else "no_verified_document")
    if not searched and not entry["documents"]:
        entry["status"] = "fetch_failed"
    entry["rationale"] = ("Articles verified against this snapshot version." if entry["documents"] else
                          "Automatic Learn research completed without a sufficiently matching article."
                          if entry["status"] == "no_verified_document" else
                          "Public documentation retrieval failed; automatic retry is pending.")
    entry["nextAttemptAt"] = (datetime.now(timezone.utc) + timedelta(
        days=retry_days(entry))).isoformat()
    return entry


async def run(args):
    root = args.snapshot_root.resolve()
    messages = snapshots(root)
    queries = read(args.queries, {})
    reviews = read(args.reviews, {})
    cache = read(args.cache, {})
    output = read(args.output, {"schemaVersion": 1, "messages": {}})
    validate_catalog(output)
    if args.check:
        validate_catalog(output, messages, complete=True)
        print(json.dumps(output.get("audit", {})))
        return
    selected = set(messages)
    if args.ids:
        selected = set(args.ids.split(","))
        if selected - messages.keys():
            raise ValueError("Requested ID is absent from approved snapshots")
    dates = [datetime.fromisoformat(entry["message"]["startDateTime"]) for entry in messages.values()]
    audit = {
        "uniqueMessages": len(messages),
        "snapshotOccurrences": sum(len(entry["snapshots"]) for entry in messages.values()),
        "snapshots": len({str(path) for path in root.glob("history/*/messages.json")})
        + int((root / "latest/messages.json").exists())
        + sum(not (path.parent / "messages.json").exists()
              for path in root.glob("history/*/index.html")),
        "publicationStart": min(dates).isoformat(),
        "publicationEnd": max(dates).isoformat(),
    }
    if args.audit:
        print(json.dumps(audit, indent=2))
        return
    saved_checkpoint = cache.get("_checkpoint", {})
    for identifier, entry in saved_checkpoint.get("messages", {}).items():
        if identifier in messages and saved_checkpoint.get("schemaVersion") == 1:
            validate_catalog({"schemaVersion": 1, "messages": {identifier: entry}})
            current = output["messages"].get(identifier)
            if not current or datetime.fromisoformat(entry["checkedAt"]) > datetime.fromisoformat(current["checkedAt"]):
                output["messages"][identifier] = entry
    jobs = []
    for identifier, source in messages.items():
        previous = output["messages"].get(identifier, {})
        old_variants = {fingerprint: previous for fingerprint in previous.get("sourceHashes", [])}
        old_variants.update(previous.get("variants", {}))
        variants = {}
        for fingerprint, message in source["variants"].items():
            # Overrides are optional hints, not a prerequisite and never raw outbound text.
            query = public_query({"title": queries[identifier]}) if identifier in queries else public_query(message)
            review = reviews.get(identifier)
            review_hash = hashlib.sha256(json.dumps(review, sort_keys=True).encode()).hexdigest()
            entry = old_variants.get(fingerprint)
            if entry:
                entry = {key: value for key, value in entry.items() if key != "variants"}
                entry["sourceHashes"] = [fingerprint]
            else:
                entry = {"sourceHashes": [fingerprint], "status": "not_researched",
                         "documents": [], "checkedAt": now(), "query": query, "errors": []}
            variants[fingerprint] = entry
            if identifier in selected and due(entry, fingerprint, query, review_hash,
                                              force=args.refresh or bool(args.ids)):
                primary = fingerprint == digest(source["message"])
                priority = (0 if primary and entry["status"] == "not_researched" else
                            1 if entry["status"] in {"not_researched", "fetch_failed"} else
                            2 if entry["status"] == "no_verified_document" else 3)
                jobs.append((priority, entry["checkedAt"], identifier, fingerprint, message, query, review))
        primary_hash = digest(source["message"])
        output["messages"][identifier] = {**variants[primary_hash],
            "variants": {key: value for key, value in variants.items() if key != primary_hash}}

    def checkpoint(force_cache=False):
        counts = {state: sum(output["messages"][i]["status"] == state for i in messages)
                  for state in sorted(STATES)}
        latest = read(root / "latest/messages.json", {"messages": []})["messages"]
        latest_counts = {state: sum(output["messages"][m["id"]]["status"] == state for m in latest)
                         for state in sorted(STATES)}
        variant_entries = [entry for source in output["messages"].values()
                           for entry in [source, *source.get("variants", {}).values()]]
        variant_counts = {state: sum(entry["status"] == state for entry in variant_entries)
                          for state in sorted(STATES)}
        pending = max(0, len(jobs) - processed)
        retrieval_errors = sum(len(entry.get("errors", [])) for entry in variant_entries)
        output["audit"] = {**audit, "checkedAt": now(), "counts": counts, "latestCounts": latest_counts,
                           "latestTotal": len(latest), "pendingAttempts": max(0, len(jobs) - processed),
                           "processedThisRun": processed, "variantCounts": variant_counts,
                           "retrievalErrors": retrieval_errors,
                           "coverage": "partial" if pending or variant_counts["not_researched"] or
                           variant_counts["fetch_failed"] or retrieval_errors else "complete",
                           "researchVersion": RESEARCH_VERSION}
        validate_catalog(output, messages, complete=True)
        if not args.search_only:
            cache["_checkpoint"] = output
            save(args.output, output)
            if force_cache or processed % 5 == 0:
                save(args.cache, cache)

    jobs.sort(key=lambda job: job[:4])
    processed = 0
    started = time.monotonic()
    checkpoint(force_cache=True)  # Queue exists durably even if MCP initialization fails.
    if jobs:
        async with streamable_http_client(ENDPOINT) as (reader, writer, _):
            async with ClientSession(reader, writer) as session:
                await session.initialize()
                available = {tool.name for tool in (await session.list_tools()).tools}
                if not {"microsoft_docs_search", "microsoft_docs_fetch"} <= available:
                    raise RuntimeError("Public Learn MCP tool contract unavailable")
                consecutive_failures = 0
                for _, _, identifier, fingerprint, message, query, review in jobs:
                    if processed >= args.max_messages or time.monotonic() - started >= args.max_seconds:
                        break
                    if args.search_only:
                        result = await call(session, cache, "search:" + query,
                                            "microsoft_docs_search", {"query": query}, args.delay, ttl_days=3)
                        print(identifier, json.dumps([
                            {"title": item.get("title"), "url": item.get("contentUrl")}
                            for item in result.get("results", [])[:4]], ensure_ascii=False), flush=True)
                        save(args.cache, cache)
                        processed += 1
                        continue
                    remaining = args.max_seconds - (time.monotonic() - started)
                    try:
                        async with asyncio.timeout(min(180, remaining)):
                            entry = await research(session, cache, message, query, review, args.delay)
                    except TimeoutError:
                        entry = failed_attempt(message, query, review, "Per-notification research time budget exceeded")
                    current = output["messages"][identifier]
                    if fingerprint == digest(messages[identifier]["message"]):
                        output["messages"][identifier] = {**entry, "variants": current["variants"]}
                    else:
                        current["variants"][fingerprint] = entry
                    processed += 1
                    checkpoint(force_cache=True)
                    print(f'{identifier} {fingerprint[:8]}: {entry["status"]} '
                          f'({len(entry["documents"])} documents)', flush=True)
                    service_failed = entry["status"] == "fetch_failed" and not entry.get("searchSucceeded")
                    consecutive_failures = consecutive_failures + 1 if service_failed else 0
                    if consecutive_failures >= 2:
                        print("Public documentation service failed twice; checkpoint saved for the next scheduled run.",
                              flush=True)
                        break
    checkpoint()
    if args.summary:
        args.summary.write_text(
            "## Official documentation research\n\n```json\n" +
            json.dumps(output["audit"], indent=2) + "\n```\n", encoding="utf-8")
    print(json.dumps(output["audit"]))


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
    parser.add_argument("--check", action="store_true", help="Validate coverage after enrichment, without network")
    parser.add_argument("--summary", type=Path)
    parser.add_argument("--max-messages", type=int, default=300)
    parser.add_argument("--max-seconds", type=int, default=1200)
    args = parser.parse_args()
    if args.max_messages < 1 or args.max_seconds < 1 or args.delay < 0:
        parser.error("Budgets must be positive and the request delay must be nonnegative")
    if args.refresh:
        save(args.cache, {})
    asyncio.run(run(args))


if __name__ == "__main__":
    main()
