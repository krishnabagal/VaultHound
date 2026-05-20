/**
 * VaultHound Master — API Routes (token-authenticated)
 * Drop this file into /opt/vaulthound/master/routes.js
 */

const express        = require('express');
const router         = express.Router();
const db             = require('./db');
const { requireToken } = require('./auth');
const cfg            = require('./config');

// ── Health check (public) ─────────────────────────────────────────────────────
router.get('/health', (_req, res) => {
  res.json({ status: 'ok', service: 'vaulthound-master', ts: new Date().toISOString() });
});

// ── Agent ingestion (token protected) ────────────────────────────────────────
router.post('/ingest', requireToken, (req, res) => {
  try {
    const { agent, scanType, target, trivyReport, summary, metadata } = req.body;
    if (!agent || !scanType || !target) {
      return res.status(400).json({ error: 'Missing required fields: agent, scanType, target' });
    }
    const agentId = db.upsertAgent(agent);
    const scan    = db.saveScan({ agentId, scanType, target, trivyReport, summary, metadata,
                                  scannedAt: metadata?.scannedAt || new Date().toISOString() });
    console.log(`[INGEST] agent=${agent.hostname} type=${scanType} target=${target}` +
                ` crit=${summary?.criticalCount||0} ${scan._overwritten?'(overwrite)':'(new)'}`);
    res.json({ ok: true, scanId: scan.id, agentId, overwritten: !!scan._overwritten });
  } catch (err) {
    console.error('[INGEST ERROR]', err);
    res.status(500).json({ error: err.message });
  }
});

// ── Dashboard (public — served from same host) ────────────────────────────────
router.get('/dashboard', (_req, res) => res.json(db.getDashboardStats()));
router.get('/scans',     (req, res) => { const s = db.getScans(req.query); res.json({ total: s.length, scans: s }); });
router.get('/scans/:id', (req, res)  => {
  const s = db.getScanById(req.params.id);
  if (!s) return res.status(404).json({ error: 'Not found' });
  res.json(s);
});
router.get('/agents',    (_req, res) => res.json(db.getAgents()));

module.exports = router;
