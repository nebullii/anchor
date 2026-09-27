// In-memory fake of Anchor's /api/v1 JSON API, following the contract in
// the brief. Deployments advance one status per GET so "wait" can be tested.

import http from "node:http";

export const TOKEN = "anc_test_token_123";

const PROGRESSION = ["queued", "building", "deploying", "health_check"];

export async function startFakeApi() {
  const state = {
    requests: [],
    projects: [
      { id: 1, name: "shop", framework: "rails", provider: "local_docker", production_branch: "main" },
      { id: 2, name: "broken", framework: "express", provider: "gcp_cloud_run", production_branch: "main" },
    ],
    analysis: {
      1: { framework: "rails", port: 3000, detected_env_vars: [{ key: "DATABASE_URL", required: true }], preflight: [] },
    },
    deployments: new Map(),
    secrets: { 1: { DATABASE_URL: "postgres://x" }, 2: {} },
    nextId: 100,
  };

  const server = http.createServer(async (req, res) => {
    let body = "";
    for await (const chunk of req) body += chunk;
    const url = new URL(req.url, "http://localhost");
    state.requests.push({ method: req.method, path: url.pathname, query: Object.fromEntries(url.searchParams), body: body ? JSON.parse(body) : undefined, auth: req.headers.authorization });

    const send = (status, data) => {
      res.writeHead(status, { "Content-Type": "application/json" });
      res.end(JSON.stringify(data));
    };
    const fail = (status, code, message) => send(status, { error: { code, message } });

    if (req.headers.authorization !== `Bearer ${TOKEN}`) return fail(401, "unauthorized", "Invalid or missing API token");

    const p = url.pathname.replace(/^\/api\/v1/, "");
    let m;

    if (req.method === "GET" && p === "/me") return send(200, { user: { id: 1, name: "Test" } });
    if (req.method === "GET" && p === "/projects") return send(200, { projects: state.projects });

    if ((m = p.match(/^\/projects\/(\d+)$/)) && req.method === "GET") {
      const project = state.projects.find((x) => x.id === Number(m[1]));
      return project ? send(200, { project }) : fail(404, "not_found", "Project not found");
    }
    if ((m = p.match(/^\/projects\/(\d+)\/analysis$/)) && req.method === "GET") {
      const a = state.analysis[m[1]];
      return a ? send(200, { analysis: a }) : fail(404, "not_found", "No analysis yet");
    }
    if ((m = p.match(/^\/projects\/(\d+)\/deployments$/))) {
      const projectId = Number(m[1]);
      if (!state.projects.some((x) => x.id === projectId)) return fail(404, "not_found", "Project not found");
      if (req.method === "GET") {
        const list = [...state.deployments.values()].filter((d) => d.project_id === projectId).reverse();
        return send(200, { deployments: list.slice(0, Number(url.searchParams.get("limit") || 20)) });
      }
      if (req.method === "POST") {
        const active = [...state.deployments.values()].find(
          (d) => d.project_id === projectId && PROGRESSION.includes(d.status),
        );
        if (active) return fail(409, "deployment_in_progress", `Deployment ${active.id} is already in progress`);
        const payload = body ? JSON.parse(body) : {};
        const d = {
          id: state.nextId++, project_id: projectId, status: "queued", triggered_by: "cli",
          branch: payload.branch || "main", error_message: null, error_category: null, ai_explanation: null,
          _step: 0, _logs: [],
        };
        state.deployments.set(d.id, d);
        return send(202, { deployment: publicDeployment(d) });
      }
    }
    if ((m = p.match(/^\/deployments\/(\d+)$/)) && req.method === "GET") {
      const d = state.deployments.get(Number(m[1]));
      if (!d) return fail(404, "not_found", "Deployment not found");
      advance(d);
      return send(200, { deployment: publicDeployment(d) });
    }
    if ((m = p.match(/^\/deployments\/(\d+)\/logs$/)) && req.method === "GET") {
      const d = state.deployments.get(Number(m[1]));
      if (!d) return fail(404, "not_found", "Deployment not found");
      const after = Number(url.searchParams.get("after_id") || 0);
      const logs = d._logs.filter((l) => l.id > after);
      return send(200, { logs, next_after_id: logs.length ? logs[logs.length - 1].id : after });
    }
    if ((m = p.match(/^\/deployments\/(\d+)\/cancel$/)) && req.method === "POST") {
      const d = state.deployments.get(Number(m[1]));
      if (!d) return fail(404, "not_found", "Deployment not found");
      if (!PROGRESSION.includes(d.status)) return fail(422, "invalid_transition", `Cannot cancel a ${d.status} deployment`);
      d.status = "cancelled";
      return send(200, { deployment: publicDeployment(d) });
    }
    if ((m = p.match(/^\/projects\/(\d+)\/rollback$/)) && req.method === "POST") {
      const d = { id: state.nextId++, project_id: Number(m[1]), status: "queued", triggered_by: "rollback", _step: 0, _logs: [] };
      state.deployments.set(d.id, d);
      return send(202, { deployment: publicDeployment(d), target_deployment_id: body ? JSON.parse(body).deployment_id ?? null : null });
    }
    if ((m = p.match(/^\/projects\/(\d+)\/secrets$/)) && req.method === "GET") {
      return send(200, { secrets: Object.keys(state.secrets[m[1]] || {}).map((key) => ({ key })) });
    }
    if ((m = p.match(/^\/projects\/(\d+)\/secrets\/([^/]+)$/)) && req.method === "PUT") {
      const key = decodeURIComponent(m[2]);
      if (!/^[A-Z][A-Z0-9_]*$/.test(key)) return fail(422, "invalid_key", "Key must be SCREAMING_SNAKE_CASE");
      state.secrets[m[1]] ||= {};
      state.secrets[m[1]][key] = JSON.parse(body).value;
      return send(200, { secret: { key } });
    }
    return fail(404, "not_found", `No route for ${req.method} ${url.pathname}`);
  });

  // Advances a deployment one step; project 2 always fails at health_check.
  function advance(d) {
    if (!PROGRESSION.includes(d.status)) return;
    d._step += 1;
    const id = d._logs.length + 1;
    if (d._step < PROGRESSION.length) {
      d.status = PROGRESSION[d._step];
      d._logs.push({ id, message: `status -> ${d.status}`, level: "info", source: "system" });
    } else if (d.project_id === 2) {
      d.status = "failed";
      d.error_message = "Health check failed: GET / returned 502";
      d.error_category = "health_check_failed";
      d.ai_explanation = "The app is not listening on $PORT.";
      d._logs.push({ id, message: "health check failed", level: "error", source: "system" });
    } else {
      d.status = "running";
      d.service_url = "http://localhost:49153";
      d._logs.push({ id, message: "traffic shifted", level: "info", source: "system" });
    }
  }

  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const { port } = server.address();
  return {
    url: `http://127.0.0.1:${port}`,
    state,
    close: () => new Promise((r) => server.close(r)),
  };
}

function publicDeployment(d) {
  return Object.fromEntries(Object.entries(d).filter(([k]) => !k.startsWith("_")));
}
