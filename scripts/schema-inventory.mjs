#!/usr/bin/env node
// Phase 0: build a machine-readable inventory of the live schema from the generated Supabase
// types file (src/integrations/supabase/types.ts, generated from the live DB) and mark which
// objects the repo's supabase/migrations/ actually define.
//
// Output: docs/schema-inventory.json and docs/schema-inventory.md
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const SRC = process.env.SRC_REPO ?? resolve(here, "../../baqala-connect-yemen");
const typesPath = resolve(SRC, "src/integrations/supabase/types.ts");
const migDir = resolve(SRC, "supabase/migrations");

// ---------- tiny parser for TS object-type literals ----------
let text = readFileSync(typesPath, "utf8").replace(/\/\/.*$/gm, "");
let pos = 0;
const ws = () => { while (pos < text.length && /[\s,;]/.test(text[pos])) pos++; };
function parseBlock() {
  // assumes text[pos] === '{'
  pos++;
  const obj = {};
  for (;;) {
    ws();
    if (text[pos] === "}") { pos++; return obj; }
    const m = /^(\[[^\]]*\]|[A-Za-z_][\w]*)\??\s*:/.exec(text.slice(pos, pos + 80));
    if (!m) throw new Error("bad key at " + text.slice(pos, pos + 60));
    const key = m[1];
    const optional = text.slice(pos, pos + m[0].length).includes("?");
    pos += m[0].length;
    ws();
    let val;
    let isArray = false;
    if (text[pos] === "{") { val = parseBlock(); if (text.startsWith("[]", pos)) { pos += 2; isArray = true; } }
    else if (text[pos] === "[") val = parseArray();
    else val = parseScalar();
    obj[key] = { val, optional, isArray };
  }
}
function parseArray() {
  pos++; // [
  const items = [];
  for (;;) {
    ws();
    if (text[pos] === "]") { pos++; return items; }
    if (text[pos] === "{") items.push(parseBlock());
    else items.push(parseScalar());
  }
}
function parseScalar() {
  // read until ';' or '}' or ']' at depth 0, or a newline not followed by a '|' continuation
  let out = "";
  let depth = 0;
  for (;;) {
    const c = text[pos];
    if (c === undefined) break;
    if (c === '"') { const e = text.indexOf('"', pos + 1); out += text.slice(pos, e + 1); pos = e + 1; continue; }
    if (c === "[" || c === "(" || c === "<") depth++;
    if (c === "]" || c === ")" || c === ">") { if (depth === 0) break; depth--; }
    if (depth === 0 && (c === ";" || c === "}" )) break;
    if (c === "\n") {
      const rest = text.slice(pos + 1);
      const nl = /^\s*\|/.test(rest);
      if (!nl) break;
    }
    out += c; pos++;
  }
  return out.replace(/\s+/g, " ").trim();
}
const start = text.indexOf("export type Database = {");
pos = text.indexOf("{", start);
const db = parseBlock();
const pub = db.public.val;

const nullable = (t) => /\|\s*null\s*$/.test(t) || /^null\s*\|/.test(t);
const enumRef = (t) => { const m = /Enums"\]\["(\w+)"\]/.exec(t); return m ? m[1] : null; };
const stripNull = (t) => t.replace(/\s*\|\s*null\s*$/, "").replace(/^null\s*\|\s*/, "");

const enums = {};
for (const [name, { val }] of Object.entries(pub.Enums.val)) {
  enums[name] = [...val.matchAll(/"([^"]+)"/g)].map((m) => m[1]);
}
function tableFrom(name, def) {
  const row = def.Row.val, ins = def.Insert?.val ?? {};
  const columns = Object.entries(row).map(([col, { val }]) => ({
    name: col,
    tsType: stripNull(val),
    enum: enumRef(val),
    nullable: nullable(val),
    hasDefault: ins[col]?.optional ?? true,
  }));
  const fks = (def.Relationships?.val ?? []).map((r) => ({
    name: JSON.parse(r.foreignKeyName.val),
    columns: r.columns.val.map((s) => JSON.parse(s)),
    references: JSON.parse(r.referencedRelation.val),
    referencedColumns: r.referencedColumns.val.map((s) => JSON.parse(s)),
    oneToOne: r.isOneToOne.val === "true",
  }));
  return { name, columns, fks };
}
const tables = Object.entries(pub.Tables.val).map(([n, d]) => tableFrom(n, d.val));
const views = Object.entries(pub.Views.val).map(([n, d]) => tableFrom(n, d.val));
const functions = Object.entries(pub.Functions.val).map(([n, d]) => ({
  name: n,
  args: typeof d.val.Args.val === "object" ? Object.fromEntries(Object.entries(d.val.Args.val).map(([k, v]) => [k + (v.optional ? "?" : ""), v.val])) : d.val.Args.val,
  returns: typeof d.val.Returns.val === "object" ? Object.fromEntries(Object.entries(d.val.Returns.val).map(([k, v]) => [k, v.val])) : d.val.Returns.val,
  returnsSet: d.val.Returns.isArray === true,
}));

// ---------- what the migrations define ----------
const migFiles = readdirSync(migDir).filter((f) => f.endsWith(".sql")).sort();
const migSql = migFiles.map((f) => readFileSync(resolve(migDir, f), "utf8")).join("\n");
const grab = (re) => new Set([...migSql.matchAll(re)].map((m) => m[1].toLowerCase()));
const migTables = grab(/create\s+table\s+(?:if\s+not\s+exists\s+)?(?:public\.)?"?(\w+)"?/gi);
const migFunctions = grab(/create\s+(?:or\s+replace\s+)?function\s+(?:public\.)?"?(\w+)"?\s*\(/gi);
const migTriggers = grab(/create\s+(?:or\s+replace\s+)?trigger\s+"?(\w+)"?/gi);
const migEnums = grab(/create\s+type\s+(?:public\.)?"?(\w+)"?\s+as\s+enum/gi);
const migViews = grab(/create\s+(?:or\s+replace\s+)?view\s+(?:public\.)?"?(\w+)"?/gi);
const migAddCols = {};
for (const m of migSql.matchAll(/alter\s+table\s+(?:public\.)?"?(\w+)"?\s+add\s+column\s+(?:if\s+not\s+exists\s+)?"?(\w+)"?/gi)) {
  (migAddCols[m[1].toLowerCase()] ??= new Set()).add(m[2].toLowerCase());
}
// columns declared inside CREATE TABLE bodies
const migCols = {};
for (const m of migSql.matchAll(/create\s+table\s+(?:if\s+not\s+exists\s+)?(?:public\.)?"?(\w+)"?\s*\(([\s\S]*?)\);/gi)) {
  const cols = new Set();
  for (const line of m[2].split(/,\s*\n/)) {
    const cm = /^\s*"?([a-z_]\w*)"?\s+/i.exec(line);
    if (cm && !/^(constraint|primary|unique|foreign|check)$/i.test(cm[1])) cols.add(cm[1].toLowerCase());
  }
  migCols[m[1].toLowerCase()] = cols;
}

const inventory = {
  generatedAt: new Date().toISOString(),
  source: { typesFile: typesPath, migrations: migFiles },
  enums,
  tables: tables.map((t) => ({
    ...t,
    inMigrations: migTables.has(t.name),
    columnsMissingFromMigrations: migTables.has(t.name)
      ? t.columns.filter((c) => !(migCols[t.name]?.has(c.name) || migAddCols[t.name]?.has(c.name))).map((c) => c.name)
      : t.columns.map((c) => c.name),
  })),
  views: views.map((v) => ({ ...v, inMigrations: migViews.has(v.name) })),
  functions: functions.map((f) => ({ ...f, inMigrations: migFunctions.has(f.name) })),
  migrationOnly: {
    triggers: [...migTriggers].sort(),
    functionsNotInTypes: [...migFunctions].filter((f) => !functions.some((x) => x.name === f)).sort(),
  },
};
writeFileSync(resolve(here, "../docs/schema-inventory.json"), JSON.stringify(inventory, null, 2));

// ---------- markdown summary ----------
const md = [];
md.push("# Schema inventory (from types.ts, cross-checked with supabase/migrations)\n");
md.push(`Generated ${inventory.generatedAt}. Tables: ${tables.length}, views: ${views.length}, functions: ${functions.length}, enums: ${Object.keys(enums).length}.\n`);
md.push("## Enums\n");
for (const [n, v] of Object.entries(enums)) md.push(`- \`${n}\`: ${v.map((x) => "`" + x + "`").join(", ")}${migEnums.has(n) ? "" : "  **(not in migrations)**"}`);
md.push("\n## Tables\n");
md.push("| Table | Cols | FKs | In migrations | Columns missing from migrations |\n|---|---|---|---|---|");
for (const t of inventory.tables) md.push(`| \`${t.name}\` | ${t.columns.length} | ${t.fks.map((f) => f.references).join(", ") || "—"} | ${t.inMigrations ? "yes" : "**no**"} | ${t.columnsMissingFromMigrations.join(", ") || "—"} |`);
md.push("\n## Views\n");
for (const v of inventory.views) md.push(`- \`${v.name}\` (${v.columns.length} cols)${v.inMigrations ? "" : "  **(not in migrations)**"}`);
md.push("\n## Functions\n");
md.push("| Function | Args | Returns | Body in migrations |\n|---|---|---|---|");
for (const f of inventory.functions) md.push(`| \`${f.name}\` | ${typeof f.args === "object" ? Object.keys(f.args).join(", ") : f.args} | ${typeof f.returns === "object" ? "record(" + Object.keys(f.returns).join(", ") + ")" : f.returns} | ${f.inMigrations ? "yes" : "**no**"} |`);
md.push("\n## Triggers defined in migrations\n");
for (const t of inventory.migrationOnly.triggers) md.push(`- \`${t}\``);
md.push("\n## Column details\n");
for (const t of inventory.tables) {
  md.push(`### ${t.name}\n`);
  md.push("| column | type | enum | null | default |\n|---|---|---|---|---|");
  for (const c of t.columns) md.push(`| ${c.name} | ${c.tsType.replace(/\|/g, "\\|")} | ${c.enum ?? ""} | ${c.nullable ? "yes" : ""} | ${c.hasDefault ? "yes" : ""} |`);
  if (t.fks.length) md.push("\nFKs: " + t.fks.map((f) => `${f.columns.join(",")} → ${f.references}(${f.referencedColumns.join(",")})`).join("; "));
  md.push("");
}
writeFileSync(resolve(here, "../docs/schema-inventory.md"), md.join("\n"));

const missingTables = inventory.tables.filter((t) => !t.inMigrations).map((t) => t.name);
const missingFns = inventory.functions.filter((f) => !f.inMigrations).map((f) => f.name);
console.log(`tables ${tables.length} (missing from migrations: ${missingTables.length}), views ${views.length}, functions ${functions.length} (missing: ${missingFns.length}), enums ${Object.keys(enums).length}`);
console.log("missing tables:", missingTables.join(", "));
console.log("missing functions:", missingFns.join(", "));
