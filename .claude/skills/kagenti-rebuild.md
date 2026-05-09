# Kagenti Rebuild: Briefing for Implementation

This document briefs the implementation of the PyTorch Conf Europe 2026 demo rebuilt on Kagenti instead of Klaviger. The target is a **separate repo** — do not build inside the klaviger repo.

## Context

The current demo lives in `klaviger/demo/` and uses Klaviger sidecars with hardcoded trust relationships per agent (one ConfigMap per agent, static hostRules). It works, but the hardcoded approach undermines the talk's message about dynamic, discoverable agent identity.

The rebuilt demo should use Kagenti's native capabilities — dynamic agent discovery, SPIFFE identity, A2A protocol — so the talk can show live agent registration and a trust graph that forms organically rather than being wired by hand.

## Non-Negotiable Decisions

These are already decided. Do not revisit.

1. **Separate repo.** Not inside klaviger. Fresh repo, clean history.

2. **Python A2A SDK agents.** Agents must be A2A-compliant using the lightweight Python A2A SDK. Do NOT use LangGraph, CrewAI, or any heavyweight framework. The agents are intentionally simple — the demo is about IAM infrastructure, not agent intelligence.

3. **Dynamic agent discovery.** No hardcoded hostRules or ConfigMaps mapping agent-to-agent relationships. Agents register via AgentCard CRDs and are discovered at runtime via A2A `/.well-known/agent-card.json`. Kagenti's operator handles the lifecycle.

4. **Kagenti as orchestrator.** No custom orchestrator agent. Kagenti control plane + MCP Gateway handles routing, token exchange, and agent coordination. The orchestrator is infrastructure, not application code.

5. **No agent instrumentation for the trust graph.** The trust graph must be built entirely from infrastructure signals — not by adding tracing code to agents. Sources:
   - Envoy/Istio access logs (SPIFFE identities, caller/callee)
   - Keycloak event log (token exchange events, scopes granted, act claim chains)
   - Kiali (mesh topology, live traffic)
   - Phoenix (LLM/tool traces, only if the agent framework emits them natively)

6. **Custom trust graph UI.** A new visualization that correlates Keycloak token lineage (who delegated to whom, with what scopes) with Kiali's call graph into a unified trust graph. This is the demo's centerpiece — the audience should see delegation chains and scope narrowing visually.

7. **Runs on Kind.** Kagenti installer supports Kind via `run-install.sh --env dev`. Use this path.

8. **Keycloak SPI is still needed.** Kagenti uses Keycloak too, and the scope narrowing bug (keycloak/keycloak#29614) still applies. Reuse or adapt `klaviger/demo/keycloak-spi/` — it handles both act-claim injection and scope narrowing. Base image must be `quay.io/keycloak/keycloak:26.5.2` (NOT nightly — nightly has AbstractJWTClientValidator regression).

## Demo Scenario (Unchanged)

The demo compares classic vs agentic IAM for an ML pipeline:

- **Classic ML namespace:** All agents share one ServiceAccount. Data-agent can write to model-registry (shouldn't). Shows Break 1 (shared identity) and Break 2 (over-permissioned).

- **Agentic ML namespace:** Each agent has its own identity. Token exchange with scope narrowing. Model-registry enforces scopes on writes.

### Pipeline flow (agentic)

```
Alice → Orchestrator → Training-Agent → Model-Registry
```

Each hop: token exchange via Keycloak with audience targeting and scope narrowing. The `act` claim accumulates the delegation chain.

### Agents to implement

| Agent | Role | Scopes needed |
|-------|------|---------------|
| orchestrator | Routes pipeline requests | delegates to downstream agents |
| data-agent | Loads/preprocesses data | `read:features` on model-registry |
| training-agent | Trains models | `write:model-registry` on model-registry |
| eval-agent | Evaluates models | read-only |
| deploy-agent | Deploys models | read-only |
| model-registry | Stores models, enforces scopes | N/A (resource server) |

All agents use the same Python A2A SDK base. Differentiated by AgentCard metadata (skills, capabilities) and environment variables.

## Keycloak Configuration

Carry forward from the existing demo:

- Realm: `demo`, User: `alice/demo`
- One Keycloak client per agent
- `standard.token.exchange.enabled=true` attribute on each client (set via REST API, NOT kcadm — kcadm has a bug with attributes in KC 26.5.2)
- `aud:X` client scopes with audience mappers, assigned as defaults
- `client-auth-federated,kubernetes-service-accounts,token-exchange-standard` features enabled
- Never send `client_id` parameter alongside `client_assertion` in federated-jwt token exchange

## What Changes from the Klaviger Demo

| Aspect | Klaviger demo | Kagenti rebuild |
|--------|--------------|-----------------|
| Agent discovery | Hardcoded ConfigMaps | AgentCard CRDs, `/.well-known/agent-card.json` |
| Orchestration | Custom Python orchestrator agent | Kagenti control plane + MCP Gateway |
| Identity binding | Klaviger sidecar validates JWTs | SPIFFE/SPIRE via Istio, Kagenti operator binds AgentCards to workload identity |
| Trust graph | No visualization | Custom UI correlating Keycloak + Kiali |
| Agent comms | Direct HTTP with Klaviger proxy | A2A protocol |
| Token exchange | Klaviger forward proxy | Kagenti MCP Gateway or equivalent infra component |

## Known Gotchas to Carry Forward

- **KC 26.5.2 only** — nightly breaks `AbstractJWTClientValidator` for federated-jwt auth
- **kcadm attribute bug** — always use REST API via curl for setting client attributes
- **Audience requirements** — 5 things must all be in place (client exists, token exchange enabled, aud scope exists + assigned, audience in token exchange request)
- **Issuer mismatch** — tokens obtained via port-forwarded Keycloak have wrong issuer; get tokens from inside the cluster
- **Kind + Podman** — set `KIND_EXPERIMENTAL_PROVIDER=podman`, use `podman exec` for image loading
- **Disk space** — `podman system prune -a -f` before building images

## Success Criteria

The demo is done when:

1. `setup.sh` (or equivalent) brings up the full stack from scratch on Kind
2. Classic namespace shows Break 1 (shared identity) and Break 2 (over-permissioned writes)
3. Agentic namespace shows scope-narrowed token exchange working across all hops
4. Trust graph UI shows the live delegation chain with scopes at each hop
5. Agent discovery is fully dynamic — adding a new agent via AgentCard CRD makes it discoverable without config changes
6. No agent code contains tracing/observability instrumentation — all signals come from infrastructure
