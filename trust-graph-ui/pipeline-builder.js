// Pipeline Builder UI Logic
(function() {
  'use strict';

  // State
  let availableAgents = [];
  let selectedAgents = [];
  let lastExecutionResult = null;

  // Initialize
  async function init() {
    setupEventListeners();
    await loadAgents();
  }

  // Event Listeners
  function setupEventListeners() {
    document.getElementById('btn-run-pipeline').addEventListener('click', runPipeline);
    document.getElementById('btn-clear-pipeline').addEventListener('click', clearPipeline);
    document.getElementById('btn-view-trust-graph').addEventListener('click', viewInTrustGraph);
    document.getElementById('btn-load-templates').addEventListener('click', showTemplates);
  }

  // Load available agents from backend
  async function loadAgents() {
    const agentListEl = document.getElementById('agent-list');

    try {
      const response = await fetch('/api/agents');
      const data = await response.json();
      availableAgents = data.agents || [];

      if (availableAgents.length === 0) {
        agentListEl.innerHTML = '<div class="empty-state">No agents available</div>';
        return;
      }

      renderAgentList();
    } catch (error) {
      console.error('Failed to load agents:', error);
      agentListEl.innerHTML = `<div class="error-state">Failed to load agents: ${error.message}</div>`;
    }
  }

  // Render agent list with checkboxes
  function renderAgentList() {
    const agentListEl = document.getElementById('agent-list');
    agentListEl.innerHTML = '';

    availableAgents.forEach(agent => {
      const agentItem = document.createElement('div');
      agentItem.className = 'agent-item';

      const checkbox = document.createElement('input');
      checkbox.type = 'checkbox';
      checkbox.id = `agent-${agent.name}`;
      checkbox.value = agent.name;
      checkbox.addEventListener('change', (e) => toggleAgent(agent.name, e.target.checked));

      const label = document.createElement('label');
      label.htmlFor = `agent-${agent.name}`;
      label.innerHTML = `
        <strong>${agent.name}</strong>
        <div class="agent-details">
          <span class="agent-skills">${(agent.skills || []).join(', ')}</span>
          <span class="agent-capabilities">${(agent.capabilities || []).join(', ')}</span>
        </div>
      `;

      agentItem.appendChild(checkbox);
      agentItem.appendChild(label);
      agentListEl.appendChild(agentItem);
    });
  }

  // Toggle agent selection
  function toggleAgent(agentName, selected) {
    if (selected) {
      if (!selectedAgents.includes(agentName)) {
        selectedAgents.push(agentName);
      }
    } else {
      selectedAgents = selectedAgents.filter(name => name !== agentName);
    }

    updatePipelinePreview();
  }

  // Update pipeline preview
  function updatePipelinePreview() {
    const stepsEl = document.getElementById('pipeline-steps');
    const runBtn = document.getElementById('btn-run-pipeline');

    if (selectedAgents.length === 0) {
      stepsEl.innerHTML = '<div class="empty-state">Select agents from the left to build a pipeline</div>';
      runBtn.disabled = true;
      return;
    }

    stepsEl.innerHTML = '';
    selectedAgents.forEach((agentName, index) => {
      const stepEl = document.createElement('div');
      stepEl.className = 'pipeline-step';
      stepEl.innerHTML = `
        <span class="step-number">${index + 1}.</span>
        <span class="step-name">${agentName}</span>
        <button class="btn-remove" data-agent="${agentName}" aria-label="Remove">×</button>
      `;

      const removeBtn = stepEl.querySelector('.btn-remove');
      removeBtn.addEventListener('click', () => removeAgent(agentName));

      stepsEl.appendChild(stepEl);
    });

    runBtn.disabled = false;
  }

  // Remove agent from pipeline
  function removeAgent(agentName) {
    selectedAgents = selectedAgents.filter(name => name !== agentName);

    const checkbox = document.getElementById(`agent-${agentName}`);
    if (checkbox) checkbox.checked = false;

    updatePipelinePreview();
  }

  // Clear pipeline
  function clearPipeline() {
    selectedAgents = [];
    document.querySelectorAll('#agent-list input[type="checkbox"]').forEach(cb => {
      cb.checked = false;
    });
    updatePipelinePreview();

    // Clear execution log
    const logContent = document.getElementById('log-content');
    logContent.innerHTML = '<div class="empty-state">Pipeline execution results will appear here</div>';
    document.getElementById('btn-view-trust-graph').style.display = 'none';
  }

  // Run pipeline
  async function runPipeline() {
    if (selectedAgents.length === 0) return;

    const runBtn = document.getElementById('btn-run-pipeline');
    const logContent = document.getElementById('log-content');

    runBtn.disabled = true;
    runBtn.textContent = 'Running...';
    logContent.innerHTML = '<div class="loading">Executing pipeline...</div>';

    try {
      const response = await fetch('/api/pipelines/execute', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ pipeline: selectedAgents })
      });

      const result = await response.json();
      lastExecutionResult = result;

      if (!response.ok) {
        throw new Error(result.error || `HTTP ${response.status}`);
      }

      renderExecutionLog(result);
      document.getElementById('btn-view-trust-graph').style.display = 'block';
    } catch (error) {
      console.error('Pipeline execution failed:', error);
      logContent.innerHTML = `<div class="error-state">Execution failed: ${error.message}</div>`;
    } finally {
      runBtn.disabled = false;
      runBtn.textContent = 'Run Pipeline';
    }
  }

  // Render execution log
  function renderExecutionLog(result) {
    const logContent = document.getElementById('log-content');
    logContent.innerHTML = '';

    const header = document.createElement('div');
    header.className = 'log-header';
    header.innerHTML = `
      <strong>Run ID:</strong> ${result.run_id || 'N/A'} &nbsp;|&nbsp;
      <strong>Status:</strong> <span class="status-${result.status}">${result.status}</span> &nbsp;|&nbsp;
      <strong>Duration:</strong> ${result.total_duration_ms || 0}ms
    `;
    logContent.appendChild(header);

    const stepsList = document.createElement('div');
    stepsList.className = 'log-steps';

    (result.steps || []).forEach((step, index) => {
      const stepEl = document.createElement('div');
      stepEl.className = `log-step status-${step.status >= 200 && step.status < 300 ? 'success' : 'error'}`;

      const statusIcon = step.status >= 200 && step.status < 300 ? '✓' : '✗';
      const prevAgent = index === 0 ? 'alice' : result.steps[index - 1].agent;

      stepEl.innerHTML = `
        <span class="log-icon">${statusIcon}</span>
        <span class="log-text">
          ${prevAgent} → ${step.agent}
          <span class="log-meta">(${step.status}, ${step.duration_ms}ms)</span>
        </span>
      `;

      stepsList.appendChild(stepEl);
    });

    logContent.appendChild(stepsList);

    if (result.keycloak_events && result.keycloak_events.length > 0) {
      const eventsEl = document.createElement('div');
      eventsEl.className = 'log-events';
      eventsEl.innerHTML = `
        <strong>Keycloak Events:</strong> ${result.keycloak_events.length} TOKEN_EXCHANGE events
        <div class="event-ids">${result.keycloak_events.join(', ')}</div>
      `;
      logContent.appendChild(eventsEl);
    }
  }

  // View in trust graph
  function viewInTrustGraph() {
    // Switch to trust graph tab
    const trustGraphTab = document.querySelector('.page-tab[data-page="trust-graph"]');
    if (trustGraphTab) {
      trustGraphTab.click();

      // Trigger trust graph reload
      setTimeout(() => {
        if (window.fetchData) {
          window.fetchData();
        }
      }, 100);
    }
  }

  // Show pipeline templates
  async function showTemplates() {
    try {
      const response = await fetch('/api/pipelines/templates');
      const data = await response.json();
      const templates = data.templates || [];

      if (templates.length === 0) {
        alert('No pipeline templates available');
        return;
      }

      // Simple template selection (could be improved with modal)
      const templateNames = templates.map((t, i) => `${i + 1}. ${t.name}`).join('\n');
      const selection = prompt(`Choose a pipeline template:\n\n${templateNames}\n\nEnter number (1-${templates.length}):`);

      if (selection) {
        const index = parseInt(selection) - 1;
        if (index >= 0 && index < templates.length) {
          loadTemplate(templates[index]);
        }
      }
    } catch (error) {
      console.error('Failed to load templates:', error);
      alert(`Failed to load templates: ${error.message}`);
    }
  }

  // Load a pipeline template
  function loadTemplate(template) {
    clearPipeline();

    template.steps.forEach(agentName => {
      const checkbox = document.getElementById(`agent-${agentName}`);
      if (checkbox) {
        checkbox.checked = true;
        if (!selectedAgents.includes(agentName)) {
          selectedAgents.push(agentName);
        }
      }
    });

    updatePipelinePreview();
  }

  // Initialize on DOM ready
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
