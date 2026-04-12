#!/usr/bin/env node
// scrape-tcfp.mjs — Scrape TCFP fire service careers via CDP
// Requires dev-browser (headless Chrome) on port 9223
// Output: JSON array of { title, url, salary, city, department, type } to stdout

import http from "node:http";
import { WebSocket } from "ws";

const CDP_PORT = 9223;
const NORTH_TX =
  /denton|corinth|lake dallas|sanger|aubrey|pilot point|argyle|lewisville|flower mound|highland village|the colony|little elm|frisco|mckinney|allen|plano|prosper|celina|anna|carrollton|coppell|grapevine|southlake|keller|roanoke|fort worth|arlington|dallas|irving|grand prairie|mansfield|trophy club|crossroads|hurst|euless|bedford|north richland|richland hills|watauga|colleyville|westlake|haslet|justin|ponder|northlake|lantana|bartonville|copper canyon|hickory creek|corral city|krugerville|oak point|paloma creek|providence|savannah|dfw|farmers branch|addison|richardson|garland|mesquite|rowlett|rockwall|wylie|sachse|murphy|lucas|fairview|princeton|waxahachie|midlothian|cedar hill|desoto|duncanville|lancaster|kennedale|weatherford|azle|decatur|bridgeport|bowie|gainesville|sherman|denison|bonham|paris/i;

const getJson = (url) =>
  new Promise((res, rej) =>
    http
      .get(url, (r) => {
        let d = "";
        r.on("data", (c) => (d += c));
        r.on("end", () => {
          try {
            res(JSON.parse(d));
          } catch {
            res(d);
          }
        });
      })
      .on("error", rej),
  );

async function main() {
  // Find an available blank tab or use the first available
  const tabs = await getJson(`http://localhost:${CDP_PORT}/json/list`);
  const tab = tabs.find((t) => t.url === "about:blank") || tabs[0];
  if (!tab?.webSocketDebuggerUrl) {
    console.error("No available tab");
    process.exit(1);
  }

  const ws = new WebSocket(tab.webSocketDebuggerUrl);
  let id = 1;
  const send = (method, params = {}) =>
    new Promise((r) => {
      const mid = id++;
      const h = (raw) => {
        const m = JSON.parse(raw.toString());
        if (m.id === mid) {
          ws.off("message", h);
          r(m);
        }
      };
      ws.on("message", h);
      ws.send(JSON.stringify({ id: mid, method, params }));
    });

  await new Promise((r) => ws.on("open", r));
  await send("Page.enable");

  // Navigate to TCFP careers page (has disclaimer gate)
  await send("Page.navigate", { url: "https://www.tcfp.texas.gov/fireservice-careers" });
  await new Promise((r) => setTimeout(r, 5000));

  // Accept disclaimer
  await send("Runtime.evaluate", {
    expression: `
      const cb = document.querySelector('input[type=checkbox]');
      if (cb) { cb.checked = true; cb.click(); }
      const form = document.querySelector('form[action*=accept]');
      if (form) form.submit();
    `,
  });
  await new Promise((r) => setTimeout(r, 5000));

  // Extract job table data
  const resp = await send("Runtime.evaluate", {
    expression: `
      const rows = [];
      document.querySelectorAll('table tr, .job-row, [class*=job]').forEach(tr => {
        const cells = tr.querySelectorAll('td');
        if (cells.length >= 4) {
          const link = tr.querySelector('a[href]');
          rows.push({
            city: cells[0]?.innerText?.trim() || '',
            department: cells[1]?.innerText?.trim() || '',
            position: cells[2]?.innerText?.trim() || '',
            type: cells[3]?.innerText?.trim() || '',
            salary: cells[4]?.innerText?.trim() || '',
            url: link?.href || '',
          });
        }
      });
      // Fallback: parse from innerText if no table
      if (rows.length === 0) {
        const text = document.body.innerText;
        const lines = text.split('\\n');
        for (const line of lines) {
          const parts = line.split('\\t');
          if (parts.length >= 4) {
            rows.push({
              city: parts[0]?.trim() || '',
              department: parts[1]?.trim() || '',
              position: parts[2]?.trim() || '',
              type: parts[3]?.trim() || '',
              salary: parts[4]?.trim() || '',
              url: '',
            });
          }
        }
      }
      JSON.stringify(rows);
    `,
    returnByValue: true,
  });

  const raw = resp?.result?.result?.value || "[]";
  const jobs = JSON.parse(raw);

  // Filter to North TX
  const filtered = jobs
    .filter((j) => NORTH_TX.test(j.city) || NORTH_TX.test(j.department))
    .map((j) => ({
      title: j.position + " — " + j.department + " (" + j.city + ", TX)",
      url: j.url || "https://www.tcfp.texas.gov/fireservice-careers",
      salary: j.salary,
      city: j.city,
      department: j.department,
      type: j.type,
    }));

  console.log(JSON.stringify(filtered, null, 2));

  await send("Page.navigate", { url: "about:blank" });
  ws.close();
  process.exit(0);
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
