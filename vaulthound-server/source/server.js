/**
 * TrivyWatch Master Server
 * Receives scan results from agents and serves the dashboard API.
 *
 * Usage:
 *   node server.js
 *   PORT=4000 node server.js
 */

const express = require('express');
const cors = require('cors');
const bodyParser = require('body-parser');
const path = require('path');
const routes = require('./routes');

const app = express();
const PORT = process.env.PORT || 4000;

// ── Middleware ──────────────────────────────────────────────────────────────
app.use(cors());
app.use(bodyParser.json({ limit: '50mb' }));
app.use(bodyParser.urlencoded({ extended: true, limit: '50mb' }));

app.use((req, _res, next) => {
  console.log(`[${new Date().toISOString()}] ${req.method} ${req.url}`);
  next();
});

// ── API ─────────────────────────────────────────────────────────────────────
app.use('/api', routes);

// ── Static dashboard ────────────────────────────────────────────────────────
// Serves the plain HTML dashboard - no build step required.
const dashboardDir = path.join(__dirname, '../dashboard');
app.use(express.static(dashboardDir));
app.get(/^\/(?!api).*/, (_req, res) => {
  res.sendFile(path.join(dashboardDir, 'index.html'));
});

// ── Start ───────────────────────────────────────────────────────────────────
app.listen(PORT, '0.0.0.0', () => {
  console.log(`
╔══════════════════════════════════════════════════╗
║          🛡️  TrivyWatch Master Server             ║
╠══════════════════════════════════════════════════╣
║  Dashboard  : http://localhost:${PORT}              ║
║  Agent API  : POST /api/ingest                   ║
║  Stats API  : GET  /api/dashboard                ║
║  Scans API  : GET  /api/scans                    ║
╚══════════════════════════════════════════════════╝
`);
});
