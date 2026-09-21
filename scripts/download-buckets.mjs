#!/usr/bin/env node
// Phase 0: download every object from the Supabase storage buckets into dump/files/<bucket>/<key>.
// Needs SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY (from the connected project's API settings).
import { mkdirSync, writeFileSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const URL_ = process.env.SUPABASE_URL, KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!URL_ || !KEY) { console.error("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY"); process.exit(1); }
const BUCKETS = (process.env.BUCKETS ?? "products-library,custom-requests").split(",");
const headers = { apikey: KEY, Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" };

async function list(bucket, prefix = "") {
  const out = [];
  for (let offset = 0; ; offset += 1000) {
    const r = await fetch(`${URL_}/storage/v1/object/list/${bucket}`, {
      method: "POST", headers,
      body: JSON.stringify({ prefix, limit: 1000, offset, sortBy: { column: "name", order: "asc" } }),
    });
    if (!r.ok) throw new Error(`list ${bucket}/${prefix}: ${r.status} ${await r.text()}`);
    const items = await r.json();
    for (const it of items) {
      const key = prefix ? `${prefix}/${it.name}` : it.name;
      if (it.id === null) out.push(...(await list(bucket, key))); // folder
      else out.push(key);
    }
    if (items.length < 1000) break;
  }
  return out;
}
let total = 0, skipped = 0;
for (const bucket of BUCKETS) {
  const keys = await list(bucket);
  console.log(`${bucket}: ${keys.length} objects`);
  let i = 0;
  const workers = Array.from({ length: 5 }, async () => {
    while (i < keys.length) {
      const key = keys[i++];
      const dest = resolve(here, "../dump/files", bucket, key);
      if (existsSync(dest)) { skipped++; continue; }
      for (let attempt = 1; attempt <= 3; attempt++) {
        const r = await fetch(`${URL_}/storage/v1/object/${bucket}/${encodeURI(key)}`, { headers });
        if (r.ok) { mkdirSync(dirname(dest), { recursive: true }); writeFileSync(dest, Buffer.from(await r.arrayBuffer())); total++; break; }
        if (attempt === 3) console.error(`FAILED ${bucket}/${key}: ${r.status}`);
      }
    }
  });
  await Promise.all(workers);
}
console.log(`downloaded ${total}, skipped existing ${skipped}`);
