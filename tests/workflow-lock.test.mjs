// Workflow hygiene: gh-aw lock files match the prompts they were compiled from, and no
// workflow widens its permissions, opens roles to everyone, or runs untrusted PR code with secrets.
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { createHash } from "node:crypto";

const dir = new URL("../.github/workflows", import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1");
const names = fs.readdirSync(dir);
const sha = text => createHash("sha256").update(text).digest("hex");

test("every agentic workflow has a lock file compiled from its current prompt", () => {
  for (const file of names.filter(name => name.endsWith(".md"))) {
    const lockFile = file.replace(/\.md$/, ".lock.yml");
    assert.ok(names.includes(lockFile), `${file} has no compiled ${lockFile}; run \`gh aw compile\``);
    const lock = fs.readFileSync(path.join(dir, lockFile), "utf8");
    const meta = JSON.parse(lock.match(/gh-aw-metadata: (\{.*\})/)?.[1] ?? "null");
    assert.ok(meta?.body_hash, `${lockFile} has no gh-aw metadata`);
    const source = fs.readFileSync(path.join(dir, file), "utf8").replace(/\r\n/g, "\n");
    const body = source.match(/^---\n[\s\S]*?\n---\n?([\s\S]*)$/)?.[1] ?? "";
    assert.equal(sha(body.trim()), meta.body_hash,
      `${file} was edited after ${lockFile} was compiled; run \`gh aw compile\` and commit the lock file`);
  }
});

test("workflows keep least-privilege defaults", () => {
  for (const file of names.filter(name => name.endsWith(".yml"))) {
    const text = fs.readFileSync(path.join(dir, file), "utf8");
    assert.match(text, /^\s*permissions:/m, `${file} must declare its permissions`);
    assert.doesNotMatch(text, /write-all/, `${file} must not use write-all`);
    assert.doesNotMatch(text, /pull_request_target/, `${file} must not use pull_request_target`);
    assert.doesNotMatch(text, /roles:\s*(?:all|\[\s*all\s*\])/, `${file} must not open roles to everyone`);
  }
});
