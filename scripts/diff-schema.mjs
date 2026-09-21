#!/usr/bin/env node
// Phase 0: compare dump/public-schema.sql (pg_dump of the live DB) with docs/schema-inventory.json
// (built from types.ts). Reports tables/columns/functions present on one side only.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const dumpPath = resolve(here, "../dump/public-schema.sql");
if (!existsSync(dumpPath)) { console.error("dump/public-schema.sql not found — run scripts/dump.sh first"); process.exit(1); }
const inv = JSON.parse(readFileSync(resolve(here, "../docs/schema-inventory.json"), "utf8"));
const sql = readFileSync(dumpPath, "utf8");

const dumpTables = {};
for (const m of sql.matchAll(/CREATE TABLE (?:IF NOT EXISTS )?public\.(\w+) \(([\s\S]*?)\n\);/g)) {
  const cols = {};
  for (const line of m[2].split("\n")) {
    const c = /^\s{4}(\w+)\s+(.+?),?$/.exec(line);
    if (c && !/^(CONSTRAINT)$/i.test(c[1])) cols[c[1]] = c[2].replace(/,$/, "");
  }
  dumpTables[m[1]] = cols;
}
const dumpFns = new Set([...sql.matchAll(/CREATE (?:OR REPLACE )?FUNCTION public\.(\w+)\(/g)].map((m) => m[1]));
const dumpTriggers = [...sql.matchAll(/CREATE TRIGGER (\w+) .*? ON public\.(\w+)/g)].map((m) => `${m[1]} on ${m[2]}`);
const dumpEnums = {};
for (const m of sql.matchAll(/CREATE TYPE public\.(\w+) AS ENUM \(([\s\S]*?)\);/g)) dumpEnums[m[1]] = [...m[2].matchAll(/'([^']+)'/g)].map((x) => x[1]);
const dumpPolicies = (sql.match(/CREATE POLICY/g) ?? []).length;

const out = ["# Schema diff: live dump vs types.ts inventory\n"];
const invTables = Object.fromEntries(inv.tables.map((t) => [t.name, t]));
out.push("## Tables\n");
for (const name of new Set([...Object.keys(dumpTables), ...Object.keys(invTables)]).values()) {
  const d = dumpTables[name], i = invTables[name];
  if (!d) { out.push(`- \`${name}\`: **in types.ts only** (not in dump!)`); continue; }
  if (!i) { out.push(`- \`${name}\`: **in dump only** (types.ts is stale)`); continue; }
  const dc = new Set(Object.keys(d)), ic = new Set(i.columns.map((c) => c.name));
  const onlyDump = [...dc].filter((c) => !ic.has(c)), onlyTypes = [...ic].filter((c) => !dc.has(c));
  if (onlyDump.length || onlyTypes.length) out.push(`- \`${name}\`: dump-only columns [${onlyDump.join(", ")}], types-only columns [${onlyTypes.join(", ")}]`);
}
out.push("\n## Column types from the dump (authoritative)\n");
for (const [t, cols] of Object.entries(dumpTables)) {
  out.push(`### ${t}\n`);
  for (const [c, def] of Object.entries(cols)) out.push(`- ${c}: ${def}`);
  out.push("");
}
out.push("## Functions\n");
const invFns = new Set(inv.functions.map((f) => f.name));
out.push(`- in dump only: ${[...dumpFns].filter((f) => !invFns.has(f)).join(", ") || "—"}`);
out.push(`- in types.ts only: ${[...invFns].filter((f) => !dumpFns.has(f)).join(", ") || "—"}`);
out.push(`\n## Triggers in dump (${dumpTriggers.length})\n`);
for (const t of dumpTriggers) out.push(`- ${t}`);
out.push(`\n## Enums in dump\n`);
for (const [n, v] of Object.entries(dumpEnums)) {
  const iv = inv.enums[n] ?? [];
  const same = JSON.stringify(v) === JSON.stringify(iv);
  out.push(`- \`${n}\`: ${v.join(", ")}${same ? "" : `  **(types.ts has: ${iv.join(", ")})**`}`);
}
out.push(`\nRLS policies in dump: ${dumpPolicies}`);
writeFileSync(resolve(here, "../docs/schema-diff.md"), out.join("\n"));
console.log("wrote docs/schema-diff.md");
