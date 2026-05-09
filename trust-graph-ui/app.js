let graphData = null;
let selectedNode = null;
let selectedEdge = null;
let highlightedEventIds = new Set();

const nodeColors = {
  user: { stroke: "#58a6ff", fill: "#0c2d6b" },
  agent: { stroke: "#7ee787", fill: "#0f3518" },
  "resource-server": { stroke: "#f0883e", fill: "#3d2004" },
};

const edgeColors = {
  authenticated: "#7ee787",
  denied: "#f85149",
  unauthenticated: "#f0883e",
};

const NODE_W = 130;
const NODE_H = 40;

function computeLayout(nodes, edges) {
  const adj = {};
  const inDeg = {};
  nodes.forEach(n => { adj[n.id] = []; inDeg[n.id] = 0; });
  edges.forEach(e => {
    if (adj[e.source]) adj[e.source].push(e.target);
    inDeg[e.target] = (inDeg[e.target] || 0) + 1;
  });

  const layers = {};
  const assigned = new Set();

  nodes.filter(n => n.type === "user").forEach(n => { layers[n.id] = 0; assigned.add(n.id); });

  let changed = true;
  while (changed) {
    changed = false;
    edges.forEach(e => {
      if (layers[e.source] !== undefined && layers[e.target] === undefined) {
        layers[e.target] = layers[e.source] + 1;
        assigned.add(e.target);
        changed = true;
      }
    });
  }

  nodes.forEach(n => {
    if (layers[n.id] === undefined) {
      if (n.type === "resource-server") layers[n.id] = 3;
      else layers[n.id] = 1;
      assigned.add(n.id);
    }
  });

  const layerGroups = {};
  nodes.forEach(n => {
    const l = layers[n.id];
    if (!layerGroups[l]) layerGroups[l] = [];
    layerGroups[l].push(n);
  });

  const maxLayer = Math.max(...Object.keys(layerGroups).map(Number));
  const svgEl = document.getElementById("graph");
  const pane = document.getElementById("graph-pane");
  const W = pane.clientWidth;
  const H = pane.clientHeight;

  const xPad = 80;
  const layerSpacing = maxLayer > 0 ? (W - 2 * xPad - NODE_W) / maxLayer : 0;

  const positions = {};
  Object.keys(layerGroups).forEach(l => {
    const group = layerGroups[l];
    const li = Number(l);
    const x = xPad + li * layerSpacing;
    const totalH = group.length * NODE_H + (group.length - 1) * 40;
    const startY = (H - totalH) / 2;
    group.forEach((n, i) => {
      positions[n.id] = { x: x + NODE_W / 2, y: startY + i * (NODE_H + 40) + NODE_H / 2 };
    });
  });

  return positions;
}

function dedupeEdges(edges) {
  const seen = new Set();
  return edges.filter(e => {
    const k = `${e.source}-${e.target}-${e.status}`;
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });
}

function renderGraph() {
  if (!graphData) return;

  const { nodes, edges } = graphData;
  const uniqueEdges = dedupeEdges(edges);
  const positions = computeLayout(nodes, uniqueEdges);

  const svg = d3.select("#graph");
  svg.selectAll("*").remove();

  const pane = document.getElementById("graph-pane");
  const W = pane.clientWidth;
  const H = pane.clientHeight;
  svg.attr("viewBox", [0, 0, W, H]);

  svg.append("defs").selectAll("marker")
    .data(["authenticated", "denied", "unauthenticated"])
    .join("marker")
    .attr("id", d => `arrow-${d}`)
    .attr("viewBox", "0 -5 10 10")
    .attr("refX", 10)
    .attr("refY", 0)
    .attr("markerWidth", 7)
    .attr("markerHeight", 7)
    .attr("orient", "auto")
    .append("path")
    .attr("fill", d => edgeColors[d])
    .attr("d", "M0,-4L10,0L0,4");

  const edgeGroup = svg.append("g").attr("class", "edges");
  const nodeGroup = svg.append("g").attr("class", "nodes");

  uniqueEdges.forEach((e, i) => {
    const src = positions[e.source];
    const tgt = positions[e.target];
    if (!src || !tgt) return;

    const x1 = src.x + NODE_W / 2;
    const y1 = src.y;
    const x2 = tgt.x - NODE_W / 2;
    const y2 = tgt.y;

    const color = edgeColors[e.status] || "#30363d";
    const dasharray = e.status === "denied" ? "6,3" : e.status === "unauthenticated" ? "3,5" : null;

    const isHighlighted = highlightedEventIds.size > 0 &&
      e.event_ids && e.event_ids.some(id => highlightedEventIds.has(id));
    const opacity = highlightedEventIds.size > 0 ? (isHighlighted ? 1 : 0.2) : 0.8;

    const line = edgeGroup.append("line")
      .attr("class", "edge-line")
      .attr("x1", x1).attr("y1", y1)
      .attr("x2", x2).attr("y2", y2)
      .attr("stroke", color)
      .attr("stroke-width", isHighlighted ? 4 : 2.5)
      .attr("stroke-opacity", opacity)
      .attr("marker-end", `url(#arrow-${e.status})`);

    if (dasharray) line.attr("stroke-dasharray", dasharray);

    if (selectedEdge && selectedEdge.source === e.source && selectedEdge.target === e.target) {
      line.classed("selected", true).attr("stroke-width", 4);
    }

    line.on("click", () => selectEdge(e));

    const scopes = (e.scopes_granted || []).filter(s => s === "*" || s.includes(":"));
    if (scopes.length > 0 || e.status === "unauthenticated") {
      edgeGroup.append("text")
        .attr("class", "scope-label")
        .attr("x", (x1 + x2) / 2)
        .attr("y", (y1 + y2) / 2 - 10)
        .text(e.status === "unauthenticated" ? "no token" : scopes.join(", "));
    }
  });

  nodes.forEach(n => {
    const pos = positions[n.id];
    if (!pos) return;
    const colors = nodeColors[n.type] || nodeColors.agent;

    const g = nodeGroup.append("g")
      .attr("class", "node-box")
      .attr("transform", `translate(${pos.x - NODE_W / 2}, ${pos.y - NODE_H / 2})`)
      .on("click", () => selectNode(n));

    if (selectedNode && selectedNode.id === n.id) g.classed("selected", true);

    const isHighlighted = highlightedEventIds.size === 0 || isNodeInHighlightedEdges(n.id);
    const opacity = highlightedEventIds.size > 0 ? (isHighlighted ? 1 : 0.3) : 1;

    g.append("rect")
      .attr("width", NODE_W)
      .attr("height", NODE_H)
      .attr("rx", 6)
      .attr("ry", 6)
      .attr("fill", colors.fill)
      .attr("stroke", colors.stroke)
      .attr("stroke-width", selectedNode && selectedNode.id === n.id ? 3 : 2)
      .attr("opacity", opacity);

    g.append("text")
      .attr("class", "node-label")
      .attr("x", NODE_W / 2)
      .attr("y", NODE_H / 2)
      .attr("opacity", opacity)
      .text(n.label);
  });
}

function isNodeInHighlightedEdges(nodeId) {
  if (!graphData) return false;
  return graphData.edges.some(e =>
    (e.source === nodeId || e.target === nodeId) &&
    e.event_ids && e.event_ids.some(id => highlightedEventIds.has(id))
  );
}

function selectNode(n) {
  selectedNode = n;
  selectedEdge = null;
  renderGraph();
  showDetailPanel();
  renderNodeDetail(n);
}

function selectEdge(e) {
  selectedEdge = e;
  selectedNode = null;
  renderGraph();
  showDetailPanel();
  renderEdgeDetail(e);
}

function showDetailPanel() {
  document.getElementById("detail-panel").classList.remove("hidden");
  setActiveTab("explain");
}

function hideDetailPanel() {
  document.getElementById("detail-panel").classList.add("hidden");
  selectedNode = null;
  selectedEdge = null;
  renderGraph();
}

function setActiveTab(tabName) {
  document.querySelectorAll(".tab").forEach(t => t.classList.toggle("active", t.dataset.tab === tabName));
  document.querySelectorAll(".tab-content").forEach(t => t.classList.toggle("active", t.id === `tab-${tabName}`));
}

function renderNodeDetail(n) {
  const nodeTypeMap = {};
  if (graphData) graphData.nodes.forEach(nd => { nodeTypeMap[nd.id] = nd.type; });

  document.getElementById("detail-title").textContent = n.id;

  const explainEl = document.getElementById("tab-explain");
  const explanation = graphData.explanations && graphData.explanations[n.id];
  if (explanation) {
    explainEl.innerHTML = `<div class="explain-text">${escapeHtml(explanation)}</div>`;
  } else {
    explainEl.innerHTML = `<div class="explain-text">No delegation chains lead to this node.</div>`;
  }

  const edgesEl = document.getElementById("tab-edges");
  const relatedEdges = graphData.edges.filter(e => e.source === n.id || e.target === n.id);
  if (relatedEdges.length === 0) {
    edgesEl.innerHTML = `<div style="color:#8b949e">No edges connected to this node.</div>`;
  } else {
    edgesEl.innerHTML = relatedEdges.map(e => renderEdgeCard(e)).join("");
  }

  const pathsEl = document.getElementById("tab-paths");
  const nodePaths = graphData.paths && graphData.paths[n.id];
  if (nodePaths && nodePaths.length > 0) {
    const pathTypeLabel = n.type === "resource-server" ? "RESOURCE" : "NODE";
    pathsEl.innerHTML = `
      <div class="detail-section">
        <div class="detail-section-title">${pathTypeLabel} PATHS (${nodePaths.length})</div>
        ${nodePaths.map((p, i) => renderPathChain(p, nodeTypeMap, i)).join("")}
      </div>`;
  } else {
    pathsEl.innerHTML = `<div style="color:#8b949e">No delegation paths found.</div>`;
  }

  renderAssessmentTab(n.id);
}

function renderEdgeDetail(e) {
  const nodeTypeMap = {};
  if (graphData) graphData.nodes.forEach(nd => { nodeTypeMap[nd.id] = nd.type; });

  document.getElementById("detail-title").textContent = `${e.source}  →  ${e.target}`;

  const explainEl = document.getElementById("tab-explain");
  const srcExplain = graphData.explanations && graphData.explanations[e.target];
  if (srcExplain) {
    explainEl.innerHTML = `<div class="explain-text">${escapeHtml(srcExplain)}</div>`;
  } else {
    explainEl.innerHTML = `<div class="explain-text">Edge from ${e.source} to ${e.target}.</div>`;
  }

  document.getElementById("tab-edges").innerHTML = renderEdgeCard(e);

  const pathsEl = document.getElementById("tab-paths");
  const targetPaths = graphData.paths && graphData.paths[e.target];
  if (targetPaths && targetPaths.length > 0) {
    pathsEl.innerHTML = `
      <div class="detail-section">
        <div class="detail-section-title">DELEGATION CHAINS (${targetPaths.length})</div>
        ${targetPaths.map((p, i) => renderPathChain(p, nodeTypeMap, i)).join("")}
      </div>`;
  } else {
    pathsEl.innerHTML = `<div style="color:#8b949e">No delegation paths.</div>`;
  }

  renderAssessmentTab(e.target);
}

function renderEdgeCard(e) {
  const scopes = (e.scopes_granted || []).filter(s => s === "*" || s.includes(":")).join(", ") || "none";
  const statusLabel = e.status === "authenticated" ? "authenticated"
    : e.status === "denied" ? "denied" : "unauthenticated";

  let eventIdsHtml = "";
  if (e.event_ids && e.event_ids.length > 0) {
    eventIdsHtml = `
      <div class="detail-section">
        <div class="detail-section-title">SPAN IDS (${e.event_ids.length})</div>
        ${e.event_ids.map(id => `<div class="span-id-link">${escapeHtml(id)}</div>`).join("")}
      </div>`;
  }

  return `
    <div class="detail-section">
      <div class="detail-section-title">${escapeHtml(e.source)} → ${escapeHtml(e.target)}</div>
      <div class="detail-row"><span class="label">Hop Kind</span><span class="value">${e.hop_kind || "—"}</span></div>
      <div class="detail-row"><span class="label">Call Count</span><span class="value">${e.call_count || 1} ${e.call_count === 1 ? "entry" : "entries"}</span></div>
      <div class="detail-row"><span class="label">First Seen</span><span class="value">${e.first_seen || "—"}</span></div>
      <div class="detail-row"><span class="label">Last Seen</span><span class="value">${e.last_seen || "—"}</span></div>
      <div class="detail-row"><span class="label">Status</span><span class="value">${statusLabel}</span></div>
      <div class="detail-row"><span class="label">Scopes</span><span class="value">${scopes}</span></div>
      ${e.http_status ? `<div class="detail-row"><span class="label">HTTP</span><span class="value">${e.http_status}</span></div>` : ""}
      ${e.trace_id ? `<div class="detail-row"><span class="label">Trace ID</span><span class="value" style="font-size:10px">${e.trace_id}</span></div>` : ""}
    </div>
    ${eventIdsHtml}`;
}

function renderPathChain(path, nodeTypeMap, index) {
  const items = path.map(id => {
    const t = nodeTypeMap[id] || "agent";
    const cls = t === "user" ? "user" : t === "resource-server" ? "resource" : "agent";
    return `<span class="path-node ${cls}">${escapeHtml(id)}</span>`;
  });
  return `<div class="path-chain">${items.join('<span class="path-arrow">→</span>')}</div>`;
}

function renderAssessmentTab(nodeId) {
  const el = document.getElementById("tab-assessment");
  const alignment = graphData.capability_alignment || {};
  const alignmentEntries = Object.entries(alignment);

  el.innerHTML = `
    <div class="detail-section">
      <div class="verdict-box ok">Verdict: OK — Risk Score: 0/100 — Baseline: 0&nbsp;prior&nbsp;runs</div>
    </div>
    <div class="detail-section">
      <div class="detail-section-title">CAPABILITY ALIGNMENT (${alignmentEntries.length} AGENTS)</div>
      <table class="alignment-table">
        ${alignmentEntries.map(([agent, status]) => `
          <tr>
            <td>${escapeHtml(agent)}</td>
            <td><span class="alignment-badge ${status === "ALIGNED" ? "aligned" : "misaligned"}">${status}</span></td>
          </tr>
        `).join("")}
      </table>
    </div>`;
}

function renderEventPills() {
  const container = document.getElementById("event-pills");
  container.innerHTML = "";
  if (!graphData || !graphData.event_ids) return;

  graphData.event_ids.forEach(id => {
    const pill = document.createElement("span");
    pill.className = "event-pill";
    pill.textContent = id.length > 20 ? id.substring(0, 8) + "..." + id.substring(id.length - 6) : id;
    pill.title = id;
    if (highlightedEventIds.has(id)) pill.classList.add("active");
    pill.addEventListener("click", () => {
      if (highlightedEventIds.has(id)) {
        highlightedEventIds.delete(id);
        pill.classList.remove("active");
      } else {
        highlightedEventIds.add(id);
        pill.classList.add("active");
      }
      renderGraph();
    });
    container.appendChild(pill);
  });
}

function updateTopBar() {
  if (!graphData) return;
  const runIdEl = document.getElementById("run-id");
  if (graphData.event_ids && graphData.event_ids.length > 0) {
    runIdEl.textContent = graphData.event_ids[0];
  } else {
    runIdEl.textContent = "latest";
  }

  const stats = graphData.stats || {};
  const score = (stats.denied || 0) + (stats.unauthenticated || 0);
  document.getElementById("badge-score").textContent = `Score: ${score}`;
}

async function fetchData() {
  try {
    const resp = await fetch("/api/trust-graph");
    graphData = await resp.json();
    document.getElementById("badge-alive").classList.remove("dead");
    document.getElementById("badge-alive").textContent = "ALIVE";
    updateTopBar();
    renderEventPills();
    renderGraph();
  } catch (e) {
    document.getElementById("badge-alive").classList.add("dead");
    document.getElementById("badge-alive").textContent = "DOWN";
  }
}

function escapeHtml(str) {
  if (!str) return "";
  return String(str).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// Page tab switching
function switchPage(pageName) {
  document.querySelectorAll('.page-tab').forEach(tab => {
    tab.classList.toggle('active', tab.dataset.page === pageName);
  });
  document.querySelectorAll('.page-content').forEach(page => {
    page.classList.toggle('active', page.id === `${pageName}-page`);
  });
}

// Event listeners
document.querySelectorAll('.page-tab').forEach(tab => {
  tab.addEventListener('click', () => switchPage(tab.dataset.page));
});

document.getElementById("btn-load").addEventListener("click", fetchData);
document.getElementById("detail-close").addEventListener("click", hideDetailPanel);
document.getElementById("btn-print").addEventListener("click", () => window.print());

document.querySelectorAll(".tab").forEach(tab => {
  tab.addEventListener("click", () => setActiveTab(tab.dataset.tab));
});

window.addEventListener("resize", () => { if (graphData) renderGraph(); });

fetchData();
