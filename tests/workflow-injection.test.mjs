// Workflow injection guard (adapted from m365-copilot-update-digest): untrusted event fields must
// never be interpolated into run/script blocks, and third-party actions must be pinned to a commit SHA.
import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const dir = new URL("../.github/workflows/", import.meta.url);
const files = fs.readdirSync(dir).filter(name => name.endsWith(".yml") && !name.endsWith(".lock.yml"));
const UNTRUSTED = /\$\{\{[^}]*github\.(event\.[a-z_.]*(title|body|ref|label|name|message|login|email)|head_ref)[^}]*\}\}/i;
const read = file => fs.readFileSync(new URL(file, dir), "utf8");

test("hand-written workflows never interpolate untrusted event fields inside run or script blocks", () => {
  const bad = [];
  for (const file of files) {
    let inBlock = false;
    let indent = 0;
    read(file).split(/\r?\n/).forEach((line, index) => {
      const start = line.match(/^(\s*)(?:-\s+)?(run|script):\s*(.*)$/);
      if (start) {
        inBlock = true;
        indent = start[1].length;
        if (UNTRUSTED.test(start[3])) bad.push(`${file}:${index + 1}`);
        return;
      }
      if (inBlock && line.trim() && line.match(/^(\s*)/)[1].length <= indent) {
        inBlock = false;
        return;
      }
      if (inBlock && UNTRUSTED.test(line)) bad.push(`${file}:${index + 1}`);
    });
  }
  assert.deepEqual(bad, [], `move these into env: ${bad.join(", ")}`);
});

test("third-party actions are pinned to a full commit SHA", () => {
  const unpinned = [];
  for (const file of files) {
    for (const match of read(file).matchAll(/^\s*-?\s*uses:\s*(\S+)/gm)) {
      const ref = match[1];
      if (/^(actions|github)\//.test(ref) || ref.startsWith("./")) continue;
      if (!/@[0-9a-f]{40}$/.test(ref)) unpinned.push(`${file}: ${ref}`);
    }
  }
  assert.deepEqual(unpinned, [], "pin third-party actions to a 40-character commit SHA after review");
});

test("the detector itself flags a known-bad pattern", () => {
  assert.ok(UNTRUSTED.test("echo ${{ github.event.pull_request.title }}"));
  assert.ok(UNTRUSTED.test("${{ github.head_ref }}"));
  assert.ok(!UNTRUSTED.test("${{ github.run_id }}"));
});
