// Stands in for core during a local runtime test: accepts /internal/v1/* and appends
// every RunEvent to /tmp/vibe-e2e-events.ndjson.
const http = require("http");
const fs = require("fs");

const OUT = process.env.SINK_OUT || "/tmp/vibe-e2e-events.ndjson";
fs.writeFileSync(OUT, "");

http
  .createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      try {
        const parsed = JSON.parse(body || "{}");
        for (const ev of parsed.events || [parsed]) fs.appendFileSync(OUT, JSON.stringify(ev) + "\n");
      } catch {
        fs.appendFileSync(OUT, JSON.stringify({ raw: body.slice(0, 2000) }) + "\n");
      }
      res.writeHead(200, { "content-type": "application/json" });
      res.end('{"ok":true}');
    });
  })
  .listen(Number(process.env.SINK_PORT || 4999), "127.0.0.1", () =>
    console.log("sink on 4999 ->", OUT)
  );
