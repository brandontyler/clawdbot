/**
 * Post-build verification: ensures every compiled extension has its
 * dist-runtime overlay (index.js). Catches incomplete builds before
 * runtime startup discovers them.
 *
 * Kiro-only file — not present upstream.
 */

import fs from "node:fs";
import path from "node:path";

const repoRoot = process.cwd();
const distExtensions = path.join(repoRoot, "dist", "extensions");
const runtimeExtensions = path.join(repoRoot, "dist-runtime", "extensions");

if (!fs.existsSync(distExtensions)) {
  console.error("✗ dist/extensions/ does not exist — build may not have run.");
  process.exit(1);
}

const compiled = fs
  .readdirSync(distExtensions, { withFileTypes: true })
  .filter(
    (d) =>
      d.isDirectory() &&
      fs.existsSync(path.join(distExtensions, d.name, "package.json")) &&
      fs.existsSync(path.join(distExtensions, d.name, "index.js")),
  )
  .map((d) => d.name);

const missing = compiled.filter(
  (id) => !fs.existsSync(path.join(runtimeExtensions, id, "index.js")),
);

if (missing.length > 0) {
  console.error(`✗ ${missing.length} extension(s) missing dist-runtime artifacts:`);
  for (const id of missing) {
    console.error(`  - ${id}`);
  }
  console.error("\nRun: pnpm install && pnpm build");
  process.exit(1);
}

console.log(`✓ All ${compiled.length} extensions have runtime artifacts.`);
