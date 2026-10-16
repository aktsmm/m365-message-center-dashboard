import asyncio
import importlib.util
import json
import tempfile
import unittest
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from pathlib import Path
from unittest.mock import AsyncMock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("documents", ROOT / "scripts/Update-M365RelatedDocuments.py")
documents = importlib.util.module_from_spec(spec)
spec.loader.exec_module(documents)
from m365_document_matching import public_query, relevance, safe_query


class DocumentsTests(unittest.TestCase):
    def test_generated_queries_never_contain_private_tokens_or_body(self):
        message = {"id": "MC9999999",
                   "title": "ContosoSecret Microsoft Entra: agents permission user@example.test "
                            "https://private.test/acme 12345678-aaaa-bbbb-cccc-123456789abc",
                   "bodyText": "customer-secret-value tenant@example.test",
                   "services": ["ContosoSecret"]}
        query = public_query(message)
        self.assertIn("entra", query)
        for forbidden in ("Contoso", "example", "private", "12345678", "customer", "MC999"):
            self.assertNotIn(forbidden.lower(), query.lower())
        safe_query(query)

    def test_relevance_rejects_similar_products_and_cross_section_term_soup(self):
        message = {"title": "Microsoft Entra passkey profiles", "services": []}
        self.assertIsNone(relevance(message, "https://learn.microsoft.com/entra/external-id/customers/passkeys",
                                    "# Customer passkey profiles\nCustomer sign-in passkey profiles."))
        message = {"title": "Microsoft Teams meeting transcription toggle", "services": []}
        self.assertIsNone(relevance(message, "https://learn.microsoft.com/deployedge/settings",
                                    "# Edge controls\nTranscription in meetings." +
                                    "\n\n" + "Unrelated text. " * 300 + "\n# Teams\nToggle controls."))
        self.assertIsNotNone(relevance(message, "https://learn.microsoft.com/microsoftteams/transcription",
                                       "# Teams meeting transcription toggle\nUse the toggle in a meeting."))

    def test_relevance_rejects_wrong_platform_and_generic_overview(self):
        message = {"title": "PowerPoint Mac custom skills", "services": []}
        self.assertIsNone(relevance(message, "https://learn.microsoft.com/microsoft-365/copilot/custom-skills",
                                    "# PowerPoint custom skills\nCreate custom skills on Windows."))
        message = {"title": "Microsoft Agent 365 usage activity insights", "services": []}
        self.assertIsNone(relevance(message, "https://learn.microsoft.com/microsoft-365/admin/agent-overview",
                                    "# Agent overview\nMicrosoft Agent 365 usage activity insights are listed elsewhere."))

    def test_unseen_id_is_automatically_searched_and_matched_without_registration(self):
        message = {"id": "MC9990001", "title": "Microsoft Teams meeting transcription",
                   "bodyText": "Private tenant content must stay local", "services": ["Teams"]}
        url = "https://learn.microsoft.com/microsoftteams/meeting-transcription"
        body = "# Teams meeting transcription\n" + "Configure meeting transcription in Teams. " * 30
        calls = []

        async def fake_call(session, cache, key, tool, args, delay, **kwargs):
            calls.append((tool, args))
            if tool == "microsoft_docs_search":
                return {"results": [{"contentUrl": url, "title": "Teams meeting transcription", "content": body}]}
            return {"markdown": body}

        article = {"url": url.replace("com/", "com/ja-jp/"), "title": "Teams の会議文字起こし",
                   "locale": "ja-jp", "checkedAt": documents.now(), "bodySha256": "a" * 64}
        with patch.object(documents, "call", side_effect=fake_call), patch.object(
                documents, "article", new=AsyncMock(return_value=article)):
            entry = asyncio.run(documents.research(AsyncMock(), {}, message, public_query(message), None, 0))
        self.assertEqual(entry["status"], "verified")
        self.assertEqual(entry["documents"][0]["source"], "automatic_learn_search")
        self.assertTrue(entry["documents"][0]["featureEvidence"]["articleExcerpt"])
        self.assertNotIn("Private", json.dumps(calls))
        self.assertNotIn("MC9990001", json.dumps(calls))

    def test_unsuccessful_search_is_researched_not_manual_review_queue(self):
        message = {"id": "MC9990002", "title": "Microsoft Teams unknown feature", "services": []}
        with patch.object(documents, "call", new=AsyncMock(return_value={"results": []})):
            entry = asyncio.run(documents.research(AsyncMock(), {}, message, public_query(message), None, 0))
        self.assertEqual(entry["status"], "no_verified_document")
        self.assertEqual(documents.retry_days(entry), 3)
        self.assertFalse(documents.due(entry, documents.digest(message), entry["query"], entry["reviewHash"]))
        entry["checkedAt"] = (datetime.now(timezone.utc) - timedelta(days=4)).isoformat()
        self.assertTrue(documents.due(entry, documents.digest(message), entry["query"], entry["reviewHash"]))

    def test_redirected_articles_cannot_pad_a_card_with_duplicate_links(self):
        message = {"id": "MC9990005", "title": "Microsoft Teams transcription",
                   "bodyText": "https://learn.microsoft.com/microsoftteams/old-page "
                               "https://learn.microsoft.com/microsoftteams/new-page", "services": []}
        body = "# Teams transcription\n" + "Transcription in Microsoft Teams. " * 30
        async def fake_call(*args, **kwargs):
            return {"results": []} if args[3] == "microsoft_docs_search" else {"markdown": body}
        article = {"url": "https://learn.microsoft.com/ja-jp/microsoftteams/new-page",
                   "title": "Teams 文字起こし", "locale": "ja-jp",
                   "checkedAt": documents.now(), "bodySha256": "a" * 64}
        with patch.object(documents, "call", side_effect=fake_call), patch.object(
                documents, "article", new=AsyncMock(return_value=article)):
            entry = asyncio.run(documents.research(AsyncMock(), {}, message, public_query(message), None, 0))
        self.assertEqual(len(entry["documents"]), 1)
        self.assertEqual(entry["candidates"][-1]["decision"], "duplicate_after_official_redirect")

    def test_search_failure_is_automatically_retryable(self):
        message = {"id": "MC9990003", "title": "Microsoft Teams", "services": []}
        with patch.object(documents, "call", new=AsyncMock(side_effect=TimeoutError())):
            entry = asyncio.run(documents.research(AsyncMock(), {}, message, public_query(message), None, 0))
        self.assertEqual(entry["status"], "fetch_failed")
        self.assertFalse(documents.due(entry, documents.digest(message), entry["query"], entry["reviewHash"]))
        entry["checkedAt"] = (datetime.now(timezone.utc) - timedelta(hours=7)).isoformat()
        self.assertTrue(documents.due(entry, documents.digest(message), entry["query"], entry["reviewHash"]))

    def test_new_snapshot_and_changed_variants_resume_automatically(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            message = {"id": "MC9990004", "title": "Microsoft Teams meeting transcription",
                       "bodyText": "First version", "services": [], "startDateTime": "2026-10-10T00:00:00Z"}
            old = {"meta": {"source": "fixture"}, "messages": [message]}
            documents.save(root / "history/2026-10-10/messages.json", old)
            latest = {"meta": {"source": "fixture"}, "messages": [{**message, "bodyText": "Second version"}]}
            documents.save(root / "latest/messages.json", latest)
            args = SimpleNamespace(snapshot_root=root, queries=root / "queries.json",
                                   reviews=root / "reviews.json", cache=root / "cache.json",
                                   output=root / "catalog.json", check=False, audit=False, ids=None,
                                   refresh=False, max_messages=1, max_seconds=60, search_only=False,
                                   delay=0, summary=None)
            session = AsyncMock()
            session.list_tools.return_value = SimpleNamespace(tools=[
                SimpleNamespace(name="microsoft_docs_search"), SimpleNamespace(name="microsoft_docs_fetch")])
            client = AsyncMock()
            client.__aenter__.return_value = session

            class Transport:
                async def __aenter__(self):
                    return None, None, None

                async def __aexit__(self, *args):
                    return False

            async def fake_research(session, cache, source, query, review, delay):
                return {"sourceHashes": [documents.digest(source)], "status": "no_verified_document",
                        "documents": [], "checkedAt": documents.now(), "query": query,
                        "reviewHash": __import__("hashlib").sha256(b"null").hexdigest(),
                        "researchVersion": documents.RESEARCH_VERSION, "errors": []}

            with patch.object(documents, "streamable_http_client", return_value=Transport()), patch.object(
                    documents, "ClientSession", return_value=client), patch.object(
                    documents, "research", side_effect=fake_research) as worker:
                asyncio.run(documents.run(args))
                first = documents.read(args.output, {})
                self.assertEqual(first["messages"][message["id"]]["status"], "no_verified_document")
                self.assertEqual(first["audit"]["pendingAttempts"], 1)
                asyncio.run(documents.run(args))
                second = documents.read(args.output, {})
                self.assertEqual(worker.call_count, 2)
                self.assertEqual(second["audit"]["pendingAttempts"], 0)
                asyncio.run(documents.run(args))
                self.assertEqual(worker.call_count, 2)
            documents.validate_catalog(second, documents.snapshots(root), complete=True)
            self.assertEqual(documents.read(root / "latest/messages.json", {}), latest)
            self.assertEqual(documents.snapshots(root)[message["id"]]["message"]["bodyText"], "Second version")

    def test_catalog_completeness_gate_runs_after_enrichment_not_before(self):
        catalog = {"schemaVersion": 1, "messages": {}}
        documents.validate_catalog(catalog)
        with self.assertRaises(ValueError):
            documents.validate_catalog(catalog, {"MC9999": {"hashes": {"a" * 64}}}, complete=True)

    def test_workflows_keep_catalog_in_every_pages_artifact(self):
        for name in ("m365-dashboard-public.yml", "m365-weekly-insights.md", "m365-weekly-translations.md"):
            text = (ROOT / ".github/workflows" / name).read_text(encoding="utf-8-sig")
            self.assertIn("Copy-Item reports/m365/related-documents.json $pagesDir -Force", text)
        text = (ROOT / ".github/workflows/m365-related-documents.yml").read_text(encoding="utf-8-sig")
        self.assertIn("cron: '37 2,14 * * *'", text)
        self.assertIn("--summary", text)
        self.assertIn("--check", text)
        self.assertIn("actions/cache/save@", text)

    def test_article_redirects_are_checked_before_requesting_another_host(self):
        client = AsyncMock()
        client.__aenter__.return_value = client
        client.get.return_value = documents.httpx.Response(
            302, headers={"Location": "https://private.example.test/collect"},
            request=documents.httpx.Request("GET", "https://learn.microsoft.com/ja-jp/copilot/edge"))
        with patch.object(documents.httpx, "AsyncClient", return_value=client):
            with self.assertRaises(ValueError):
                asyncio.run(documents.article(AsyncMock(), {}, "https://learn.microsoft.com/copilot/edge", 0))
        self.assertEqual(client.get.call_count, 1)

    def test_strict_official_article_urls(self):
        for value in ("http://learn.microsoft.com/a/b", "https://learn.microsoft.com.evil/a/b",
                      "https://user@learn.microsoft.com/a/b", "https://learn.microsoft.com/copilot",
                      "https://learn.microsoft.com/answers/a/1",
                      "https://learn.microsoft.com/copilot/edge?tenant=private"):
            with self.assertRaises(ValueError):
                documents.learn_url(value)
        self.assertEqual(documents.learn_url("https://learn.microsoft.com/en-us/copilot/edge", "ja-jp"),
                         "https://learn.microsoft.com/ja-jp/copilot/edge")

    def test_explicit_links_are_prioritized_and_deduplicated(self):
        message = {"bodyText": "https://learn.microsoft.com/en-us/copilot/edge). https://evil.test/a",
                   "details": [{"value": "https://learn.microsoft.com/copilot/edge"}]}
        self.assertEqual(documents.explicit_urls(message), ["https://learn.microsoft.com/copilot/edge"])
        message = {"bodyText": "https://learn.microsoft.com/entra/passkey/setup%22%20target=_blank",
                   "details": []}
        self.assertEqual(documents.explicit_urls(message), ["https://learn.microsoft.com/entra/passkey/setup"])

    def test_feature_binding_and_preserving_source(self):
        message = {"id": "MC1", "title": "Feature", "bodyText": "Body", "services": ["Teams"], "tags": []}
        before = json.dumps(message)
        fingerprint = documents.digest(message)
        self.assertEqual(json.dumps(message), before)
        self.assertEqual(fingerprint, documents.digest({**message, "officialDocumentUrls": []}))
        self.assertNotEqual(fingerprint, documents.digest({**message, "bodyText": "Other feature"}))

    def test_checkpoints_are_atomic_and_readable(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.json"
            documents.save(path, {"status": "fetch_failed"})
            self.assertEqual(documents.read(path, {}), {"status": "fetch_failed"})
            self.assertFalse(path.with_suffix(".json.tmp").exists())

    def test_cache_does_not_call_mcp(self):
        session = AsyncMock()
        result = asyncio.run(documents.call(session, {"key": {"results": []},
                                            "_checkedAt": {"key": documents.now()}}, "key", "search", {}, 0))
        self.assertEqual(result, {"results": []})
        session.call_tool.assert_not_called()

    def test_rate_limit_has_bounded_retries(self):
        session = AsyncMock()
        result = type("Result", (), {"isError": True, "content": [type("Content", (), {"text": "429"})()]})()
        session.call_tool.return_value = result
        with self.assertRaises(RuntimeError):
            asyncio.run(documents.call(session, {}, "key", "search", {}, 0))
        self.assertEqual(session.call_tool.call_count, 4)

    def test_confirmed_english_fallback_for_unavailable_japanese(self):
        base = "https://learn.microsoft.com/copilot/edge"
        client = AsyncMock()
        client.__aenter__.return_value = client
        client.get.side_effect = [
            documents.httpx.Response(404, request=documents.httpx.Request("GET", documents.learn_url(base, "ja-jp"))),
            documents.httpx.Response(200, text='<meta name="locale" content="en-us">',
                                    request=documents.httpx.Request("GET", documents.learn_url(base, "en-us"))),
        ]
        with patch.object(documents.httpx, "AsyncClient", return_value=client), patch.object(
                documents, "call", new=AsyncMock(return_value={"markdown": "# Verified English article\n" + "Article body. " * 100})):
            result = asyncio.run(documents.article(AsyncMock(), {}, base, 0))
        self.assertEqual(result["locale"], "en-us")
        self.assertTrue(result["localeFallback"])
        self.assertTrue(result["url"].startswith("https://learn.microsoft.com/en-us/"))

    def test_public_annotation_contract(self):
        catalog = documents.read(ROOT / "reports/m365/related-documents.json", {})
        # A newly collected snapshot is input to enrichment, not a fixture failure.
        # Full snapshot coverage is checked AFTER enrichment with --check.
        documents.validate_catalog(catalog)

    def test_renderer_binds_documents_and_rejects_unsafe_urls(self):
        source = documents.read(ROOT / "reports/m365/latest/messages.json", {})
        message = source["messages"][0]
        entry = {"sourceHashes": [documents.digest(message)], "status": "verified",
                 "checkedAt": documents.now(), "documents": [{
                     "url": "https://learn.microsoft.com/ja-jp/copilot/edge",
                     "title": "Verified article", "rationale": "Exact feature",
                     "locale": "ja-jp", "checkedAt": documents.now(), "bodySha256": "a" * 64}]}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            documents.save(path / "messages.json", source)
            catalog = {"schemaVersion": 1, "messages": {message["id"]: entry}}
            documents.save(path / "documents.json", catalog)
            command = ["pwsh", "-NoProfile", "-File", str(ROOT / "scripts/New-M365MessageCenterDashboard.ps1"),
                       "-MessagesJson", str(path / "messages.json"),
                       "-RelatedDocumentsJson", str(path / "documents.json"),
                       "-OutputPath", str(path / "index.html")]
            subprocess.run(command, check=True, capture_output=True)
            html = (path / "index.html").read_text(encoding="utf-8-sig")
            self.assertIn("Verified article", html)
            self.assertIn("メッセージ原文", html)
            self.assertIn("data-open-detail", html)
            embedded = json.JSONDecoder().raw_decode(html.split("const DATA = ", 1)[1])[0]
            self.assertEqual(source, embedded)
            entry["sourceHashes"] = ["b" * 64]
            documents.save(path / "documents.json", catalog)
            subprocess.run(command, check=True, capture_output=True)
            self.assertNotIn("Verified article", (path / "index.html").read_text(encoding="utf-8-sig"))
            entry["sourceHashes"] = [documents.digest(message)]
            entry["documents"][0]["url"] = "https://evil.test/article"
            documents.save(path / "documents.json", catalog)
            result = subprocess.run(command, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            entry["documents"] = []
            documents.save(path / "documents.json", catalog)
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)


if __name__ == "__main__":
    unittest.main()
