const DashboardView = (() => {
  const DAY = 86400000;
  const filterValues = ["all", "major", "due", "high", "soon", "overdue"];
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

  return { DAY, normalizeText, validDate, readFilters, writeFilters, deadlineBucket,
    priorityCompare, sortMessages, inDateRange, excerpt, facts, citationIds, freshness };
})();
