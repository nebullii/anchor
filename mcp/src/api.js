// Thin client for Anchor's JSON API (/api/v1). This is the ONLY way the MCP
// server talks to Anchor: no database access, no shelling out.
//
// Errors from the API arrive as {"error":{"code","message"}} and are raised
// as ApiError so tools can surface them to the agent verbatim.

export class ApiError extends Error {
  constructor(status, code, message) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
  }
}

const DEFAULT_TIMEOUT_MS = 30_000;

export class AnchorApi {
  /**
   * @param {object} opts
   * @param {string} opts.baseUrl  e.g. https://anchor.example.com
   * @param {string} opts.token    API token ("anc_...")
   * @param {typeof fetch} [opts.fetchImpl]
   * @param {number} [opts.timeoutMs]
   */
  constructor({ baseUrl, token, fetchImpl = globalThis.fetch, timeoutMs = DEFAULT_TIMEOUT_MS }) {
    if (!baseUrl) throw new Error("ANCHOR_URL is not set");
    if (!token) throw new Error("ANCHOR_TOKEN is not set");
    this.baseUrl = baseUrl.replace(/\/+$/, "");
    this.token = token;
    this.fetch = fetchImpl;
    this.timeoutMs = timeoutMs;
  }

  async request(method, path, { body, query } = {}) {
    const url = new URL(`${this.baseUrl}/api/v1${path}`);
    for (const [k, v] of Object.entries(query || {})) {
      if (v !== undefined && v !== null && v !== "") url.searchParams.set(k, String(v));
    }

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    let res;
    try {
      res = await this.fetch(url, {
        method,
        headers: {
          Authorization: `Bearer ${this.token}`,
          Accept: "application/json",
          ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
          "User-Agent": "anchor-mcp/0.1.0",
        },
        body: body !== undefined ? JSON.stringify(body) : undefined,
        signal: controller.signal,
      });
    } catch (err) {
      const reason = err?.name === "AbortError" ? `timed out after ${this.timeoutMs}ms` : err?.message;
      throw new ApiError(0, "network_error", `Could not reach Anchor at ${this.baseUrl}: ${reason}`);
    } finally {
      clearTimeout(timer);
    }

    const text = await res.text();
    let data = null;
    if (text) {
      try {
        data = JSON.parse(text);
      } catch {
        data = null;
      }
    }

    if (!res.ok) {
      const code = data?.error?.code || `http_${res.status}`;
      const message = data?.error?.message || `Anchor API returned HTTP ${res.status}`;
      throw new ApiError(res.status, code, message);
    }
    return data ?? {};
  }

  // ---- Endpoints (see the JSON API contract) ------------------------------

  me() { return this.request("GET", "/me"); }
  listProjects() { return this.request("GET", "/projects"); }
  getProject(id) { return this.request("GET", `/projects/${seg(id)}`); }
  getAnalysis(id) { return this.request("GET", `/projects/${seg(id)}/analysis`); }
  listDeployments(projectId, limit) {
    return this.request("GET", `/projects/${seg(projectId)}/deployments`, { query: { limit } });
  }
  createDeployment(projectId, branch) {
    return this.request("POST", `/projects/${seg(projectId)}/deployments`, { body: branch ? { branch } : {} });
  }
  getDeployment(id) { return this.request("GET", `/deployments/${seg(id)}`); }
  getLogs(id, afterId) {
    return this.request("GET", `/deployments/${seg(id)}/logs`, { query: { after_id: afterId } });
  }
  cancelDeployment(id) { return this.request("POST", `/deployments/${seg(id)}/cancel`); }
  rollback(projectId, deploymentId) {
    return this.request("POST", `/projects/${seg(projectId)}/rollback`, {
      body: deploymentId ? { deployment_id: deploymentId } : {},
    });
  }
  listSecrets(projectId) { return this.request("GET", `/projects/${seg(projectId)}/secrets`); }
  setSecret(projectId, key, value) {
    return this.request("PUT", `/projects/${seg(projectId)}/secrets/${seg(key)}`, { body: { value } });
  }
}

// Encodes a path segment so ids like "../me" cannot change the route.
function seg(value) {
  return encodeURIComponent(String(value));
}
