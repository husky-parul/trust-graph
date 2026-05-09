# Kagenti IAM Demo — PyTorch Conf Europe 2026

Agentic IAM demo rebuilt on [Kagenti](https://github.com/kagenti/kagenti). Shows individual agent identities, RFC 8693 token exchange with scope narrowing, and a live trust graph.

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
