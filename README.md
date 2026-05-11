# Trust Graph

A **delegation graph** for agent-based systems. Captures who acted on behalf of whom at every hop, establishes provenance for every action, and makes agentic behavior auditable and enforceable.

## What is Trust Graph?

When a user delegates a task to an AI agent, that agent often delegates further — calling other agents, accessing resources, making decisions on the user's behalf. The result is a **delegation chain**:

```
Principal → Agent → Agent → … → Resource
```

Trust Graph makes these chains visible and enforceable. It answers three questions:

1. **Who acted on behalf of whom?** Every delegation hop is captured as an edge in a directed acyclic graph (DAG). The full graph — the *trust graph* — shows the complete lineage of a request from principal through every agent to every resource.

2. **What were they allowed to do?** Each hop carries scoped credentials. Scopes narrow as delegation deepens — an agent can never grant more authority than it was given. The trust graph records these scopes at every edge.

3. **Was this expected?** The observed trust graph can be compared against learned baselines to detect novel edges, capability overreach, and anomalous delegation patterns.

### Design principles

- **Observe outside the trust boundary.** A compromised agent must not be able to alter its own trace data. Observation happens at the proxy/sidecar layer, not inside the agent process.
- **Zero agent instrumentation.** Agents are plain application code — HTTP, gRPC, A2A, or any protocol. They don't import tracing SDKs or stamp trust headers. The infrastructure handles all of it.
- **Implementation-agnostic.** The trust graph concept does not depend on a specific proxy, service mesh, or identity provider. The data plane changes; the trust graph does not.

### What it looks like

```
         alice
           │
           ▼
     orchestrator
       │       │
       ▼       ▼
  training   data-agent
   -agent    (read:features)
(write:model    ✗ write → denied
 -registry)
       │
       ▼
 model-registry
   ✓ write → allowed
```

Each edge carries: caller identity, callee identity, granted scopes, and the delegation chain (`act` claim) showing the full path from the original principal. The trust graph UI renders this live as requests flow.

## Our Implementation

This repo implements the trust graph on [Kagenti](https://github.com/kagenti/kagenti) + Keycloak, running on Kind.

- **Identity**: Each agent gets its own Kubernetes ServiceAccount and Keycloak client. Istio injects Envoy sidecars into every pod, providing mTLS (SPIFFE identities) and mesh telemetry.
- **Delegation**: [Kagenti AuthBridge](https://github.com/kagenti/kagenti) intercepts outbound agent calls and performs RFC 8693 token exchange against Keycloak. A custom Keycloak SPI injects `act` claims (delegation chain) and narrows scopes at each hop.
- **Observation**: Three layers, none requiring agent code changes:
  - **Layer 1 — Keycloak events** (cryptographic, authoritative): Token exchange events record who delegated to whom, with what scopes, verified by signed JWTs. This is the trust graph's source of truth.
  - **Layer 2 — Istio/Envoy OTel spans** (infrastructure, not application-settable): Network-level call graph with latency, status codes, and call patterns.
  - **Layer 3 — Agent runtime traces**: MLflow/Langfuse traces showing LLM calls and tool invocations inside agents. Linked automatically via `traceparent` forwarded by the sidecar — zero agent instrumentation needed.
- **Correlation**: AuthBridge is the bridge between layers. It sits in the request path where it sees both the Istio trace context (`traceparent`) and the Keycloak token exchange. By emitting OTel spans tagged with trust metadata (act claims, scopes, delegation chain) under the same trace ID, it gives the trust graph backend a single key to join all three layers into one DAG per request.
- **Enforcement**: Downstream services (e.g., model-registry) inspect the scoped token and allow or deny operations. Scope narrowing at the Keycloak SPI layer prevents privilege escalation.

A previous implementation ([trust-graph-dataplane](https://github.com/husky-parul/trust-graph-dataplane)) used Envoy sidecars with custom Lua filters and trust headers instead of Keycloak token exchange. The trust graph concept is the same; the infrastructure underneath changed.

## Roadmap

The current implementation captures **delegation** — who acted on behalf of whom, with what scopes. The following extensions are planned:

### Intent propagation

Today the trust graph records *what* an agent was allowed to do, but not *why*. Scopes say "read:features" — they don't say "for research purposes" or "for model retraining." We call this **loss of purpose**.

**Plan:** Add `intendedUse` and `purpose` fields to A2A Agent Cards. Carry an `intent` field in task payloads, propagated through the delegation chain alongside the `act` claim. AuthBridge already intercepts every hop — it can log intent metadata alongside the token exchange. The trust graph UI would show intent at each edge, making purpose visible across the full chain.

This builds on infrastructure we already have (Agent Cards, AuthBridge interception, token exchange events). No new components — it's metadata enrichment.

### Signed attestations

Keycloak TOKEN_EXCHANGE events are cryptographically grounded — the JWTs carrying `act` claims are signed by Keycloak's RSA key. But these are ephemeral tokens, not portable provenance records. You can't hand a JWT to an external auditor and say "prove this delegation happened."

**Plan:** Wrap delegation events into [DSSE](https://github.com/secure-systems-lab/dsse) attestation envelopes — each binding actor identity, action, declared intent, scopes, and timestamp into a signed record. Log these to an append-only store for tamper-evident auditability. This is a lightweight path toward [Sigstore](https://sigstore.dev)-compatible attestation without requiring full Sigstore infrastructure (Fulcio, Rekor) in the cluster.

### Persistent graph store

The trust graph is currently built on-the-fly from event streams — Keycloak events and OTel spans are queried, correlated, and rendered into a DAG per request. Nothing persists. You can't ask "show me all delegations from last week" or "has this agent ever accessed that resource before."

**Plan:** Persist delegation edges to a lightweight store (SQLite) as they arrive. This enables historical queries, baseline computation for anomaly detection (novel edges, capability overreach), and the explain/assess capabilities from the [trust-graph-dataplane](https://github.com/husky-parul/trust-graph-dataplane) lineage service. A production system might use a property graph (Neo4j, TerminusDB) for richer traversal queries; the demo uses SQLite to keep the component count low.

## Quick Start

```bash
# Set path to your kagenti repo clone
export KAGENTI_REPO=/path/to/kagenti

# Run full setup (Kind cluster + Kagenti platform + demo)
./scripts/setup.sh
```

## What This Demo Shows

### Classic ML Namespace (Break 1 + Break 2)
- All agents share one ServiceAccount → **Break 1**: no individual identity
- data-agent can write to model-registry → **Break 2**: over-permissioned

### Agentic ML Namespace (Fixed)
- Each agent has its own identity (ServiceAccount + Keycloak client)
- Token exchange with scope narrowing at every hop (AuthBridge + Keycloak SPI)
- data-agent write to model-registry → **denied** (only has `read:features`)
- training-agent write to model-registry → **allowed** (has `write:model-registry`)
- Trust graph UI shows live delegation chains

## Architecture

```
Alice → Kagenti UI → Kagenti Backend → A2A Agent
                                            │
                                      AuthBridge sidecar
                                      (token exchange)
                                            │
                                        Keycloak SPI
                                    (act-claim + scope narrowing)
                                            │
                                      Downstream agent
```

## Components

| Component | Description |
|-----------|-------------|
| `agent/` | Python A2A SDK agent (single codebase, all 4 pipeline agents) |
| `model-registry/` | HTTP resource server with scope enforcement |
| `keycloak-spi/` | Custom Keycloak provider for act-claims + scope narrowing |
| `trust-graph-ui/` | D3 trust graph visualization |
| `k8s/classic/` | Classic namespace manifests (shared identity) |
| `k8s/agentic/` | Agentic namespace manifests (individual identities + AuthBridge) |
| `scripts/` | Setup, deployment, and test scripts |

## Prerequisites

- [Kind](https://kind.sigs.k8s.io/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/)
- Docker or Podman
- [Kagenti](https://github.com/kagenti/kagenti) repo clone
