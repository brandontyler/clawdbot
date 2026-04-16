#!/usr/bin/env node
// scrape-neogov.mjs — Scrape governmentjobs.com city pages via CDP
// Requires dev-browser (headless Chrome) on port 9223
//
// Usage: node scrape-neogov.mjs [slug1 slug2 ...]
// Output: JSON array of { title, url, meta, city } to stdout

import http from "node:http";
import { WebSocket } from "ws";

const CDP_PORT = 9223;
const RENDER_WAIT_MS = 7000;
const FIRE_KEYWORDS =
  /firefight|fire\s*(fighter|chief|inspector|marshal|captain|engineer|cadet|recruit)|paramedic|ems\b/i;

// Verified North TX NEOGOV slugs (centered on Denton, ~100mi radius)
// 58 cities/counties covering DFW metroplex + outer ring
const DEFAULT_SLUGS = [
  // Denton County core
  "dentontx",
  "denton",
  "dentoncounty",
  "highlandvillage",
  "lewisville",
  "flowermoundtx",
  "aubreytx",
  "sanger",
  "argyle",
  "crossroads",
  "prospertx",
  "trophyclub",
  "roanoke",
  // Collin County
  "frisco",
  "cityofmckinney",
  "allen",
  "princeton",
  "sachsetx",
  "murphytx",
  // Dallas County
  "dallas",
  "garland",
  "mesquitetx",
  "cityofmesquite",
  "cityofirving",
  "farmersbranch",
  "addisontx",
  "highlandpark",
  "desototx",
  "lancastertx",
  "cedarhill",
  "glennheights",
  "rowlett",
  "lakeworth",
  // Tarrant County
  "fortworth",
  "arlington",
  "arlingtontx",
  "grandprairietx",
  "mansfieldtx",
  "colleyville",
  "grapevinetx",
  "coppell",
  "haltomcity",
  "wataugatx",
  "joshuatx",
  // Rockwall / Kaufman / East
  "rockwalltx",
  "forneytx",
  // Ellis / Johnson / South
  "waxahachie",
  "midlothiantx",
  "ennistx",
  "redoak",
  // Parker / Wise / West
  "weatherford",
  // Grayson / Cooke / North
  "shermantx",
  "denisontx",
  "gainesvilletx",
  // Outer ring (~75-100mi)
  "wacotx",
  "templetx",
  "longviewtx",
  "texarkanatx",
  "thecolonytx",
];

function httpReq(method, path) {
  return new Promise((resolve, reject) => {
    const req = http.request({ hostname: "127.0.0.1", port: CDP_PORT, path, method }, (res) => {
      let d = "";
      res.on("data", (c) => (d += c));
      res.on("end", () => {
        try {
          resolve(JSON.parse(d));
        } catch {
          resolve(d);
        }
      });
    });
    req.on("error", reject);
    req.end();
  });
}

async function scrapeCity(slug) {
  const url = `https://www.governmentjobs.com/careers/${slug}`;
  let tab;
  try {
    tab = await httpReq("PUT", "/json/new?url=about:blank");
    if (!tab?.webSocketDebuggerUrl) {
      throw new Error("No WS URL");
    }
  } catch (e) {
    process.stderr.write(`[${slug}] Tab create failed: ${e.message}\n`);
    return [];
  }

  let ws;
  try {
    ws = new WebSocket(tab.webSocketDebuggerUrl);
    await new Promise((res, rej) => {
      ws.on("open", res);
      ws.on("error", rej);
      setTimeout(() => rej(new Error("WS connect timeout")), 5000);
    });
  } catch (e) {
    process.stderr.write(`[${slug}] WS failed: ${e.message}\n`);
    httpReq("PUT", `/json/close/${tab.id}`).catch(() => {});
    return [];
  }

  let msgId = 1;
  const send = (method, params = {}) =>
    new Promise((resolve, reject) => {
      const id = msgId++;
      const timeout = setTimeout(() => {
        ws.off("message", handler);
        reject(new Error("CDP timeout"));
      }, 15000);
      const handler = (raw) => {
        const msg = JSON.parse(raw);
        if (msg.id === id) {
          clearTimeout(timeout);
          ws.off("message", handler);
          resolve(msg.result);
        }
      };
      ws.on("message", handler);
      ws.send(JSON.stringify({ id, method, params }));
    });

  let jobs = [];
  try {
    await send("Page.enable");
    await send("Page.navigate", { url });
    await new Promise((r) => setTimeout(r, RENDER_WAIT_MS));

    // Dismiss cookie consent if present
    await send("Runtime.evaluate", {
      expression: `document.querySelector('[class*="osano-cm-accept"]')?.click()`,
      returnByValue: true,
    });
    // Small extra wait after cookie dismiss for any re-render
    await new Promise((r) => setTimeout(r, 1000));

    const result = await send("Runtime.evaluate", {
      expression: `JSON.stringify(
        Array.from(document.querySelectorAll('.list-item')).map(el => ({
          title: (el.querySelector('.item-details-link')?.textContent || '').trim(),
          url: el.querySelector('.item-details-link')?.href || '',
          meta: (el.querySelector('.list-meta')?.textContent || '').trim().replace(/\\s+/g, ' '),
        }))
      )`,
      returnByValue: true,
    });

    const parsed = JSON.parse(result?.result?.value || "[]");
    jobs = parsed
      .filter((j) => j.title && FIRE_KEYWORDS.test(j.title + " " + j.meta))
      .map((j) => ({ ...j, city: slug }));
  } catch (e) {
    process.stderr.write(`[${slug}] Scrape error: ${e.message}\n`);
  }

  ws.close();
  httpReq("PUT", `/json/close/${tab.id}`).catch(() => {});
  return jobs;
}

async function main() {
  const slugs = process.argv.length > 2 ? process.argv.slice(2) : DEFAULT_SLUGS;
  const allJobs = [];

  for (const slug of slugs) {
    process.stderr.write(`[${slug}] scraping...`);
    const jobs = await scrapeCity(slug);
    process.stderr.write(` ${jobs.length} fire job(s)\n`);
    // Stream results immediately so partial output survives timeouts
    for (const job of jobs) {
      console.log(JSON.stringify(job));
    }
    allJobs.push(...jobs);
    if (slugs.indexOf(slug) < slugs.length - 1) {
      await new Promise((r) => setTimeout(r, 800));
    }
  }

  process.stderr.write(`[done] ${allJobs.length} total fire jobs from ${slugs.length} cities\n`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
