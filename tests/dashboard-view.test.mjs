import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import test from "node:test";

const source = fs.readFileSync(new URL("../scripts/dashboard-view.js", import.meta.url), "utf8");
const view = vm.runInNewContext(`${source}\nDashboardView`, { URL, Date });
const plain = value => JSON.parse(JSON.stringify(value));
const reference = Date.parse("2026-10-16T00:00:00Z");

test("full share state round-trips without losing theme, verification or detail anchors", () => {
  const state = { query: "日本語 Copilot", filter: "soon", documentStatus: "verified",
    sort: "deadline", from: "2026-10-01", to: "2026-10-16" };
  const url = view.writeFilters("https://example.test/?scoutTheme=dark&verify=commit&focus=identity#message-MC1", state);
  assert.deepEqual(plain(view.readFilters(url.href)), { ...state, warning: "" });
  assert.equal(url.searchParams.get("scoutTheme"), "dark");
  assert.equal(url.searchParams.get("focus"), "identity");
  assert.equal(url.hash, "#message-MC1");
});

test("invalid URL values cannot create invalid filters or silent invalid dates", () => {
  const state = view.readFilters("https://example.test/?from=2026-02-30&sort=evil&filter=bad&docs=bad");
  assert.equal(state.from, "");
  assert.equal(state.sort, "updated");
  assert.equal(state.filter, "all");
  assert.equal(state.documentStatus, "all");
  assert.ok(state.warning);
  assert.equal(view.validDate("2028-02-29"), true);
  assert.equal(view.validDate("2026-02-29"), false);
});

test("deadline priority does not let old deadlines displace upcoming changes", () => {
  const records = [
    { id: "MC1", actionRequiredByDateTime: "2026-08-01T00:00:00Z", isMajorChange: true },
    { id: "MC2", actionRequiredByDateTime: "2026-10-19T00:00:00Z" },
    { id: "MC3", isMajorChange: true },
    { id: "MC4", actionRequiredByDateTime: "2027-02-01T00:00:00Z" }
  ];
  assert.deepEqual(plain(view.sortMessages(records, "deadline", reference).map(message => message.id)),
    ["MC2", "MC3", "MC4", "MC1"]);
  assert.equal(view.deadlineBucket(records[0], reference), "overdue");
  assert.equal(view.deadlineBucket(records[1], reference), "soon");
  assert.equal(view.deadlineBucket({ actionRequiredByDateTime: "bad" }, reference), "none");
});

test("date filters use an inclusive Japan calendar day and never rewrite the source", () => {
  const message = { id: "MC1", lastModifiedDateTime: "2026-10-15T15:00:00Z" };
  const before = JSON.stringify(message);
  assert.equal(view.inDateRange(message, "2026-10-16", "2026-10-16"), true);
  assert.equal(view.inDateRange({ lastModifiedDateTime: "2026-10-16T15:00:00Z" }, "", "2026-10-16"), false);
  assert.equal(view.inDateRange(message, "2026-10-17", "2026-10-16"), false);
  assert.equal(JSON.stringify(message), before);
});

test("facts are bounded original excerpts, missing fields are not invented", () => {
  const message = { bodyText: "Updated October 1: Timeline changed.\nNew capability.\n"
    + "[Rollout schedule]\nStarts in November.\n[Impact on your organization]\nAdmins.\n"
    + "[Action required/recommendations]\nReview the setting." };
  const facts = plain(view.facts(message));
  assert.equal(facts.find(fact => fact.key === "change").text, "New capability.");
  assert.equal(facts.find(fact => fact.key === "timing").text, "Starts in November.");
  assert.equal(facts.find(fact => fact.key === "action").text, "Review the setting.");
  assert.equal(view.facts({ bodyText: "" }).length, 0);
  assert.equal(view.excerpt("x".repeat(500)).length, 241);
});

test("literal escaped newlines and citation IDs are normalized once", () => {
  assert.equal(view.normalizeText("MC123: A\\nMC456: B"), "MC123: A\nMC456: B");
  assert.deepEqual(plain(view.citationIds("MC123: A\\nmc456: B MC123")), ["MC123", "MC456"]);
  assert.equal(view.normalizeText(String.raw`Open C:\new\report or \\network\share`),
    String.raw`Open C:\new\report or \\network\share`);
  assert.equal(view.excerpt(String.raw`Open C:\new\report`), String.raw`Open C:\new\report`);
});

test("freshness has explicit stale and unknown states, not success-shaped fallbacks", () => {
  assert.equal(view.freshness("2026-10-15T00:00:00Z", reference), "current");
  assert.equal(view.freshness("2026-10-01T00:00:00Z", reference), "stale");
  assert.equal(view.freshness("bad", reference), "unknown");
  assert.equal(view.freshness("2027-01-01T00:00:00Z", reference), "unknown");
});

test("headline takes a bounded first Japanese sentence", () => {
  assert.equal(view.headline("Teams の会議が変わります。詳細は次の通りです。"), "Teams の会議が変わります。");
  const long = view.headline(`${"あ".repeat(60)}、${"い".repeat(60)}。`);
  assert.ok(long.length <= 81 && long.endsWith("…"));
  assert.equal(view.headline("  "), "");
});

test("qa never invents answers and labels basis", () => {
  const message = { id: "MC1", title: "T", bodyText: "[What and why]: New feature arrives.", actionRequiredByDateTime: null };
  const items = plain(view.qa(message));
  assert.equal(items.length, 5);
  assert.equal(items[0].basis, "original-excerpt");
  assert.equal(items[1].basis, "not-in-source");
  assert.equal(items[1].answer, view.NOT_IN_SOURCE);
  const verified = plain(view.qa(message, { headline: "新機能が追加されます。", translationStatus: "current" }));
  assert.equal(verified[0].basis, "verified-translation");
});

test("csv neutralizes formulas and notes cite sources", () => {
  const record = view.exportRecord({ id: "MC2", title: "=cmd()", bodyText: "", services: ["Teams"] },
    { headline: "見出し", translationStatus: "unverified", originalUrl: "https://admin.microsoft.com/x", documents: [] });
  assert.equal(record.headlineStatus, "saved-unverified");
  const csv = view.toCsv([record]);
  assert.ok(csv.startsWith("\uFEFF"));
  assert.ok(csv.includes(`"'=cmd()"`));
  const notes = view.notesMarkdown([record], {});
  assert.ok(notes.includes("想定問答") && notes.includes("原文未照合") === false || notes.includes("未照合"));
  assert.ok(notes.includes("https://admin.microsoft.com/x"));
});
