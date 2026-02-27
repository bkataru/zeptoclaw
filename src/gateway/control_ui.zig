//! Control UI Module
//! Provides web-based UI for monitoring and managing the gateway

const std = @import("std");

pub const ControlUI = struct {
    allocator: std.mem.Allocator,
    enabled: bool,
    allow_insecure_auth: bool,

    pub fn init(allocator: std.mem.Allocator, enabled: bool, allow_insecure_auth: bool) ControlUI {
        return ControlUI{
            .allocator = allocator,
            .enabled = enabled,
            .allow_insecure_auth = allow_insecure_auth,
        };
    }

    pub fn deinit(self: *ControlUI) void {
        _ = self;
    }

    /// Generate the HTML for the control UI
    pub fn generateHTML(self: *ControlUI) ![]const u8 {
        const html =
            \\<!DOCTYPE html>
            \\<html lang="en">
            \\<head>
            \\  <meta charset="UTF-8">
            \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
            \\  <title>ZeptoClaw Gateway Control UI</title>
            \\  <style>
            \\    * { margin: 0; padding: 0; box-sizing: border-box; }
            \\    body {
            \\      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
            \\      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            \\      min-height: 100vh;
            \\      padding: 20px;
            \\    }
            \\    .container {
            \\      max-width: 1200px;
            \\      margin: 0 auto;
            \\      background: white;
            \\      border-radius: 12px;
            \\      box-shadow: 0 10px 40px rgba(0,0,0,0.2);
            \\      overflow: hidden;
            \\    }
            \\    .header {
            \\      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            \\      color: white;
            \\      padding: 30px;
            \\      text-align: center;
            \\    }
            \\    .header h1 { font-size: 2.5em; margin-bottom: 10px; }
            \\    .header p { opacity: 0.9; font-size: 1.1em; }
            \\    .content { padding: 30px; }
            \\    .status-card {
            \\      background: #f8f9fa;
            \\      border-radius: 8px;
            \\      padding: 20px;
            \\      margin-bottom: 20px;
            \\      border-left: 4px solid #28a745;
            \\    }
            \\    .status-card h2 { color: #333; margin-bottom: 15px; }
            \\    .status-indicator {
            \\      display: inline-block;
            \\      width: 12px;
            \\      height: 12px;
            \\      background: #28a745;
            \\      border-radius: 50%;
            \\      margin-right: 8px;
            \\      animation: pulse 2s infinite;
            \\    }
            \\    @keyframes pulse {
            \\      0%, 100% { opacity: 1; }
            \\      50% { opacity: 0.5; }
            \\    }
            \\    .stats-grid {
            \\      display: grid;
            \\      grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            \\      gap: 20px;
            \\      margin-bottom: 30px;
            \\    }
            \\    .stat-card {
            \\      background: white;
            \\      border: 1px solid #e0e0e0;
            \\      border-radius: 8px;
            \\      padding: 20px;
            \\      text-align: center;
            \\    }
            \\    .stat-card h3 { color: #666; font-size: 0.9em; margin-bottom: 10px; }
            \\    .stat-card .value { font-size: 2em; font-weight: bold; color: #333; }
            \\    .sessions-section { margin-top: 30px; }
            \\    .sessions-section h2 { color: #333; margin-bottom: 20px; }
            \\    table { width: 100%; border-collapse: collapse; }
            \\    th, td {
            \\      padding: 12px;
            \\      text-align: left;
            \\      border-bottom: 1px solid #e0e0e0;
            \\    }
            \\    th { background: #f8f9fa; font-weight: 600; color: #333; }
            \\    tr:hover { background: #f8f9fa; }
            \\    .status-badge {
            \\      padding: 4px 12px;
            \\      border-radius: 12px;
            \\      font-size: 0.85em;
            \\      font-weight: 500;
            \\    }
            \\    .status-active { background: #d4edda; color: #155724; }
            \\    .status-idle { background: #fff3cd; color: #856404; }
            \\    .status-terminated { background: #f8d7da; color: #721c24; }
            \\    .btn {
            \\      padding: 8px 16px;
            \\      border: none;
            \\      border-radius: 4px;
            \\      cursor: pointer;
            \\      font-size: 0.9em;
            \\      transition: all 0.2s;
            \\    }
            \\    .btn-danger { background: #dc3545; color: white; }
            \\    .btn-danger:hover { background: #c82333; }
            \\    .logs-section { margin-top: 30px; }
            \\    .logs-section h2 { color: #333; margin-bottom: 20px; }
            \\    .logs-container {
            \\      background: #1e1e1e;
            \\      color: #d4d4d4;
            \\      padding: 20px;
            \\      border-radius: 8px;
            \\      font-family: 'Courier New', monospace;
            \\      max-height: 300px;
            \\      overflow-y: auto;
            \\    }
            \\    .log-entry { margin-bottom: 8px; }
            \\    .log-timestamp { color: #569cd6; }
            \\    .log-level { color: #4ec9b0; }
            \\    .log-message { color: #d4d4d4; }
            \\    .connection-status {
            \\      position: fixed;
            \\      bottom: 20px;
            \\      right: 20px;
            \\      padding: 10px 20px;
            \\      background: white;
            \\      border-radius: 8px;
            \\      box-shadow: 0 2px 10px rgba(0,0,0,0.1);
            \\      display: flex;
            \\      align-items: center;
            \\      gap: 10px;
            \\    }
            \\    .connection-status.connected { border-left: 4px solid #28a745; }
            \\    .connection-status.disconnected { border-left: 4px solid #dc3545; }
            \\  </style>
            \\</head>
            \\<body>
            \\  <div class="container">
            \\    <div class="header">
            \\      <h1>🦀 ZeptoClaw Gateway</h1>
            \\      <p>Real-time monitoring and control interface</p>
            \\    </div>
            \\    <div class="content">
            \\      <div class="status-card">
            \\        <h2><span class="status-indicator"></span>Gateway Status</h2>
            \\        <p><strong>Status:</strong> <span id="gateway-status">Loading...</span></p>
            \\        <p><strong>Uptime:</strong> <span id="gateway-uptime">Loading...</span></p>
            \\      </div>
            \\      <div class="stats-grid">
            \\        <div class="stat-card">
            \\          <h3>Total Sessions</h3>
            \\          <div class="value" id="stat-total-sessions">-</div>
            \\        </div>
            \\        <div class="stat-card">
            \\          <h3>Active Sessions</h3>
            \\          <div class="value" id="stat-active-sessions">-</div>
            \\        </div>
            \\        <div class="stat-card">
            \\          <h3>Total Messages</h3>
            \\          <div class="value" id="stat-total-messages">-</div>
            \\        </div>
            \\        <div class="stat-card">
            \\          <h3>WebSocket Clients</h3>
            \\          <div class="value" id="stat-ws-clients">-</div>
            \\        </div>
            \\      </div>
            \\      <div class="sessions-section">
            \\        <h2>Active Sessions</h2>
            \\        <table>
            \\          <thead>
            \\            <tr>
            \\              <th>ID</th>
            \\              <th>User</th>
            \\              <th>Channel</th>
            \\              <th>Messages</th>
            \\              <th>Status</th>
            \\              <th>Actions</th>
            \\            </tr>
            \\          </thead>
            \\          <tbody id="sessions-table">
            \\            <tr><td colspan="6">Loading sessions...</td></tr>
            \\          </tbody>
            \\        </table>
            \\      </div>
            \\      <div class="logs-section">
            \\        <h2>Recent Logs</h2>
            \\        <div class="logs-container" id="logs-container">
            \\          <div class="log-entry">
            \\            <span class="log-timestamp">[Loading...]</span>
            \\            <span class="log-level">INFO</span>
            \\            <span class="log-message">Fetching logs...</span>
            \\          </div>
            \\        </div>
            \\      </div>
            \\    </div>
            \\  </div>
            \\  <div class="connection-status" id="connection-status">
            \\    <span id="connection-indicator" class="status-indicator"></span>
            \\    <span id="connection-text">Connecting...</span>
            \\  </div>
            \\  <script>
            \\    // Configuration
            \\    const API_BASE = window.location.origin;
            \\    const WS_URL = `ws://${window.location.host}/ws`;
            \\
            \\    // State
            \\    let ws = null;
            \\    let reconnectInterval = null;
            \\    let startTime = Date.now();
            \\
            \\    // Initialize
            \\    document.addEventListener('DOMContentLoaded', () => {
            \\      connectWebSocket();
            \\      fetchStatus();
            \\      fetchSessions();
            \\      fetchLogs();
            \\
            \\      // Refresh data every 5 seconds
            \\      setInterval(() => {
            \\        fetchStatus();
            \\        fetchSessions();
            \\      }, 5000);
            \\    });
            \\
            \\    // WebSocket connection
            \\    function connectWebSocket() {
            \\      ws = new WebSocket(WS_URL);
            \\
            \\      ws.onopen = () => {
            \\        console.log('WebSocket connected');
            \\        updateConnectionStatus(true);
            \\        if (reconnectInterval) {
            \\          clearInterval(reconnectInterval);
            \\          reconnectInterval = null;
            \\        }
            \\      };
            \\
            \\      ws.onmessage = (event) => {
            \\        console.log('WebSocket message:', event.data);
            \\        const data = JSON.parse(event.data);
            \\        handleWebSocketMessage(data);
            \\      };
            \\
            \\      ws.onclose = () => {
            \\        console.log('WebSocket disconnected');
            \\        updateConnectionStatus(false);
            \\        if (!reconnectInterval) {
            \\          reconnectInterval = setInterval(connectWebSocket, 5000);
            \\        }
            \\      };
            \\
            \\      ws.onerror = (error) => {
            \\        console.error('WebSocket error:', error);
            \\      };
            \\    }
            \\
            \\    // Handle WebSocket messages
            \\    function handleWebSocketMessage(data) {
            \\      switch (data.type) {
            \\        case 'status_update':
            \\          updateStats(data.stats);
            \\          break;
            \\        case 'session_created':
            \\        case 'session_updated':
            \\        case 'session_terminated':
            \\          fetchSessions();
            \\          break;
            \\        case 'log_entry':
            \\          addLogEntry(data.log);
            \\          break;
            \\      }
            \\    }
            \\
            \\    // Update connection status
            \\    function updateConnectionStatus(connected) {
            \\      const statusEl = document.getElementById('connection-status');
            \\      const textEl = document.getElementById('connection-text');
            \\
            \\      if (connected) {
            \\        statusEl.classList.add('connected');
            \\        statusEl.classList.remove('disconnected');
            \\        textEl.textContent = 'Connected';
            \\      } else {
            \\        statusEl.classList.add('disconnected');
            \\        statusEl.classList.remove('connected');
            \\        textEl.textContent = 'Disconnected';
            \\      }
            \\    }
            \\
            \\    // Fetch gateway status
            \\    async function fetchStatus() {
            \\      try {
            \\        const response = await fetch(`${API_BASE}/status`, {
            \\          headers: { 'X-Auth-Token': getAuthToken() }
            \\        });
            \\        const data = await response.json();
            \\        updateStats(data);
            \\        document.getElementById('gateway-status').textContent = 'Running';
            \\        updateUptime();
            \\      } catch (error) {
            \\        console.error('Error fetching status:', error);
            \\        document.getElementById('gateway-status').textContent = 'Error';
            \\      }
            \\    }
            \\
            \\    // Update statistics
            \\    function updateStats(stats) {
            \\      if (stats.sessions) {
            \\        document.getElementById('stat-total-sessions').textContent = stats.sessions.total || 0;
            \\        document.getElementById('stat-active-sessions').textContent = stats.sessions.active || 0;
            \\      }
            \\      document.getElementById('stat-total-messages').textContent = stats.total_messages || 0;
            \\      document.getElementById('stat-ws-clients').textContent = stats.websocket_clients || 0;
            \\    }
            \\
            \\    // Update uptime
            \\    function updateUptime() {
            \\      const uptime = Date.now() - startTime;
            \\      const seconds = Math.floor(uptime / 1000);
            \\      const minutes = Math.floor(seconds / 60);
            \\      const hours = Math.floor(minutes / 60);
            \\      const days = Math.floor(hours / 24);
            \\
            \\      let uptimeStr = '';
            \\      if (days > 0) uptimeStr += `${days}d `;
            \\      if (hours % 24 > 0) uptimeStr += `${hours % 24}h `;
            \\      if (minutes % 60 > 0) uptimeStr += `${minutes % 60}m `;
            \\      uptimeStr += `${seconds % 60}s`;
            \\
            \\      document.getElementById('gateway-uptime').textContent = uptimeStr;
            \\    }
            \\
            \\    // Fetch sessions
            \\    async function fetchSessions() {
            \\      try {
            \\        const response = await fetch(`${API_BASE}/sessions`, {
            \\          headers: { 'X-Auth-Token': getAuthToken() }
            \\        });
            \\        const data = await response.json();
            \\        renderSessions(data.sessions || []);
            \\      } catch (error) {
            \\        console.error('Error fetching sessions:', error);
            \\      }
            \\    }
            \\
            \\    // Render sessions table
            \\    function renderSessions(sessions) {
            \\      const tbody = document.getElementById('sessions-table');
            \\
            \\      if (sessions.length === 0) {
            \\        tbody.innerHTML = '<tr><td colspan="6">No active sessions</td></tr>';
            \\        return;
            \\      }
            \\
            \\      tbody.innerHTML = sessions.map(session => `
            \\        <tr>
            \\          <td>${escapeHtml(session.id)}</td>
            \\          <td>${escapeHtml(session.user)}</td>
            \\          <td>${escapeHtml(session.channel)}</td>
            \\          <td>${session.message_count}</td>
            \\          <td><span class="status-badge status-${session.status}">${session.status}</span></td>
            \\          <td>
            \\            <button class="btn btn-danger" onclick="terminateSession('${escapeHtml(session.id)}')">Terminate</button>
            \\          </td>
            \\        </tr>
            \\      `).join('');
            \\    }
            \\
            \\    // Terminate session
            \\    async function terminateSession(sessionId) {
            \\      if (!confirm(`Are you sure you want to terminate session ${sessionId}?`)) {
            \\        return;
            \\      }
            \\
            \\      try {
            \\        const response = await fetch(`${API_BASE}/sessions/${sessionId}/terminate`, {
            \\          method: 'POST',
            \\          headers: { 'X-Auth-Token': getAuthToken() }
            \\        });
            \\        const data = await response.json();
            \\        if (data.success) {
            \\          fetchSessions();
            \\        }
            \\      } catch (error) {
            \\        console.error('Error terminating session:', error);
            \\        alert('Failed to terminate session');
            \\      }
            \\    }
            \\
            \\    // Fetch logs
            \\    async function fetchLogs() {
            \\      try {
            \\        const response = await fetch(`${API_BASE}/logs`, {
            \\          headers: { 'X-Auth-Token': getAuthToken() }
            \\        });
            \\        const data = await response.json();
            \\        renderLogs(data.logs || []);
            \\      } catch (error) {
            \\        console.error('Error fetching logs:', error);
            \\      }
            \\    }
            \\
            \\    // Render logs
            \\    function renderLogs(logs) {
            \\      const container = document.getElementById('logs-container');
            \\      container.innerHTML = logs.map(log => `
            \\        <div class="log-entry">
            \\          <span class="log-timestamp">[${log.timestamp || 'Now'}]</span>
            \\          <span class="log-level">${log.level || 'INFO'}</span>
            \\          <span class="log-message">${escapeHtml(log.message || log)}</span>
            \\        </div>
            \\      `).join('');
            \\    }
            \\
            \\    // Add log entry
            \\    function addLogEntry(log) {
            \\      const container = document.getElementById('logs-container');
            \\      const entry = document.createElement('div');
            \\      entry.className = 'log-entry';
            \\      entry.innerHTML = `
            \\        <span class="log-timestamp">[${log.timestamp || 'Now'}]</span>
            \\        <span class="log-level">${log.level || 'INFO'}</span>
            \\        <span class="log-message">${escapeHtml(log.message)}</span>
            \\      `;
            \\      container.insertBefore(entry, container.firstChild);
            \\
            \\      // Keep only last 50 log entries
            \\      while (container.children.length > 50) {
            \\        container.removeChild(container.lastChild);
            \\      }
            \\    }
            \\
            \\    // Get auth token from localStorage or prompt
            \\    function getAuthToken() {
            \\      let token = localStorage.getItem('zeptoclay_auth_token');
            \\      if (!token) {
            \\        token = prompt('Enter your ZeptoClaw auth token:');
            \\        if (token) {
            \\          localStorage.setItem('zeptoclay_auth_token', token);
            \\        }
            \\      }
            \\      return token;
            \\    }
            \\
            \\    // Escape HTML to prevent XSS
            \\    function escapeHtml(text) {
            \\      const div = document.createElement('div');
            \\      div.textContent = text;
            \\      return div.innerHTML;
            \\    }
            \\  </script>
            \\</body>
            \\</html>
        ;

        return self.allocator.dupe(u8, html);
    }
};
