#!/usr/bin/env node
// Local PostgreSQL 17 for the migration work, no root and no docker required.
//   node pg.mjs start   -> initdb (first time) + start on 127.0.0.1:55432, user wasl / password wasl
//   node pg.mjs stop
//   node pg.mjs reset   -> stop, wipe data dir, start fresh
// Connection string: postgres://wasl:wasl@127.0.0.1:55432/postgres
import EmbeddedPostgres from "embedded-postgres";
import { existsSync, rmSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const dataDir = resolve(here, "../.pgdata");
const port = Number(process.env.PGPORT ?? 55432);
const pg = new EmbeddedPostgres({
  databaseDir: dataDir,
  user: "wasl",
  password: "wasl",
  port,
  persistent: true,
  initdbFlags: ["--encoding=UTF8", "--locale=C.UTF-8"],
});
const cmd = process.argv[2] ?? "start";
if (cmd === "stop" || cmd === "reset") {
  try { await pg.stop(); console.log("stopped"); } catch (e) { console.log("stop:", e.message); }
  if (cmd === "reset") { rmSync(dataDir, { recursive: true, force: true }); console.log("data dir removed"); }
}
if (cmd === "start" || cmd === "reset") {
  if (!existsSync(dataDir)) { await pg.initialise(); console.log("initialised", dataDir); }
  await pg.start();
  console.log(`postgres 17 listening on 127.0.0.1:${port}  (postgres://wasl:wasl@127.0.0.1:${port}/postgres)`);
}
