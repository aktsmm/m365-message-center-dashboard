const DashboardView = (() => {
  const DAY = 86400000;
  const filterValues = ["all", "major", "due", "high", "soon", "overdue", "now", "month"];
  const documentValues = ["all", "verified", "no_verified_document", "fetch_failed", "not_researched"];
  const sortValues = ["updated", "deadline", "start"];
  const normalizeText = value => String(value || "").split(/((?:[A-Za-z]:\\|\\\\)[^\s]+)/g)
    .map((part, index) => index % 2 ? part : part.replace(/\\r\\n|\\n|\\r/g, "\n"))
    .join("").replace(/\r\n/g, "\n");
  const dateValue = value => value ? Date.parse(value) : NaN;

  function validDate(value) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(value || "")) return false;
    const parsed = new Date(`${value}T00:00:00Z`);
    return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
  }

  function readFilters(url) {
    const params = new URL(url).searchParams;
    const state = {
      query: String(params.get("q") || "").slice(0, 300),
      filter: filterValues.includes(params.get("filter")) ? params.get("filter") : "all",
      documentStatus: documentValues.includes(params.get("docs")) ? params.get("docs") : "all",
      sort: sortValues.includes(params.get("sort")) ? params.get("sort") : "updated",
      from: validDate(params.get("from")) ? params.get("from") : "",
      to: validDate(params.get("to")) ? params.get("to") : ""
    };
    const invalidDates = ["from", "to"].some(key => params.get(key) && !validDate(params.get(key)));
    return { ...state, warning: invalidDates ? "URL の日付条件が不正なため、その日付条件を除外しました。" : "" };
  }

  function writeFilters(url, state) {
    const result = new URL(url);
    for (const key of ["q", "filter", "docs", "sort", "from", "to"]) result.searchParams.delete(key);
    if (state.query) result.searchParams.set("q", state.query);
    if (state.filter !== "all") result.searchParams.set("filter", state.filter);
    if (state.documentStatus !== "all") result.searchParams.set("docs", state.documentStatus);
    if (state.sort !== "updated") result.searchParams.set("sort", state.sort);
    if (state.from) result.searchParams.set("from", state.from);
    if (state.to) result.searchParams.set("to", state.to);
    return result;
  }

  function deadlineBucket(message, reference = Date.now()) {
    const deadline = dateValue(message.actionRequiredByDateTime);
    if (!Number.isFinite(deadline)) return "none";
    if (deadline < reference) return "overdue";
    return deadline <= reference + 30 * DAY ? "soon" : "later";
  }

  // Deterministic triage: no AI, derived only from the published deadline, dates and wording.
  const URGENT_TITLE = /\b(action (?:may be )?required|retir\w*|deprecat\w*|end of support|will be removed|breaking change|no longer)\b/i;
  const TIERS = {
    now: { label: "今すぐ確認", rank: 0 },
    month: { label: "今月準備", rank: 1 },
    info: { label: "情報のみ", rank: 2 },
    past: { label: "期限経過", rank: 3 }
  };

  function tier(message, reference = Date.now()) {
    const bucket = deadlineBucket(message, reference);
    if (bucket === "overdue") return "past";
    if (bucket === "soon" || URGENT_TITLE.test(String(message.title || ""))) return "now";
    const start = dateValue(message.startDateTime);
    const nearRollout = Number.isFinite(start) && start >= reference - 30 * DAY && start <= reference + 45 * DAY;
    return bucket === "later" || message.isMajorChange || nearRollout ? "month" : "info";
  }

  const CATEGORY_LABELS = {
    plan_for_change: "計画が必要", planforchange: "計画が必要",
    stay_informed: "情報提供", stayinformed: "情報提供",
    prevent_or_fix_issue: "問題の予防・修正", preventorfixissue: "問題の予防・修正"
  };
  function categoryLabel(value) {
    const key = String(value || "").toLowerCase().replace(/[\s-]/g, "_");
    return CATEGORY_LABELS[key] || CATEGORY_LABELS[key.replace(/_/g, "")] || String(value || "未分類");
  }

  // "(Updated)" notices lead with a dated change note; surface it instead of burying it.
  function updateNote(message) {
    if (!/^\s*\(updated\)/i.test(String(message.title || ""))) return null;
    const text = String(message.bodyText || "").replace(/\r\n/g, "\n");
    const match = text.match(/^\s*Updated\s+([A-Za-z]+ \d{1,2}, \d{4})\s*:?\s*([^\n]*(?:\n(?!\s*\n)[^\n]*)?)/i);
    if (!match) return null;
    const note = excerpt(match[2], 200);
    return note ? { date: match[1], text: note } : null;
  }

  function priorityCompare(left, right, reference = Date.now()) {
    const rank = message => {
      const bucket = deadlineBucket(message, reference);
      return bucket === "soon" ? 0 : message.isMajorChange && bucket !== "overdue" ? 1
        : bucket === "later" ? 2 : bucket === "overdue" ? 4 : 3;
    };
    const difference = rank(left) - rank(right);
    if (difference) return difference;
    const leftDeadline = dateValue(left.actionRequiredByDateTime);
    const rightDeadline = dateValue(right.actionRequiredByDateTime);
    if (Number.isFinite(leftDeadline) && Number.isFinite(rightDeadline) && leftDeadline !== rightDeadline) {
      return deadlineBucket(left, reference) === "overdue"
        ? rightDeadline - leftDeadline : leftDeadline - rightDeadline;
    }
    return (dateValue(right.lastModifiedDateTime) || 0) - (dateValue(left.lastModifiedDateTime) || 0)
      || String(left.id).localeCompare(String(right.id));
  }

  function sortMessages(messages, sort, reference = Date.now()) {
    return [...messages].sort(sort === "deadline"
      ? (left, right) => priorityCompare(left, right, reference)
      : (left, right) => (dateValue(right[sort === "start" ? "startDateTime" : "lastModifiedDateTime"]) || 0)
        - (dateValue(left[sort === "start" ? "startDateTime" : "lastModifiedDateTime"]) || 0)
        || String(left.id).localeCompare(String(right.id)));
  }

  function inDateRange(message, from, to) {
    if (from && to && from > to) return false;
    if (!from && !to) return true;
    const updated = dateValue(message.lastModifiedDateTime);
    if (!Number.isFinite(updated)) return false;
    return (!from || updated >= Date.parse(`${from}T00:00:00+09:00`))
      && (!to || updated < Date.parse(`${to}T00:00:00+09:00`) + DAY);
  }

  function excerpt(value, limit = 240) {
    const text = String(value || "").replace(/\s+/g, " ").trim();
    return text.length > limit ? `${text.slice(0, limit).trimEnd()}…` : text;
  }

  function facts(message) {
    const text = String(message.bodyText || "").replace(/\r\n/g, "\n");
    const sections = [];
    const headings = [...text.matchAll(/^\s*\[([^\]\n]{2,110})\]\s*:?\s*/gm)];
    for (let index = 0; index < headings.length; index++) {
      const heading = headings[index];
      sections.push({
        heading: heading[1].replace(/:$/, "").trim().toLowerCase(),
        body: text.slice(heading.index + heading[0].length, headings[index + 1]?.index ?? text.length)
      });
    }
    const find = pattern => excerpt(sections.find(section => pattern.test(section.heading))?.body || "");
    const intro = text.slice(0, headings[0]?.index ?? text.length)
      .replace(/^Updated[^\n]*\n?/i, "").trim();
    const changed = find(/what and why|what.*new|introduction|summary/) || excerpt(intro);
    return [
      { key: "change", label: "変更", text: changed },
      { key: "impact", label: "影響", text: find(/impact|affect|who.*affected/) },
      { key: "timing", label: "時期", text: find(/rollout|when.*happen|schedule/) },
      { key: "action", label: "対応", text: find(/action required|recommendation|need to do|can do|prepare/) }
    ].filter(fact => fact.text);
  }

  function citationIds(value) {
    return [...new Set((normalizeText(value).match(/\bMC\d+\b/gi) || []).map(id => id.toUpperCase()))];
  }

  function freshness(value, reference = Date.now(), hours = 120) {
    const timestamp = dateValue(value);
    if (!Number.isFinite(timestamp) || timestamp > reference + DAY) return "unknown";
    return reference - timestamp > hours * 3600000 ? "stale" : "current";
  }

  // A scannable Japanese lead taken from the first sentence of an existing Japanese summary.
  function headline(summary, limit = 80) {
    const text = String(summary || "").replace(/\s+/g, " ").trim();
    if (!text) return "";
    const sentence = text.split(/(?<=[。．!！?？])/)[0].trim();
    if (sentence.length <= limit) return sentence;
    const cut = sentence.slice(0, limit);
    const boundary = Math.max(cut.lastIndexOf("、"), cut.lastIndexOf("，"), cut.lastIndexOf(" "));
    return `${(boundary >= limit * 0.5 ? cut.slice(0, boundary) : cut).trimEnd()}…`;
  }

  function formatJst(value) {
    const timestamp = dateValue(value);
    return Number.isFinite(timestamp)
      ? new Intl.DateTimeFormat("ja-JP", { year: "numeric", month: "long", day: "numeric", timeZone: "Asia/Tokyo" })
        .format(new Date(timestamp))
      : "";
  }

  const NOT_IN_SOURCE = "提供された原文の抜粋では確認できません。管理センターの原文で確認してください。";

  // Source-grounded Q&A: answers are verified Japanese text or original excerpts, never inferred.
  function qa(message, { headline: japanese = "", translationStatus = "missing" } = {}) {
    const found = Object.fromEntries(facts(message).map(fact => [fact.key, fact.text]));
    const answer = (question, text, basis, language = "en") => text
      ? { question, answer: text, basis, language }
      : { question, answer: NOT_IN_SOURCE, basis: "not-in-source", language: "ja" };
    const deadline = formatJst(message.actionRequiredByDateTime);
    return [
      japanese && translationStatus === "current"
        ? { question: "何が変わりますか？", answer: japanese, basis: "verified-translation", language: "ja" }
        : answer("何が変わりますか？", found.change, "original-excerpt"),
      answer("誰に影響しますか？", found.impact, "original-excerpt"),
      answer("いつから始まりますか？", found.timing, "original-excerpt"),
      answer("管理者は何をすべきですか？", found.action, "original-excerpt"),
      deadline
        ? { question: "対応期限はありますか？", answer: `原文に ${deadline} の対応期限が記載されています。`, basis: "original-metadata", language: "ja" }
        : { question: "対応期限はありますか？", answer: "原文に対応期限の記載はありません。", basis: "original-metadata", language: "ja" }
    ];
  }

  function exportRecord(message, context = {}) {
    const translationStatus = context.translationStatus || "missing";
    return {
      id: message.id,
      title: message.title,
      japaneseHeadline: context.headline || "",
      headlineStatus: context.headline ? (translationStatus === "current" ? "verified" : "saved-unverified") : "pending",
      category: message.category || "",
      severity: message.severity || "",
      isMajorChange: Boolean(message.isMajorChange),
      priorityTier: tier(message),
      updateNote: updateNote(message),
      services: [...(message.services || [])],
      startDateTime: message.startDateTime || null,
      lastModifiedDateTime: message.lastModifiedDateTime || null,
      actionRequiredByDateTime: message.actionRequiredByDateTime || null,
      originalUrl: context.originalUrl || "",
      documentStatus: context.documentStatus || "not_researched",
      documents: (context.documents || []).map(document => ({ title: document.title, url: document.url, locale: document.locale })),
      facts: facts(message),
      qa: qa(message, { headline: context.headline, translationStatus })
    };
  }

  const csvCell = value => {
    let text = String(value ?? "").replace(/\r?\n/g, " ");
    if (/^[=+\-@\t\r]/.test(text)) text = `'${text}`;
    return `"${text.replace(/"/g, '""')}"`;
  };

  const CSV_COLUMNS = ["id", "title", "japaneseHeadline", "headlineStatus", "category", "severity", "isMajorChange",
    "services", "startDateTime", "lastModifiedDateTime", "actionRequiredByDateTime", "originalUrl",
    "documentStatus", "documents"];

  function toCsv(records) {
    const rows = records.map(record => CSV_COLUMNS.map(column => csvCell(
      column === "services" ? record.services.join("; ")
        : column === "documents" ? record.documents.map(document => `${document.title} <${document.url}>`).join("; ")
          : record[column])));
    return `\uFEFF${[CSV_COLUMNS.map(csvCell).join(","), ...rows.map(row => row.join(","))].join("\r\n")}`;
  }

  function notesMarkdown(records, { generatedAt = "", conditions = "" } = {}) {
    const basis = { "verified-translation": "検証済みの日本語要約", "original-excerpt": "原文抜粋（英語）",
      "original-metadata": "原文メタデータ", "not-in-source": "原文に記載なし" };
    const body = records.map(record => [
      `## ${record.id} ${record.japaneseHeadline || record.title}`,
      record.japaneseHeadline ? `原題: ${record.title}` : "",
      record.headlineStatus === "saved-unverified" ? "※日本語見出しは保存済みで、現在の原文版は未照合です。" : "",
      "",
      "### 想定問答",
      ...record.qa.flatMap(item => [`**Q. ${item.question}**`, `A. ${item.answer}`, `（根拠: ${basis[item.basis]}）`, ""]),
      "### 出典",
      record.originalUrl ? `- メッセージ原文: ${record.originalUrl}` : "- メッセージ原文: 管理センターで確認してください",
      ...record.documents.map(document => `- ${document.title}: ${document.url}`),
      ""
    ].filter(line => line !== "" || true).join("\n")).join("\n");
    return `# Microsoft 365 変更通知 想定問答（スライドノート用）\n\n`
      + `この問答は原文の抜粋と検証済みの要約だけで作成しています。回答は推測しません。${generatedAt ? `\n\nスナップショット: ${generatedAt}` : ""}`
      + `${conditions ? `\n\n表示条件: ${conditions}` : ""}\n\n${body}\n`;
  }

  function translationEta(pending, perRun = 4) {
    return { pending, runs: Math.ceil(pending / perRun), days: Math.ceil(pending / perRun) };
  }

  return { DAY, normalizeText, validDate, readFilters, writeFilters, deadlineBucket,
    priorityCompare, sortMessages, inDateRange, excerpt, facts, citationIds, freshness,
    headline, formatJst, qa, exportRecord, toCsv, notesMarkdown, translationEta, NOT_IN_SOURCE,
    tier, TIERS, categoryLabel, updateNote };
})();
