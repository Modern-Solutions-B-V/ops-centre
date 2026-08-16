# Downstream Fork Record — Modern Solutions ops-centre

Upstream: Osmantic/ODS
Baseline: v2.6.0 (SHA:f461b3e5e6e3f21077eefb6ca39bc49a2f0b0838)
Strategy: fork-and-pin; working branch ms/main from v2.6.0
Downstream layer: docs/ms/ (governance, decisions, changelog MSODS-*)
Changed defaults: recorded per-change in docs/ms/ODS-MS-CHANGELOG.md
Hardware assumption: single AMD Strix Halo host (EVO-X3, UMA 64GB), external-LLM
mode against host-native Ollama; Tailscale-only exposure (BIND_ADDRESS=127.0.0.1)
Never used: public bootstrap installer (install from this clone only)
Validation: scripts/audit-extensions.py, validate-generated-configs.py,
validate-golden-paths.py per upstream FORKABILITY.md
