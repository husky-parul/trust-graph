# Kagenti Demo Rebuild — Implementation Plan

## Context

The demo shows agentic IAM: individual agent identities, token exchange with scope narrowing, and a live trust graph. The rebuild uses Kagenti's native capabilities — dynamic discovery, AuthBridge token exchange, and Kagenti backend routing — so the talk can show agent registration and trust forming organically.

## Request Flow — How It Works End to End

```
Alice → Kagenti UI → Kagenti Backend (FastAPI) → A2A Agent
                                                      │
                                                      │ agent calls another agent
                                                      │ (plain HTTP to K8s service)
                                                      │
                                                AuthBridge sidecar
                                                (iptables intercept)
                                                      │
                                                      │ RFC 8693 token exchange
                                                      ▼
                                                  Keycloak
                                             (custom SPI runs here)
                                             ┌─────────────────────┐
                                             │ 1. Act-claim inject │
                                             │    (delegation chain)│
                                             │ 2. Scope narrowing  │
                                             │    (intersect scopes)│
                                             └─────────────────────┘
                                                      │
                                                      │ new token with:
                                                      │  - act claim (who delegated to whom)
                                                      │  - narrowed scopes
                                                      ▼
                                                Downstream agent
                                             (receives scoped token)
```

### Step-by-step walkthrough

1. **Alice logs in** via Keycloak, gets a JWT token
2. **Alice sends request** through Kagenti UI → Kagenti Backend
3. **Kagenti Backend** discovers agents via K8s label `kagenti.io/type=agent`, resolves agent URL via K8s service DNS (`http://{name}.{namespace}.svc.cluster.local:8080`), forwards request with Alice's token
4. **Agent receives request** — AuthBridge sidecar validates inbound JWT (signature, issuer, audience)
5. **Agent calls downstream** (e.g., training-agent calls model-registry) — plain HTTP call
6. **AuthBridge intercepts** the outbound call via iptables, calls Keycloak token exchange endpoint
7. **Keycloak SPI runs** (`AgenticTokenExchangeProvider`):
   - **Act-claim injection**: Records `{ sub: training-agent, act: { sub: orchestrator } }` — who's acting on behalf of whom
   - **Scope narrowing**: Intersects requested scopes with what this client is allowed → prevents privilege escalation
8. **AuthBridge** puts the new scoped token in the Authorization header, forwards to downstream
9. **Downstream agent** (model-registry) checks scopes in token — allows or denies the operation

### What is NOT involved

- **MCP Gateway** — only for MCP tool servers, NOT for A2A agent routing
- **Custom orchestrator** — Kagenti Backend + control plane IS the orchestrator
- **Agent-to-agent config** — no hardcoded host rules; AuthBridge routes + Keycloak scopes handle everything

---

## Architecture

```
                    Kagenti Backend (FastAPI)
                           │
              ┌────────────┼────────────────┐
              ▼            ▼                 ▼
         data-agent   training-agent    eval-agent  ...
        (read:features) (write:model-registry)
              │            │
              └─────┬──────┘
                    ▼
             model-registry
          (enforces scopes on writes)
```

- **No custom orchestrator.** Kagenti Backend discovers agents and routes requests.
- **AuthBridge sidecars** (injected by webhook) handle RFC 8693 token exchange transparently.
- **Keycloak SPI** handles act-claim injection and scope narrowing (ported from Klaviger).
- **AgentCard CRDs** enable dynamic discovery — no hardcoded agent-to-agent mappings.
- **Trust graph UI** built from infrastructure signals (Keycloak events + Kiali topology).

---

## Repository Structure

```
/home/claude/ttg/
├── agent/                          # Single Python A2A agent codebase (all 4 pipeline agents)
│   ├── Dockerfile
│   ├── pyproject.toml
│   └── src/ml_agent/
│       ├── __init__.py
│       ├── agent.py                # A2A server, AgentCard from env vars
│       └── executor.py             # AgentExecutor — identity info, downstream calls
│
├── model-registry/                 # Resource server with scope enforcement
│   ├── Dockerfile
│   ├── pyproject.toml
│   └── src/model_registry/
│       ├── __init__.py
│       └── server.py               # A2A agent + POST /write scope check
│
├── keycloak-spi/                   # Port from Klaviger — act-claim + scope narrowing
│   ├── pom.xml
│   ├── Dockerfile
│   └── src/main/java/dev/kagenti/demo/keycloak/
│       ├── AgenticTokenExchangeProvider.java
│       └── AgenticTokenExchangeProviderFactory.java
│
├── trust-graph-ui/                 # Plain HTML/JS + D3 visualization
│   ├── Dockerfile
│   ├── index.html                  # D3 trust graph + delegation chain viewer
│   ├── app.js                      # Fetches Keycloak events + Kiali graph, correlates
│   ├── styles.css
│   └── backend.py                  # Thin Python backend aggregating KC + Kiali APIs
│
├── k8s/
│   ├── classic/                    # Shared identity, no auth (Break 1 + Break 2)
│   │   ├── namespace.yaml
│   │   ├── rbac.yaml               # Single shared ServiceAccount
│   │   └── deployments.yaml        # All agents, model-registry AUTH_MODE=none
│   │
│   └── agentic/                    # Individual identities, AuthBridge, scope narrowing
│       ├── namespace.yaml          # Labels for Istio ambient + Kagenti
│       ├── rbac.yaml               # Per-agent ServiceAccounts
│       ├── deployments.yaml        # Agents with kagenti.io/type labels
│       ├── services.yaml           # ClusterIP services per agent
│       └── authbridge-routes.yaml  # ConfigMap: host → audience + scopes
│
├── scripts/
│   ├── setup.sh                    # Master: calls setup-kagenti.sh + demo-specific setup
│   ├── build-images.sh             # Build + load images into Kind
│   ├── deploy-classic.sh           # Deploy classic-ml namespace
│   ├── deploy-agentic.sh           # Deploy agentic-ml namespace + Keycloak config
│   ├── configure-keycloak.sh       # Realm, clients, scopes, audience mappers (REST API)
│   └── test-demo.sh               # Automated Break 1/2 verification + fix verification
│
├── plan.md                         # This file
└── README.md
```

---

## Implementation Steps

### Step 1: Project Scaffolding
- Initialize git repo at `/home/claude/ttg`
- Create directory structure
- Create root README.md

### Step 2: Keycloak SPI (Port from Klaviger)
Port from `/home/claude/klaviger/demo/keycloak-spi/`:
- `AgenticTokenExchangeProvider.java` — act-claim injection + scope narrowing (205 lines, direct port)
- `AgenticTokenExchangeProviderFactory.java` — SPI factory (48 lines, direct port)
- `pom.xml` — Keycloak 26.5.2, Java 21
- `Dockerfile` — Multi-stage: Maven build → Keycloak 26.5.2 base with SPI JAR
- SPI service loader file under `META-INF/services/`

**Key gotcha:** Base image MUST be `quay.io/keycloak/keycloak:26.5.2` (not nightly).

### Step 3: ML Pipeline Agent (Single Codebase)
One Python A2A SDK agent, differentiated by environment variables:

**`agent.py`** — A2A server setup:
- Build `AgentCard` from env vars: `AGENT_NAME`, `AGENT_SKILLS`, `AGENT_CAPABILITIES`, `AGENT_DESCRIPTION`
- Create `A2AStarletteApplication` with the card
- Serve `/.well-known/agent-card.json`
- Run with uvicorn on `HOST:PORT`

**`executor.py`** — `AgentExecutor` implementation.
The A2A SDK routes incoming requests to `executor.execute()`. This is "what the agent does when it receives work." Without it, the A2A server accepts requests but has nothing to execute.
- `execute(context, event_queue)`:
  1. **Reports identity** — decodes the JWT from the Authorization header to extract: who is the subject (alice), who is acting (the previous agent in the delegation chain via `act` claim), what scopes the token carries, what audience it targets
  2. **Calls downstream** — if `DOWNSTREAM` env var set, makes HTTP calls to other agents. AuthBridge sidecar intercepts these outbound calls and performs token exchange transparently.
  3. **Tests model-registry write** — if `MODEL_REGISTRY_URL` set, attempts a write to demonstrate scope narrowing (allowed for training-agent which has `write:model-registry`, denied for data-agent which only has `read:features`)
  4. **Emits result** — returns identity info + downstream results + write test outcome as a JSON artifact via `TaskUpdater`
  - Authorization header is forwarded on all outbound calls (AuthBridge intercepts and exchanges)

**`pyproject.toml`** dependencies:
- `a2a-sdk>=0.3.26`
- `uvicorn`
- `httpx` (for downstream calls)

**`Dockerfile`**: Python 3.12, non-root user 1001

**Env vars per agent (set in K8s manifests):**

| Agent | AGENT_NAME | AGENT_SKILLS | AGENT_CAPABILITIES |
|-------|-----------|-------------|-------------------|
| data-agent | data-agent | data-loading,preprocessing | read:features |
| training-agent | training-agent | model-training | write:model-registry,provision:gpu |
| eval-agent | eval-agent | model-evaluation | read:test-data |
| deploy-agent | deploy-agent | model-deployment | deploy:staging |

### Step 4: Model Registry
Separate A2A agent that also acts as a resource server:
- Serves `/.well-known/agent-card.json` (A2A compliant)
- `GET /models` — list stored models
- `POST /write` — write model entry, enforces `write:model-registry` scope
- `AUTH_MODE` env var: `none` (classic) or `check-scope` (agentic)
- JWT decoding from Authorization header (unverified — display/scope-check only)
- In-memory storage (demo)

### Step 5: Kubernetes Manifests — Classic Namespace
Port from Klaviger `demo/k8s/classic/`:
- Namespace `classic-ml`
- Single shared `ml-pipeline-sa` ServiceAccount
- 5 agent Deployments + model-registry, all sharing the SA
- Model-registry with `AUTH_MODE=none`
- No Kagenti labels, no AuthBridge injection
- **Shows Break 1** (shared identity) and **Break 2** (over-permissioned writes)

### Step 6: Kubernetes Manifests — Agentic Namespace
- Namespace `agentic-ml` with labels:
  - `istio.io/dataplane-mode: ambient`
  - `kagenti.io/inject: enabled` (for AuthBridge webhook)
- Per-agent ServiceAccounts (6 total)
- Deployments with labels:
  - `kagenti.io/type: agent`
  - `protocol.kagenti.io/a2a: ""`
  - AuthBridge webhook auto-injects sidecars (envoy-proxy, proxy-init, client-registration, spiffe-helper)
- Services (ClusterIP) per agent
- `authbridge-routes` ConfigMap:
  ```yaml
  - host: "model-registry"
    target_audience: "model-registry"
    token_scopes: "openid read:features write:model-registry"
  - host: "data-agent"
    target_audience: "data-agent"
    token_scopes: "openid read:features"
  - host: "training-agent"
    target_audience: "training-agent"
    token_scopes: "openid write:model-registry provision:gpu"
  ```
  Scope narrowing happens at Keycloak SPI level — routes request broad scopes, SPI narrows per-client.
- Model-registry with `AUTH_MODE=check-scope`

### Step 7: Keycloak Configuration Scripts
Port + adapt from Klaviger `demo/scripts/configure-keycloak.sh`:
- Create `demo` realm, `alice/demo` user
- Create client scopes: `read:features`, `write:model-registry`, `provision:gpu`, `read:test-data`, `write:eval-reports`, `deploy:staging`
- Create audience scopes: `aud:data-agent`, `aud:training-agent`, etc.
- Create per-agent Keycloak clients with `federated-jwt` auth
- Set attributes via REST API (not kcadm — kcadm has attribute bug in KC 26.5.2):
  - `jwt.credential.issuer=kubernetes`
  - `jwt.credential.sub=system:serviceaccount:agentic-ml:{agent}`
  - `standard.token.exchange.enabled=true`
- Add audience mappers per client
- Assign scopes to clients (capability scopes vary per agent, audience scopes for all)
- **Never send `client_id` alongside `client_assertion`**

### Step 8: Setup Scripts
**`setup.sh`** — Master script:
1. Clone/pull Kagenti repo (if not local)
2. Run `scripts/kind/setup-kagenti.sh --with-istio --with-spire --with-kiali --with-otel`
3. Build demo images (`build-images.sh`)
4. Deploy classic namespace (`deploy-classic.sh`)
5. Deploy agentic namespace (`deploy-agentic.sh` — includes Keycloak SPI + config)
6. Run verification (`test-demo.sh`)

**`build-images.sh`**:
- Build `demo-ml-agent:latest` from `agent/`
- Build `demo-model-registry:latest` from `model-registry/`
- Build `keycloak-agentic-spi:latest` from `keycloak-spi/`
- Build `trust-graph-ui:latest` from `trust-graph-ui/`
- Load all into Kind cluster

**`deploy-agentic.sh`**:
1. Apply namespace + RBAC
2. Deploy Keycloak with SPI (custom image, replaces default KC)
3. Run `configure-keycloak.sh`
4. Apply AuthBridge routes ConfigMap
5. Apply agent Deployments + Services
6. Wait for readiness + AgentCard CRD auto-creation by operator

### Step 9: Trust Graph UI
**Backend** (`backend.py` — Python FastAPI):
- `GET /api/trust-graph` — builds the trust graph from cryptographically grounded data (see "Trust Graph Data" section above):
  1. **Layer 1 — Keycloak admin API**: `GET /admin/realms/demo/events?type=TOKEN_EXCHANGE` — returns individual token exchange events with verified `clientId` (source agent), `audience` (target agent), `scope` (scopes granted), `time` (epoch ms). This is the authoritative source — `clientId` is verified via federated-jwt authentication, not self-reported headers.
  2. **Layer 2 — Istio/Envoy OTel spans**: Per-request spans from sidecars with source workload, destination, trace ID, HTTP status, duration. Correlated to Keycloak events via trace ID when available, falling back to Kiali aggregated graph.
  3. **Layer 3 — MLflow traces** (optional): If agents tag their MLflow runs with `trust.run_id`, the backend enriches nodes with agent-internal detail (LLM calls, tool invocations).
  4. **Edge classification**:
     - `authenticated` — Keycloak token exchange event exists with verified delegation chain
     - `unauthenticated` — network traffic with no corresponding token exchange = no delegation proof
     - `denied` — token exchange succeeded but downstream returned 403 (scope enforcement)
  5. **Stats**: response includes event counts, correlation metrics, and layer availability
- Serves static files (index.html, app.js, styles.css)

**Frontend** (`index.html` + `app.js` + `styles.css`):
- D3 force-directed graph showing agents as nodes
- Edges show delegation direction + scopes at each hop
- Color-coding: green = scope granted, red/dashed = scope denied
- Tooltip on edges: full act-claim chain, scope narrowing details, reason for denial
- Auto-refresh every 10 seconds
- Legend explaining the visualization

### Step 10: Test Script
**`test-demo.sh`** — automated verification:
1. Classic namespace: call data-agent `/api/info` → shows shared SA (Break 1)
2. Classic namespace: data-agent writes to model-registry → succeeds (Break 2)
3. Agentic namespace: login as alice, get token
4. Agentic namespace: call training-agent → token exchange, model-registry write succeeds
5. Agentic namespace: call data-agent → token exchange, model-registry write denied (scope narrowing works)
6. Verify AgentCards exist: `kubectl get agentcards -n agentic-ml`
7. Verify trust graph UI shows delegation chain

---

## Key Differences from Klaviger Demo

| Aspect | Klaviger | Kagenti Rebuild |
|--------|---------|----------------|
| Agent discovery | Hardcoded ConfigMaps | AgentCard CRDs + `/.well-known/agent-card.json` |
| Orchestration | Custom Python orchestrator agent | Kagenti Backend (FastAPI) routes to agents |
| Token exchange | Klaviger forward proxy (HTTP_PROXY) | AuthBridge sidecar (iptables interception) |
| Identity | Klaviger sidecar JWT validation | SPIFFE/SPIRE via Istio + AuthBridge |
| Routing config | Per-agent ConfigMap with hostRules | Namespace-level AuthBridge routes ConfigMap |
| Agent comms | Direct HTTP via Klaviger proxy | A2A protocol |
| Trust graph | No visualization | Custom D3 UI correlating Keycloak + Kiali |
| Agent code | Custom HTTP server (no framework) | A2A SDK (A2AStarletteApplication) |

---

## Trust Graph Data: Correlation, Spoofing, and Cryptographic Grounding

### The problem with timestamp correlation

The initial approach in `backend.py` correlated two independent event streams — Keycloak TOKEN_EXCHANGE events and Envoy/OTel access logs — using timestamp proximity within a 2-second window. At machine speed with unique source+target pairs, this works for a single-user demo. But it breaks in real-world multi-agent, multi-tenant scenarios:

- **Concurrent requests**: Two requests hitting the same `training-agent → model-registry` path within the 2s window produce ambiguous matches
- **Multi-tenant**: Multiple users (Alice and Bob) triggering the same pipeline simultaneously → false cross-correlation
- **Retries and caching**: AuthBridge may cache tokens, so Keycloak event count ≠ access log count → unmatched edges in both directions
- **Scale**: At 100+ agents with fan-out patterns, the number of candidate matches per window grows combinatorially

Timestamp correlation is fundamentally a heuristic — it guesses which events belong together. We need a deterministic link.

### Prior art: trust-graph-otel and trust-graph-extproc

The earlier prototypes (`/home/claude/trust-graph-otel`, `/home/claude/trust-graph-extproc`) solved this with a **header propagation approach**:

1. **Ingress gateway** stamps immutable headers: `x-request-id` (becomes the `run_id`), `x-principal-id` (from OAuth token)
2. **Envoy sidecars** mutate `x-caller-id` and `x-trust-hop-kind` at each outbound hop
3. **Custom OTel tags** on every span: `trust.run_id`, `trust.source`, `trust.target`, `trust.hop_kind`, `trust.principal_id`
4. **Lineage Service** queries Jaeger by `trust.run_id` → gets ALL spans for that request flow → builds the DAG from span attributes

No timestamp correlation needed. The `run_id` is the deterministic correlation key — all spans for one request share it. The DAG is built from `trust.source` / `trust.target` attributes, not from matching independent event sources.

**But this approach is subject to header spoofing.** Any agent can set `x-caller-id: admin` or forge `x-request-id` to pollute trace correlation. The trust-graph-otel docs flagged this as a known vulnerability.

### Kagenti's advantage: cryptographically grounded trust data

In the Kagenti architecture, the trust data we need for the graph already exists in non-spoofable form. We don't need to trust application-set headers for identity or delegation — we have cryptographic proof:

| Source | Why it's trustworthy | What it gives us |
|--------|---------------------|------------------|
| **Keycloak TOKEN_EXCHANGE events** | Client authenticated via `federated-jwt` — K8s SA token signed by API server | Who exchanged (`clientId`), for whom (`audience`), what scopes granted |
| **JWT `act` claims** | Token signed by Keycloak's RSA private key | Full delegation chain: `{sub: training-agent, act: {sub: orchestrator, act: {sub: alice}}}` |
| **SPIFFE/SPIRE identity** (Istio mTLS) | Pod SVID issued by SPIRE, verified via mTLS handshake | `x-forwarded-client-cert` with SPIFFE URI — set by Envoy from TLS cert, not by application code |
| **K8s ServiceAccount token** | Signed by K8s API server | `system:serviceaccount:agentic-ml:training-agent` — unforgeable pod identity |

The delegation chain is cryptographically proven end to end: Keycloak won't issue a token with an `act` claim unless the client authenticated with a valid K8s SA JWT. No agent can fake that. The SPI intersects scopes against what Keycloak has configured for the client — an agent can't request scopes it wasn't granted.

### The revised approach: three layers

```
┌────────────────────────────────────────────────────────────────────┐
│  Layer 1: Trust DAG (cryptographic — non-spoofable)               │
│                                                                    │
│  Source: Keycloak TOKEN_EXCHANGE events + signed JWT act claims    │
│  Gives:  Who delegated to whom, what scopes granted/denied        │
│  Trust:  Cryptographically verified — K8s SA JWT + Keycloak sig   │
└────────────────────────────────────────────────────────────────────┘
                              │
                              │ correlated via trace ID
                              │ (spoofable but harmless — see below)
                              ▼
┌────────────────────────────────────────────────────────────────────┐
│  Layer 2: Network topology (infrastructure — zero instrumentation)│
│                                                                    │
│  Source: Istio/Envoy OTel spans with traceparent propagation      │
│  Gives:  HTTP-level call graph, latencies, status codes           │
│  Trust:  Sidecar-generated, not application-settable              │
└────────────────────────────────────────────────────────────────────┘
                              │
                              │ correlated via trace ID
                              │ (automatic — sidecar forwards traceparent to agent)
                              ▼
┌────────────────────────────────────────────────────────────────────┐
│  Layer 3: Agent runtime (framework observability — optional)      │
│                                                                    │
│  Source: MLflow / Langfuse / OpenLLMetry traces                   │
│  Gives:  LLM calls, tool invocations, reasoning steps            │
│  Trust:  Self-reported by agent (best-effort enrichment)          │
│  Link:   Automatic — OTel auto-instrumentation inherits trace ID │
│          from traceparent forwarded by sidecar, zero agent changes│
└────────────────────────────────────────────────────────────────────┘
```

**Layer 1** is the source of truth — it's what the trust graph is built from. It answers: "who acted on behalf of whom, with what permissions?"

**Layer 2** enriches with network-level detail (latency, HTTP status, call patterns). Istio sidecars generate these spans — agents can't forge them. The `traceparent` header propagated by Istio links spans to a single request flow, but even if an agent spoofs `traceparent`, the worst outcome is messy traces, not privilege escalation.

**Layer 3** is purely optional. It shows what happened *inside* the agent — LLM calls, tool invocations, reasoning steps. Without it, the graph still works; you just don't see agent-internal detail.

### Zero agent instrumentation — the sidecar does everything

A key advantage of Kagenti's architecture: **AuthBridge is an Envoy-based sidecar injected per agent.** It already sits in the request path for both inbound (JWT validation) and outbound (token exchange) traffic. This means the sidecar — not the agent — can handle all trust metadata propagation:

**Inbound path** (request arrives at agent):
```
Request with traceparent + JWT
        │
  AuthBridge sidecar (Envoy)
  ├─ Validates JWT (already does this)
  ├─ Reads act claims, scopes, audience from token
  ├─ Reads traceparent from Istio mesh
  ├─ Emits OTel span with:
  │     trust.source = JWT act.sub (caller)
  │     trust.target = own pod identity (SPIFFE/SA)
  │     trust.scopes = token scopes
  │     trust.principal = root subject in act chain
  │     trace_id = from traceparent
  └─ Forwards request to agent container (with traceparent intact)
```

**Outbound path** (agent calls downstream):
```
Agent makes plain HTTP call to downstream
        │
  AuthBridge sidecar intercepts (iptables)
  ├─ Performs RFC 8693 token exchange (already does this)
  ├─ Gets back new JWT with updated act chain + narrowed scopes
  ├─ Emits OTel span with:
  │     trust.source = own identity
  │     trust.target = downstream agent
  │     trust.scopes_requested = what was asked for
  │     trust.scopes_granted = what Keycloak returned
  │     trust.act_chain = full delegation chain from new token
  │     trace_id = propagated from inbound traceparent
  └─ Forwards request to downstream with new JWT + traceparent
```

**Result**: The complete trust DAG — delegation chains, scope narrowing, deny/allow decisions — is captured entirely by the sidecar infrastructure. The agent code is untouched. Not even one line.

**Layer 3 linking is also automatic**: The sidecar forwards `traceparent` to the agent container. If the agent uses any OTel auto-instrumented framework (Python OTel auto-instrumentation, MLflow's OTel integration, Langfuse), its internal spans automatically become children of the same trace. No manual `mlflow.set_tag("trust.run_id", ...)` needed — the trace context is already there from the sidecar.

```
Trace abc123:
  ├─ [sidecar] inbound: alice → training-agent (scopes: write:model-registry)
  │   └─ [agent/MLflow] LLM call: "evaluate model quality"        ← auto-linked
  │   └─ [agent/MLflow] tool: compute_metrics()                   ← auto-linked
  ├─ [sidecar] outbound: training-agent → model-registry (scope narrowing)
  │   └─ [sidecar] inbound at model-registry: training-agent → model-registry
```

The entire three-layer picture — delegation chain, network topology, and agent runtime — shares one trace ID, and zero lines of agent code were modified to achieve it.

### Propagation mechanism: W3C Baggage vs Custom Headers

There are two ways to carry trust metadata through the request chain. Both are spoofable (the security boundary is Keycloak, not headers — see below), so the choice is about engineering tradeoffs.

**Option A: W3C Baggage propagation**

Standard OTel mechanism. Trust metadata rides alongside `traceparent` in the `baggage` header:

```
traceparent: 00-<trace-id>-<span-id>-01
baggage: trust.principal=alice,trust.run_id=<trace-id>
```

OTel SDKs, Istio, and Envoy propagate both headers automatically. Agents using OTel-instrumented HTTP clients (httpx, requests) emit child spans under the same trace without any manual wiring.

| | Pros | Cons |
|--|------|------|
| **Standards** | W3C standard — any OTel-aware component understands it | Baggage spec limits values to ASCII, URL-encoded, 8192 bytes total |
| **Propagation** | Automatic through OTel SDK + Istio — zero config per agent | Requires OTel SDK in the agent runtime (or Istio auto-propagation) |
| **Correlation** | Agent spans automatically share the same trace ID | If agent doesn't use OTel SDK, baggage is silently dropped |
| **Ecosystem** | Works with Jaeger, Tempo, Zipkin, any OTel-compatible backend | Baggage is visible to every service in the chain — information leakage risk for sensitive metadata |
| **Runtime linking** | Agent can read baggage to tag MLflow runs — one line of code | Istio ambient mode baggage propagation support varies by version |

**Option B: Custom `x-trust-*` headers**

What trust-graph-otel used. Explicit headers managed by Envoy Lua filters at each hop:

```
x-request-id: 550e8400-...
x-principal-id: user:alice
x-caller-id: agent:training-agent
x-trust-hop-kind: agent_to_agent
```

| | Pros | Cons |
|--|------|------|
| **Control** | Full control over what's propagated — Lua filters set/mutate per hop | Must write and maintain Lua/ext_proc filters for every sidecar config |
| **No SDK dependency** | Works with any HTTP client — just headers | Agent must manually forward headers on outbound calls (or sidecar must re-inject) |
| **Visibility** | Can choose exactly which headers cross trust boundaries | Non-standard — every consumer must know the custom header schema |
| **Mutability** | Can have immutable headers (principal) and mutable ones (caller) in same request | Envoy header mutation ordering can be subtle — Lua filter execution order matters |
| **Runtime linking** | Agent reads `x-request-id` to tag MLflow runs | More plumbing code than baggage — parsing headers vs reading OTel context |

**Recommendation for Kagenti**: Use W3C Baggage where the infrastructure supports it (Istio + OTel collector). The baggage header gives us trace-correlated propagation for free, and the agent can read the trace context to link MLflow runs. Fall back to custom headers only for metadata that needs per-hop mutation (like `x-caller-id`), which is better handled by sidecars anyway.

Both approaches share the same spoofing characteristics — neither is a security boundary. The security boundary is the signed token chain (see next section).

### Why spoofable trace context is harmless

The `traceparent` / `x-request-id` header flows through Istio and is technically modifiable by application code. But spoofing it doesn't help an attacker:

- **Authorization is enforced by signed JWTs**, not by trace context. An agent can't get broader scopes by forging headers.
- **The trust DAG is built from Keycloak events**, not from trace-propagated headers. A forged `x-caller-id` doesn't appear in the Keycloak event log — the authenticated `clientId` does.
- **Worst case**: A rogue agent corrupts its own trace lineage, making the observability graph messy for that request. It cannot forge delegation chains, elevate privileges, or impersonate other agents.
- **Defense in depth**: Envoy's `x-forwarded-client-cert` (extracted from mTLS handshake, not settable by application code) provides cryptographic source identity that can cross-validate against Keycloak's `clientId`. Both inbound and outbound sidecars emit spans for the same hop — a forged header on one side won't match the other.

In short: trace context is a convenience for correlation, not a security boundary. The security boundary is the signed token chain.

### What the trust graph backend actually queries

```python
# Layer 1: Cryptographic trust data (always available, authoritative)
kc_events = await get_token_exchange_events()
# Each event has: clientId (verified via federated-jwt), audience, scope, act claims, timestamp

# Layer 2: Network topology (always available, sidecar-generated)
infra_spans = await get_infra_spans(trace_id)
# Spans from Envoy with HTTP method, status, latency — not application-settable

# Layer 3: Agent runtime (automatic if agent uses OTel-instrumented framework)
mlflow_spans = await get_child_spans(trace_id, service="training-agent")
# Child spans under same trace — auto-linked via traceparent forwarded by sidecar
```

The DAG is built from Layer 1. Layers 2 and 3 enrich the nodes and edges with operational and runtime detail. All three layers share the same trace ID, and zero agent code changes are needed for any of them.

---

## Verification (Success Criteria)

1. `setup.sh` brings up full stack from scratch on Kind
2. Classic namespace shows Break 1 (shared identity) and Break 2 (data-agent writes to model-registry)
3. Agentic namespace shows scope-narrowed token exchange at all hops
4. Trust graph UI shows live delegation chain with scopes at each hop
5. `kubectl get agentcards -n agentic-ml` shows dynamically discovered agents
6. Adding a new agent via Deployment + labels makes it discoverable without config changes
7. No agent code contains tracing/observability instrumentation

---

<details>
<summary><strong>2026-05-07 — Gap Analysis: What's Missing or Drifted</strong></summary>

### Current cluster state

Kind cluster `kagenti` running with Podman. 24 namespaces. Kagenti controller manager recovered after `fs.inotify.max_user_instances` increased from 128 → 1024 (was in CrashLoopBackOff for 12h). Webhook controller in `kagenti-webhook-system` had 73 restarts but is now running.

All 5 agents + model-registry deployed in both `classic-ml` and `agentic-ml` namespaces. Trust Graph UI deployed and functional with static DAG layout. Keycloak configured with demo realm, 5 agent clients, 6 capability scopes, audience mappers, alice user, TOKEN_EXCHANGE events enabled.

### 1. Keycloak SPI (Step 2) — NOT DEPLOYED

The SPI source exists in `keycloak-spi/` (ported from Klaviger) but the Keycloak pod is running **stock** `quay.io/keycloak/keycloak` — not the custom image with the SPI JAR baked in. Without it:
- No act-claim injection (delegation chain not recorded in tokens)
- No scope narrowing at the Keycloak level (intersection of requested vs allowed scopes)

**To fix:** Build `keycloak-agentic-spi:latest` image, push to in-cluster registry, update the Keycloak StatefulSet to use the custom image, restart.

### 2. AuthBridge sidecars (Step 6) — NOT INJECTED

All agentic-ml pods are `1/1 Ready` (no sidecar container). The plan requires AuthBridge sidecars for transparent token exchange on outbound calls.

- Namespace has `kagenti-enabled: true` but no `kagenti.io/inject` label
- No `authbridge-routes` ConfigMap exists (defines host → audience + scope mappings)
- No `Agent` CRs exist — the webhook watches Agent CRDs, not raw pods
- The webhook controller was crash-looping (inotify) for 12h; now recovered

**To fix:** Create Agent CRs for each agent in `agentic-ml` → operator creates deployments with AuthBridge sidecars injected. Create `authbridge-routes` ConfigMap with host/audience/scope mappings.

### 3. Agent CRs and AgentCards (Steps 6, 10) — NONE EXIST

- `kubectl get agents --all-namespaces` → empty
- `kubectl get agentcards --all-namespaces` → empty
- Plan says operator auto-creates AgentCards from Agent CRs
- We bypassed the operator by creating plain Deployments manually
- Verification criterion #5 (`kubectl get agentcards -n agentic-ml`) will fail

**To fix:** Define Agent CRs for each of the 5 agents. The operator should create deployments with sidecars and register AgentCards for discovery.

### 4. Keycloak client auth — DRIFTED from federated-jwt to client-secret

Plan specifies `federated-jwt` authentication (K8s ServiceAccount token → Keycloak). We changed all agent clients to `client-secret` auth because the custom SPI isn't deployed and stock Keycloak doesn't support the `federated-jwt` authenticator.

Impact: `clientId` in Keycloak events is verified by shared secret, not cryptographic K8s SA identity. The "cryptographically grounded" claim in the plan requires federated-jwt.

**To fix:** Deploy the Keycloak SPI (fixes #1), then switch clients back to `federated-jwt` with `jwt.credential.issuer=kubernetes` and `jwt.credential.sub=system:serviceaccount:agentic-ml:{agent}`.

### 5. Token exchange flow — SIMULATED, NOT REAL

`run-demo-pipeline.sh` performs token exchanges manually from a Python script using client secrets and direct Keycloak API calls. The plan says AuthBridge sidecars intercept outbound HTTP calls transparently via iptables and perform token exchange automatically.

Currently: agents make plain HTTP calls with no interception. The trust graph edges come from the simulation script, not from real agent-to-agent traffic.

**To fix:** Once AuthBridge sidecars are injected (#2), agent outbound calls will be intercepted. The pipeline script can then be replaced by actual agent-to-agent A2A calls through alice → Kagenti Backend → agents.

### 6. No Jaeger / trace query backend — Layer 2 unqueryable

OTel collector exists (`otel-collector.kagenti-system:4317/4318/8335`) but no Jaeger or Tempo for querying spans. The `observability` namespace is empty. Even if sidecars were emitting OTel spans, there's no query API to retrieve them.

The trust graph backend has code to query Jaeger (`get_service_spans()`) but it returns empty because Jaeger isn't deployed.

**To fix:** Deploy Jaeger (or Tempo) in the `observability` namespace, configure OTel collector to export to it, update trust graph backend's `JAEGER_URL` env var.

### 7. Trust Graph UI — architecture drift

Plan says the backend correlates Layer 1 (Keycloak events) + Layer 2 (sidecar OTel spans) + Layer 3 (MLflow) via shared trace_id. Current backend:
- Only queries Keycloak events (Layer 1)
- Has stub code for Jaeger/Kiali queries that return empty
- Does timestamp-based enrichment (the approach the plan explicitly criticizes)
- No trace_id correlation, no per-run grouping
- Token exchanges are merged by (source, target) pair across all sessions

**To fix:** Once Jaeger is deployed (#6) and sidecars emit spans (#2), update backend to query spans by trace_id and group edges into runs.

### Priority order

1. Deploy Keycloak SPI (custom image) → act-claims + scope narrowing
2. Create Agent CRs → AuthBridge sidecar injection
3. Deploy Jaeger → Layer 2 span query capability
4. Switch to federated-jwt auth → cryptographic identity
5. Update trust graph backend → trace_id correlation, per-run grouping

</details>

---

## 2026-05-07 — Pipeline Creation UI Design

### Context

Alice can log into Kagenti UI and see the 5 deployed agents, but there's **no way to create and execute pipelines** that chain agents together to demonstrate trust graph delegation flows. Currently, pipelines are hardcoded via environment variables (`DOWNSTREAM`) and AuthBridge routes.

**Goal:** Add a pipeline creation UI that allows Alice to:
1. Select agents to chain together
2. Execute the pipeline (triggering token exchanges)
3. View resulting delegation chains in the trust graph

### Architecture Decision

**Extend the existing trust-graph-ui** with a new "Pipeline Builder" tab:
- Reuses vanilla JS + D3.js stack (no framework change)
- Backend-orchestrated execution (critical for token exchange through AuthBridge)
- Seamless integration with trust graph visualization

**Why not a separate app?**
- Would duplicate auth setup and backend logic
- Harder to highlight pipeline results in trust graph
- User would switch between 2 UIs

**Why backend orchestration?**
- Browser cannot reach K8s cluster services
- Must ensure tokens flow through AuthBridge sidecars
- Backend already has Keycloak admin API access

### UI Design

```
┌─────────────────────────────────────────────────┐
│  Trust Graph  |  Pipeline Builder     ← New tabs│
├─────────────────────────────────────────────────┤
│  [Available Agents]          [Pipeline Steps]   │
│  ┌──────────────────┐        ┌───────────────┐  │
│  │☐ data-agent      │   →    │ 1. data-agent │  │
│  │☐ training-agent  │        │ 2. training...│  │
│  │☐ eval-agent      │        │ 3. model-reg..│  │
│  │☐ deploy-agent    │        └───────────────┘  │
│  │☐ model-registry  │                           │
│  └──────────────────┘                           │
│  [Run Pipeline]  [Clear]  [Load Template]       │
├─────────────────────────────────────────────────┤
│  Execution Log:                                 │
│  ✓ alice → data-agent (200, 145ms)              │
│  ✓ data-agent → training-agent (200, 230ms)     │
│  ✓ training-agent → model-registry (200, 180ms) │
│  [View in Trust Graph]                          │
└─────────────────────────────────────────────────┘
```

**Pipeline format:** Linear chain (array of agent names)
- v1: `["data-agent", "training-agent", "model-registry"]`
- Future: DAG with branches

### Backend API

Add 3 endpoints to `/home/claude/ttg/trust-graph-ui/backend.py`:

**1. `GET /api/agents`** — Discover available agents
```python
{
  "agents": [
    {
      "name": "data-agent",
      "skills": ["data-loading", "preprocessing"],
      "capabilities": ["read:features"],
      "url": "http://data-agent.agentic-ml.svc.cluster.local:8000"
    },
    # ... other agents
  ]
}
```

**2. `POST /api/pipelines/execute`** — Execute pipeline with Alice's token
```python
# Request
{"pipeline": ["data-agent", "training-agent", "model-registry"]}

# Response
{
  "run_id": "abc-123",
  "status": "completed",
  "steps": [
    {"agent": "data-agent", "status": 200, "duration_ms": 145, "event_ids": [...]},
    {"agent": "training-agent", "status": 200, "duration_ms": 230, "event_ids": [...]},
  ],
  "total_duration_ms": 375,
  "keycloak_events": ["kc-evt-001", "kc-evt-002"]
}
```

**3. `GET /api/pipelines/templates`** — Pre-defined pipelines
```python
{
  "templates": [
    {
      "name": "Training Pipeline",
      "steps": ["data-agent", "training-agent", "model-registry"]
    },
    {
      "name": "Full ML Pipeline",
      "steps": ["data-agent", "training-agent", "eval-agent", "deploy-agent"]
    }
  ]
}
```

### Execution Flow

```
1. User clicks "Run Pipeline" in browser
2. Browser POSTs to /api/pipelines/execute with agent list
3. Backend:
   a. Obtains Alice token via Keycloak password grant
      POST /realms/demo/protocol/openid-connect/token
      (grant_type=password, client_id=demo-dashboard, username=alice)
   
   b. For each agent in chain:
      - POST to http://{agent}.agentic-ml.svc.cluster.local:8000/api/run-pipeline
      - Include Authorization: Bearer {alice_token}
      - AuthBridge sidecar intercepts, performs RFC 8693 token exchange
      - Keycloak SPI injects act-claim and narrows scopes
      - Generates TOKEN_EXCHANGE event
   
   c. Returns execution trace to browser
4. Browser displays execution log
5. Trust graph auto-refreshes to show new edges
```

**No agent code changes needed**: Agents already support `/api/run-pipeline` endpoint (see executor.py:137)

### Implementation Files

**New files:**
- `/home/claude/ttg/trust-graph-ui/pipeline-builder.js` (~250 lines)

**Modified files:**
- `/home/claude/ttg/trust-graph-ui/index.html` — add pipeline tab UI
- `/home/claude/ttg/trust-graph-ui/backend.py` — add 3 endpoints (~150 lines)
- `/home/claude/ttg/trust-graph-ui/styles.css` — pipeline builder CSS (~300 lines)
- `/home/claude/ttg/trust-graph-ui/app.js` — add page tab switching (~20 lines)

### Implementation Phases

**Phase 1: Basic UI**
- Add tab navigation (Trust Graph | Pipeline Builder)
- Create pipeline-builder.js with agent selection, preview, run button
- Add CSS styling (match GitHub dark theme)
- Implement page tab switching

**Phase 2: Backend Orchestration**
- Add `/api/agents` endpoint (return AGENTS constant)
- Add `/api/pipelines/execute` endpoint:
  - Alice token acquisition (password grant)
  - Sequential agent calls with Authorization headers
  - Collect execution results (status, duration, event IDs)
- Add `/api/pipelines/templates` with 2-3 pre-defined pipelines

**Phase 3: Trust Graph Integration**
- Add "View in Trust Graph" button (switches tabs, triggers refresh)
- Auto-refresh trust graph after pipeline execution
- Highlight edges from pipeline run using event IDs

**Phase 4: Enhancements (Optional)**
- Template dropdown UI (vs. prompt-based selection)
- Execution history (last N runs in memory)
- Scope validation warnings
- DAG builder with drag-and-drop

### Deployment

```bash
cd /home/claude/ttg/trust-graph-ui

# Build image
podman build -t trust-graph-ui:latest .

# Push to in-cluster registry
kubectl port-forward -n cr-system svc/registry 5000:5000 &
podman push --tls-verify=false localhost:5000/trust-graph-ui:latest 127.0.0.1:5000/trust-graph-ui:latest

# Restart deployment
kubectl rollout restart -n trust-graph-ui deployment/trust-graph-ui
```

No changes to agent deployments or Keycloak configuration required.

### Verification

**Manual testing (VM browser at http://localhost:9090):**
1. Click "Pipeline Builder" tab
2. Select agents: data-agent, training-agent, model-registry
3. Click "Run Pipeline"
4. Verify execution log shows 200 responses
5. Click "View in Trust Graph"
6. Verify new edges (alice → data-agent → training-agent → model-registry)
7. Click edge, verify scopes in detail panel

**Integration tests:**
```bash
# Test agent discovery
curl http://localhost:9090/api/agents | jq '.agents[].name'

# Test pipeline execution
curl -X POST http://localhost:9090/api/pipelines/execute \
  -H "Content-Type: application/json" \
  -d '{"pipeline": ["data-agent", "training-agent"]}'

# Verify trust graph updated
curl http://localhost:9090/api/trust-graph | jq '.edges | length'
```

### Trade-offs Considered

**Alternative 1: Tekton Pipelines integration**
- Pros: Production-grade orchestration
- Cons: Doesn't generate Keycloak TOKEN_EXCHANGE events, adds complexity
- Decision: Rejected — overkill for 5-agent demo

**Alternative 2: Direct browser → agent calls**
- Pros: Simpler backend
- Cons: Browser can't reach cluster services, bypasses AuthBridge
- Decision: Rejected — backend orchestration required

**Alternative 3: DAG builder first**
- Pros: More expressive
- Cons: Complex UI, demo only needs linear chains
- Decision: Start linear, add DAG in Phase 4 if needed

### Success Criteria

- Alice can build pipelines in UI without editing YAML
- Pipeline execution generates Keycloak TOKEN_EXCHANGE events
- Trust graph shows delegation chains with correct scopes
- Demo flow: login → build pipeline → run → view trust graph (< 30 seconds)
