/**
 * In-memory store for scan results.
 * In production, swap this for PostgreSQL / MongoDB.
 */

const { v4: uuidv4 } = require('uuid');

const store = {
  agents: {},  // id -> agent record (keyed by stable id, deduped by hostname)
  scans: [],   // Array of scan results, newest first
};

// Agent registry
// Deduplicates by hostname so the same machine never appears twice,
// even when the agent restarts without a cached agentId.
function upsertAgent(info) {
  const hostname = info.hostname || 'unknown';

  // Find existing entry for this hostname
  const existing = Object.values(store.agents).find(a => a.hostname === hostname);
  const id = existing ? existing.id : (info.agentId || uuidv4());

  store.agents[id] = {
    id,
    hostname,
    os: info.os || 'unknown',
    version: info.agentVersion || '1.0.0',
    lastSeen: new Date().toISOString(),
    scanCount: (existing ? existing.scanCount : 0) + 1,
  };
  return id;
}

function getAgents() {
  return Object.values(store.agents);
}

// Scan storage — upsert by (agentId + scanType + target)
// If the same agent scans the same target again, overwrite the existing record
// in-place so counts never double-up. A new record is only created when the
// combination is genuinely new.
function saveScan(scan) {
  const now = new Date().toISOString();

  // Build the dedup key: stable identity of "who scanned what"
  const dedupKey = `${scan.agentId}::${scan.scanType}::${scan.target}`;

  const existingIdx = store.scans.findIndex(s => s._dedupKey === dedupKey);

  if (existingIdx !== -1) {
    // Overwrite in-place — keep the original scan ID so existing UI references
    // still work, but refresh every data field and move it to the top (newest)
    const existing = store.scans[existingIdx];
    const updated = {
      ...existing,
      ...scan,
      _dedupKey: dedupKey,
      _overwritten: true,
      receivedAt: now,
      firstSeenAt: existing.firstSeenAt || existing.receivedAt,
    };
    store.scans.splice(existingIdx, 1); // remove old position
    store.scans.unshift(updated);       // put at top (newest)
    console.log(`[DB] Overwrote existing scan for ${scan.target} (agent ${scan.agentId?.slice(0,8)})`);
    return updated;
  }

  // Brand-new combination — insert
  const record = {
    id: uuidv4(),
    _dedupKey: dedupKey,
    receivedAt: now,
    firstSeenAt: now,
    ...scan,
  };
  store.scans.unshift(record);
  if (store.scans.length > 500) store.scans.length = 500;
  return record;
}

function getScans(filters = {}) {
  let results = [...store.scans];
  if (filters.agentId)  results = results.filter(s => s.agentId === filters.agentId);
  if (filters.type)     results = results.filter(s => s.scanType === filters.type);
  if (filters.target)   results = results.filter(s => s.target?.includes(filters.target));
  return results;
}

function getScanById(id) {
  return store.scans.find(s => s.id === id);
}

// Aggregated dashboard stats
function getDashboardStats() {
  const scans = store.scans;
  const agents = getAgents();

  let totalCritical = 0, totalHigh = 0, totalMedium = 0, totalLow = 0;
  let totalSecrets = 0, totalMisconfigs = 0, totalVulns = 0;

  const recentActivity = [];
  const targetMap = {};

  for (const scan of scans) {
    const s = scan.summary || {};
    totalCritical   += s.criticalCount   || 0;
    totalHigh       += s.highCount       || 0;
    totalMedium     += s.mediumCount     || 0;
    totalLow        += s.lowCount        || 0;
    totalSecrets    += s.secretCount     || 0;
    totalMisconfigs += s.misconfigCount  || 0;
    totalVulns      += s.vulnCount       || 0;

    if (recentActivity.length < 20) {
      recentActivity.push({
        id: scan.id,
        agentId: scan.agentId,
        hostname: store.agents[scan.agentId]?.hostname || scan.agentId,
        scanType: scan.scanType,
        target: scan.target,
        receivedAt: scan.receivedAt,
        critical: s.criticalCount || 0,
        high: s.highCount || 0,
      });
    }

    const key = scan.target;
    if (!targetMap[key]) targetMap[key] = { target: key, scanType: scan.scanType, totalFindings: 0, scans: 0 };
    targetMap[key].totalFindings += (s.criticalCount || 0) + (s.highCount || 0) + (s.mediumCount || 0);
    targetMap[key].scans += 1;
  }

  const topTargets = Object.values(targetMap)
    .sort((a, b) => b.totalFindings - a.totalFindings)
    .slice(0, 10);

  const dayMap = {};
  for (const scan of scans) {
    const day = scan.receivedAt?.slice(0, 10);
    if (!day) continue;
    if (!dayMap[day]) dayMap[day] = { date: day, critical: 0, high: 0, medium: 0, low: 0 };
    const s = scan.summary || {};
    dayMap[day].critical += s.criticalCount || 0;
    dayMap[day].high     += s.highCount     || 0;
    dayMap[day].medium   += s.mediumCount   || 0;
    dayMap[day].low      += s.lowCount      || 0;
  }
  const severityTrend = Object.values(dayMap).sort((a, b) => a.date.localeCompare(b.date)).slice(-14);

  return {
    overview: {
      totalScans: scans.length,
      activeAgents: agents.length,
      totalCritical,
      totalHigh,
      totalMedium,
      totalLow,
      totalSecrets,
      totalMisconfigs,
      totalVulns,
    },
    agents,
    recentActivity,
    topTargets,
    severityTrend,
  };
}

module.exports = { upsertAgent, getAgents, saveScan, getScans, getScanById, getDashboardStats };
