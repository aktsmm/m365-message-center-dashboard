import asyncio
import importlib.util
import json
import tempfile
import unittest
import subprocess
from pathlib import Path
from unittest.mock import AsyncMock, patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("documents", ROOT / "scripts/Update-M365RelatedDocuments.py")
documents = importlib.util.module_from_spec(spec)
spec.loader.exec_module(documents)


class DocumentsTests(unittest.TestCase):
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
        sources = documents.snapshots(ROOT / "reports/m365")
        self.assertEqual(set(catalog["messages"]), set(sources))
        for identifier, entry in catalog["messages"].items():
            self.assertIn(entry["status"], documents.STATES)
            self.assertEqual(entry["sourceHashes"], sorted(sources[identifier]["hashes"]))
            self.assertLessEqual(len(entry["documents"]), 3)
            if entry["status"] == "verified":
                self.assertTrue(entry["documents"])
            for document in entry["documents"]:
                documents.learn_url(document["url"])
                self.assertTrue(document["title"])
                self.assertTrue(document["rationale"])
                self.assertRegex(document["bodySha256"], r"^[a-f0-9]{64}$")
                self.assertIn(document["locale"], {"ja-jp", "en-us"})

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
