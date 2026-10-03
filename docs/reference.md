# Reference tables

Lookup tables that AGENTS.md points at. They live here rather than in AGENTS.md
because that file is read into every session, and these are needed only when
you are actually looking something up.

## Shared library modules

Every module in `lib/`. `common.sh` sources all of them except itself and
`router.sh`, which `lib/provider.sh` sources lazily when a routed launch needs
it.

| Module | Purpose | Key functions |
|--------|---------|---------------|
| `common.sh` | Bootstrap, constants, sources all others | `dx_repo_root()` |
| `lock.sh` | Advisory directory locks with owner records and serialized stale recovery | `dx_lock_acquire()`, `dx_lock_release()`, `dx_lock_with()` |
| `agent-tools.sh` | Conservative Claude/Codex tooling bootstrap, Dex's MCP registry and per-launch plugins, per-phase MCP servers (`## MCP`), opt-in global hooks and skill links | `dx_bootstrap_agent_tooling()`, `dx_install_safe_official_claude_plugins()`, `dx_mcp_registry_set()`, `dx_dex_launch_mcp_config()`, `dx_mcp_launch_config()`, `dx_mcp_phase_report()`, `dx_dex_launch_plugin_dirs()`, `dx_claude_global_skills_state()`, `dx_remove_claude_skill_links()` |
| `attribution.sh` | Commit/PR attribution settings, installation, hook chaining, restoration, and the model resolver | `dx_attribution_settings()`, `dx_attribution_model()`, `dx_install_repo_attribution()`, `dx_uninstall_repo_attribution()`, `dx_commit_attribution_message()` |
| `codex.sh` | Codex CLI skill installation helpers | `dx_install_codex_skills()`, `dx_count_dex_skills()`, `dx_codex_dex_skills_complete()`, `dx_uninstall_codex_skills()` |
| `completion.sh` | Generation-bound completion expectations, receipts, validation, and cleanup | `dx_completion_issue()`, `dx_completion_write_receipt()`, `dx_completion_consume()` |
| `dexcode.sh` | DexCode login, org connections, run registration/sync, artifact upload | `dx_dexcode_login()`, `dx_dexcode_command()`, `dx_dexcode_prepare_run_sync()`, `dx_dexcode_upload_artifact()` |
| `events.sh` | Run IDs, local run directories, JSONL event journals, redacted logs, artifact manifests, summaries, the run's copy of the approved Claude plan | `dx_run_prepare()`, `dx_event_emit()`, `dx_run_log_append()`, `dx_run_register_artifact()`, `dx_run_write_summary()`, `dx_run_archive_plans()`, `dx_run_plan_file()` |
| `factory.sh` | Optional Dex Factory event sync over HTTP | `dx_factory_sync_pending_events()`, `dx_factory_events_endpoint()`, `dx_factory_sync_requested()` |
| `git.sh` | Git helpers, including safe tracker-branch adoption | `dx_default_branch()`, `dx_ticket_branch_prepare()`, `dx_slugify()` |
| `lifecycle-control.sh` | Human/agent lifecycle pause, stop, phase transition, ownership, and audit receipts | `dx_write_lifecycle_control()`, `dx_lifecycle_control_read()`, `dx_lifecycle_control_lock_acquire()` |
| `maintenance.sh` | Background maintenance config, workflow install, run IDs, locks, and reviewer normalization | `dx_maintenance_event_mode()`, `dx_maintenance_install_workflow()`, `dx_maintenance_run_id()`, `dx_maintenance_request_reviewer()`, `dx_maintenance_pr_review_state()` |
| `reviewers.sh` | Reviewers table parsing, Greptile/Copilot adapter triggers, the Phase 6 reviewer wait gate, CI readiness, and cycle accounting | `dx_reviewers_rows()`, `dx_reviewer_trigger()`, `dx_reviewer_comment()`, `dx_reviewer_gate()`, `dx_complete_ci_state()`, `dx_complete_record_cycle()` |
| `pr-threads.sh` | The review-thread policy: per-outcome replies, reactions and resolves, open-thread listing for Phase 6, and backup-then-delete of a stray pending review | `dx_pr_thread_policy()`, `dx_pr_thread_respond()`, `dx_pr_threads_open()`, `dx_pr_pending_review_clear()` |
| `override.sh` | Session policy journal, validation, expiry, and effective-value resolution | `dx_override_set()`, `dx_override_clear()`, `dx_override_list()`, `dx_override_effective()` |
| `provider.sh` | Provider/model profile resolution, launch wrapping (including the session PATH), and diagnostics | `dx_provider_apply()`, `dx_provider_claude()`, `dx_session_path()`, `dx_provider_command()`, `dx_provider_doctor()` |
| `project-state.sh` | Init ownership snapshots, conservative project cleanup, and the machine-readable `.dex/dex.md` contract reader | `dx_project_state_begin()`, `dx_project_state_finalize()`, `dx_project_state_remove_managed()`, `dx_project_contract_values()`, `dx_project_worktree_hook()`, `dx_project_context_provider()`, `dx_project_pr_template()`, `dx_project_pr_label_rules()`, `dx_pr_apply_label_rules()`, `dx_project_teardown_value()` |
| `context-providers.sh` | Runs a project's `## Context Providers` commands at session start and phase handoff and wraps their output as unverified recall ([docs/context-providers.md](context-providers.md)) | `dx_context_provider_block()` |
| `review.sh` | Scope-bound review selection/state, evidence, deterministic baselines, wrapper-clock metrics, retained proofs, ledgers, receipts, result parsing, churn detection, and telemetry JSON | `dx_review_evidence_valid()`, `dx_review_baseline_publish()`, `dx_review_metrics_mark()`, `dx_review_ledger_valid()`, `dx_review_write_receipt()`, `dx_review_event_json()` |
| `review-capacity.sh` | Host-wide FIFO admission with named pools (`waves`, `checks`, `heavy`), PID-reuse-safe stale-owner recovery, and a per-pool limit | `dx_review_capacity_limit()`, `dx_review_capacity_wait()`, `dx_review_capacity_release()`, `dx_capacity_pool_wait()`, `dx_capacity_pool_release()`, `dx_capacity_pool_queue_status()` |
| `review-loop.sh` | The review loop itself plus its helpers: wave orchestration, tier assessment, run telemetry, pause and interrupt handling, scope snapshots. `dxreviewloop` in dx.sh is a thin wrapper over it | `dx_review_loop_run()`, `__dx_review_emit_event()`, `__dx_review_scope_snapshot()` |
| `review-controller.sh` | Pure review-loop state transitions and atomic findings history | `dx_review_transition()`, `dx_review_findings_history_append()` |
| `review-acceptance.sh` | Durable wave handoff, retained authorization, and idempotent parent checkpoint recovery | `dx_review_acceptance_begin()`, `dx_review_acceptance_finish()` |
| `review-diagnostics.sh` | Bounded failure evidence retained before child cleanup | `__dx_review_cleanup_pass()` |
| `review-policy.sh` | Trusted default-branch clean-pass policy resolution and binding | `dx_review_policy_resolve()`, `dx_review_policy_for_tier()` |
| `rtk.sh` | RTK token-reduction bootstrap and checks | `dx_install_rtk_tooling()`, `dx_check_rtk_tooling()`, `dx_rtk_resolved_binary()` |
| `router.sh` | Lazy optional CCR CLI and provider launch bridge | `dx_router_node_check()`, `dx_router_command()`, `dx_router_launch()` |
| `run-spec.sh` | Structured headless run spec validation, fetch, normalization, and journal prep | `dx_run_spec_normalize()`, `dx_run_spec_fetch()`, `dx_run_spec_prepare_journal()` |
| `session-catalog.sh` | Read-only, repo-scoped lifecycle inventory and exact selector resolution | `dx_session_catalog_records()`, `dx_session_catalog_record()`, `dx_session_catalog_select()` |
| `session-runtime.sh` | PID-reuse-safe lifecycle runtime leases and health | `dx_session_runtime_start()`, `dx_session_runtime_heartbeat()`, `dx_session_runtime_finish()` |
| `session.sh` | Session ID derivation, state file paths, and per-command timeouts | `dx_session_id()`, `dx_provider_state_file()`, `dx_cleanup_session()`, `dx_run_with_timeout()` |
| `session-process.sh` | Session process ownership: the per-phase token, carrier scans, the reap at session end, phase exit and orphan sweep, `dx ps` process descriptions, and the per-session gate, peak-RSS and summary telemetry | `dx_session_process_token_attach()`, `dx_session_finish_processes()`, `dx_session_process_describe()`, `dx_session_gate_record()`, `__dx_session_summary()` |
| `session-management.sh` | Strict internal lifecycle-session cleanup transactions | `__dx_session_management_cleanup_exact()` |
| `output.sh` | Formatted user-facing output | `dx_done()`, `dx_ok()`, `dx_warn()`, `dx_error()`, etc. |
| `host-budget.sh` | Measured host facts (cores, memory, load, cgroup limits, free memory) with recorded fallbacks; the per-session test-job budget and runner environment (`DX_TEST_JOBS`, vitest, pytest-xdist, cargo, go, make); the `heavy` admission limit, the per-phase host snapshot, the reduced-priority wrappers, and heavy-gate receipts | `dx_host_cpu_count()`, `dx_host_memory_total_gb()`, `dx_host_load1()`, `dx_host_test_jobs()`, `dx_host_budget_env()`, `dx_host_heavy_limit()`, `dx_host_snapshot()`, `dx_host_handoff_line()`, `dx_host_priority_wrapper()`, `dx_gate_receipt_write()`, `dx_gate_receipt_lookup()` |
| `ui-capture.sh` | Playwright/UI capture tooling, artifact paths, MCP bootstrap | `dx_install_ui_capture_tooling()`, `dx_ui_capture_run_dir()`, `dx_ui_capture_playwright_ready()` |
| `ticket.sh` | Ticket references: the optional `ticket_prefixes` list under `## Tickets` in `.dex/dex.md`, the canonical ticket ID (`ENG-1234` for a listed prefix, else the number), and the workspace names built from it; the `ticket_close` setting under the same section, the `DEX_TICKET_CLOSE` run override and the mode recorded at launch, and the tracker kind read from `## Integrations`. See [Ticket close](worktree-teardown.md#ticket-close) | `dx_ticket_prefixes()`, `dx_ticket_parse()`, `dx_ticket_workspace_name()`, `dx_ticket_id_from_workspace_name()`, `dx_ticket_close_mode()`, `dx_ticket_close_setting()`, `dx_ticket_close_snapshot()`, `dx_ticket_tracker_kind()` |
| `triage.sh` | Standalone ticket triage arguments, provider launch, and isolated cleanup | `dx_triage_run()`, `dx_triage_cleanup()` |
| `worker.sh` | DexCode worker registration and the poll/claim/lease/settle daemon | `dx_worker_command()`, `dx_worker_register()`, `dx_worker_daemon()` |
| `teardown.sh` | Safe worktree teardown: the `## Worktree Teardown` settings, the rescue copy and the gate `dx_wt_remove()` runs first, safe branch deletion, merged-PR lookup, and deferred teardown records. `dxrm`, `dxrm --all`, `dxclean` and `dx worktree audit --apply` all remove through that gate and keep a branch whose commits exist nowhere else; `dxclean` first finishes `on_merge` teardowns whose pull request merged, skips deferred ones, and follows lifecycle branches renamed away from `worktree-*` through session records, as `dxrm <name>` does once the directory is gone. See [docs/worktree-teardown.md](worktree-teardown.md); the `ticket_close: on_merge` record that rides on the same `.meta` and that sweep, which closes the ticket once the pull request merges | `dx_teardown_setting()`, `dx_wt_teardown_gate()`, `dx_wt_rescue()`, `dx_branch_delete_safe()`, `dx_lifecycle_branch_release()`, `dx_pr_merged_head()`, `dx_teardown_deferred_list()`, `dx_ticket_close_defer()`, `dx_ticket_close_items_add()`, `dx_ticket_close_settle()`, `dx_ticket_close_record_match()`, `dx_ticket_close_forget()`, `dx_pr_merged_number()` |
| `worktree.sh` | Worktree management utilities, shared build-cache links, and the project's `## Worktree Hooks` lifecycle commands | `dx_wt_branch()`, `dx_wt_remove()`, `dx_worktree_hook_run()`, `dx_worktree_orphan_resources()`, `dx_cleanup_last_session()`, `dx_cleanup_stale_files()` |

## `dx install` flags

Every Claude session Dex launches gets Dex's hooks through its `--settings`
file and Dex's skills as the plugin `dex` through `--plugin-dir
"$DEX_DIR/plugin"` (skills answer to their bare name and to `dex:<name>`).
The hook and skill flags only change what plain `claude` sessions see.

## Per-launch MCP servers and plugins

`dx install`, `dx init` and `dx tools bootstrap` set these up under
`$DX_TOOL_DIR`, never in your own Claude or Codex configuration. `dx sync`
only checks them unless you pass `--bootstrap`. `DEX_SKIP_TOOL_BOOTSTRAP=1`
turns every install off.

| What | Where | How a launch gets it |
|------|-------|----------------------|
| MCP registry (`playwright`, `chrome-devtools`, `openaiDeveloperDocs`, and any `.mcp.json` server `dx config` adds) | `$DX_TOOL_DIR/mcp-registry.json` | Claude: one `--mcp-config` file, not strict, so your own servers still load. Codex (interactive sessions): `-c mcp_servers.<name>.<field>=…`. Claude skips a name you configured (user, local or project scope) or disabled, so yours wins. Codex skips a name your `config.toml` defines. Codex values, `env` included, appear in its argv. Phases that launch with no MCP servers or with a project's `## MCP` list, and review waves, keep their strict config ([docs/mcp-phases.md](mcp-phases.md)) |
| Plugin marketplaces (`claude-plugins-official`, and `openai-codex` when Codex is installed) | `$DX_TOOL_DIR/plugins/marketplaces/<name>`, a clone at the commit Dex pins | not loaded directly |
| Plugins (`codex`, `frontend-design`, and the TypeScript, Pyright, rust-analyzer and gopls LSP plugins) | `$DX_TOOL_DIR/plugins/resolved/<plugin>`: a link to a plugin with its own manifest, or a generated `plugin.json` for a `strict: false` marketplace entry | one `--plugin-dir` per plugin the repository's languages select, after Dex's own; a plugin named in `enabledPlugins` in your user, project or local settings, true or false, is left to you |

`dx tools bootstrap` refuses a plugin when:

- its marketplace `source` is not a directory inside the marketplace;
- a symlink in its tree resolves outside the plugin's own directory (a link
  inside it is allowed, and its target is scanned like any other file);
- its marketplace entry or its own `plugin.json` gives `commands`, `agents`,
  `skills`, `hooks`, `mcpServers`, `lspServers` or `outputStyles` as a path;
- its entry, or any file in its tree up to 1 MB, mentions
  `CLAUDE_PLUGIN_DATA` (which writes under `~/.claude/plugins/data`).

These checks run when the plugin is resolved, not at launch. The text scan is
a heuristic; the real control is the short allowlist of plugins, from
marketplaces pinned to reviewed commits.

Through the router, the registry joins its MCP scope as the lowest layer, so
`mcp_scope.include` still decides. A phase whose `## MCP` value is `none` or a list hands the router
a strict configuration as its own, so the router's scope does not replace it.

Codex has no per-launch skills path. Dex's skill links in `$CODEX_HOME/skills`
and its RTK instructions (`RTK.md`, an import line in `AGENTS.md`) are the one
global write left, and they are opt-in: `dx tools bootstrap --codex-home` or
`DEX_CODEX_HOME_WRITES=1`. The bootstrap records that explicit choice as
`$DX_TOOL_DIR/codex-home-writes`, so later checks and the doctor follow it.
`DEX_CODEX_HOME_WRITES=0` overrides the record for one run, and
`dx tools bootstrap --no-codex-home` deletes it and removes the links and
instructions.

Registrations an earlier Dex made at user scope stay where they are; Dex no
longer adds new ones.

| Flag | Effect |
|------|--------|
| `--global-hooks` | Also install Dex's hooks in your Claude settings, gated on `DEX_LAUNCHED` so Dex launches do not run them twice |
| `--no-global-hooks` | Remove Dex's hooks from your Claude settings |
| `--global-skills` | Also link Dex's skills into `~/.claude/skills` (one directory link, or per-skill links beside your own) |
| `--no-global-skills` | Remove Dex's links from `~/.claude/skills`; anything else there stays |
| `--no-shell-integration` | Skip the `~/.zshrc` append and print the two lines that put the [shims](#shims) on PATH |

## Shims

`shims/` holds one relative symlink per public `dx.sh` function (`dx`, `dex`,
`dexter`, `dxloop`, `dxtriage`, `dxrefine`, `dxcomplete`, `dxreviewloop`,
`dxrm`, `dxls`, `dxcd`, `dxclean`), each pointing at `bin/dx-multicall`. The
multicall script runs the function it was invoked as under
`zsh -f -c 'source "$DEX_DIR/dx.sh"; "$0" "$@"'`. `DEX_DIR` defaults to the
checkout the script lives in; a missing `dx.sh` or zsh exits 127. `dxcd` prints
its target instead of changing directory.

`dx install --no-shell-integration` skips the `~/.zshrc` append and prints the
two lines that put the shims on PATH. `dx_session_path` puts `$DEX_DIR/shims`
and the managed RTK directory on the PATH of every Claude and Codex launch, so
in-session `dx` commands resolve without an rc. `tests/dx-without-rc-test.sh`
keeps the shim list in step with `dx.sh`.

## Environment variables

The environment values below are launch defaults. Active lifecycle consumers
re-read the corresponding `dx control override` records without a provider
relaunch. Review can use an override-bound lower target; named assurance
waivers remain separate from passed results. See `docs/autonomous-mode.md` for
the gate map.

| Variable | Purpose | Default |
|----------|---------|---------|
| `DEX_DIR` | Installation directory | `$HOME/work/dex` |
| `DEX_HOME` | One root for all Dex state; see [State root](#state-root). Empty counts as unset | unset |
| `DEX_OFFLINE` | `1` turns off every optional network call Dex's own tooling makes; see [Offline mode](#offline-mode) | unset |
| `DEX_AUTO_INIT` | `1` lets `dx` set up `.dex/` in a repository without one when there is no terminal to ask on; see [Auto-init](#auto-init) | unset |
| `DEX_EXTRA_SETTINGS` | A Claude settings file layered last into every Dex launch's `--settings` file; an unreadable one stops the launch | unset |
| `DEX_LAUNCHED` | Set to `1` in every Claude session Dex launches; the opt-in global hooks (`dx install --global-hooks`) do nothing when it is set | unset |
| `DX_STATE_DIR` | Phase state directory | `$DEX_HOME/state`, else `~/.claude/.dex-phases` |
| `DX_LOOP_DIR` | Loop state directory | `$DEX_HOME/loops`, else `~/.claude/.dex-loops` |
| `DX_ARTIFACT_DIR` | Dex-generated screenshots, videos, traces, and logs | `$DEX_HOME/artifacts`, else `~/.claude/.dex-artifacts` |
| `DX_TOOL_DIR` | Dex-managed external tooling cache | `$DEX_HOME/tools`, else `~/.claude/.dex-tools` |
| `DEX_ROUTER_HOT_RELOAD` | `0` turns off the router gateway's automatic reload of changed `scripts/ccr/` sources; read by `dx router start` | on |
| `DX_RUN_ROOT` | Dex run directories, event journals, summaries, and run artifacts | `$DEX_HOME/runs`, else `~/.dex/runs` |
| `DX_MAINTENANCE_DIR` | `dx maintain` locks and last-success stamps | `$DEX_HOME/maintenance`, else `~/.claude/.dex-maintenance` |
| `DX_LOG_DIR` | `dx worker` service logs | `$DEX_HOME/logs`, else `~/.dex/logs` |
| `DX_RESCUE_DIR` | Untracked files and uncommitted edits saved from a removed worktree; see [Worktree teardown](worktree-teardown.md) | `$DEX_HOME/rescue`, else `~/.dex/rescue` |
| `DX_PROVIDER_GLOBAL_CONFIG` | Global provider profiles and default (`dx provider use`) | `$DEX_HOME/providers.json`, else `~/.dex/providers.json` |
| `DX_SETUP_FILE` | The `dx setup` routing choice | `$DEX_HOME/setup.json`, else `~/.dex/setup.json` |
| `DX_INSTALL_STATE_FILE` | Install state: managed worktree directories, the session-messaging answer | `$DEX_HOME/install-state.json`, else `~/.claude/.dex-install-state.json` |
| `DEXCODE_CONFIG_DIR` | DexCode login and sync configuration | `$DEX_HOME/dexcode`, else `${XDG_CONFIG_HOME:-~/.config}/dex` |
| `DEX_RUN_ID` | Current run ID passed into hooks/provider subprocesses | unset |
| `DEX_HEADLESS_RUN` | Internal marker for lifecycle sessions started by `dx run` | unset |
| `DEX_HEADLESS_RUN_SPEC_FILE` | Normalized run spec path passed into the launched lifecycle | unset |
| `DEX_HEADLESS_REQUIRES_PLAN_APPROVAL` | Whether Phase 1 must wait for interactive plan approval | spec value |
| `DEX_TICKET_CLOSE` | Run override for `ticket_close` (`on_complete`, `on_merge` or `never`): when Phase 6 moves the ticket to Done. `dx run` sets it from `workflow.ticket_close`; an invalid value is ignored with a warning. See [Ticket close](worktree-teardown.md#ticket-close) | `.dex/dex.md` setting |
| `DX_RTK_ENABLED` | Enable RTK token-reduction bootstrap (`0` disables) | `1` |
| `DX_RTK_BIN` | Override RTK binary path used by Dex hooks/checks | unset |
| `DX_RTK_INSTALL_DIR` | RTK binary install directory | `$DX_TOOL_DIR/rtk/bin` |
| `DX_RTK_VERSION` | Pin RTK release installed by Dex | latest GitHub release |
| `DX_RTK_HTTP_TIMEOUT_SECONDS` | Seconds one RTK download may take | 20 for release metadata, 180 for the binary |
| `DX_SESSION_RUNTIME_OWNER_START_TIMEOUT_MILLISECONDS` | Internal wait for a runtime supervisor to publish ready state; retry-time override, not a lifecycle gate | 15000 |
| `DX_SESSION_RUNTIME_OWNER_FINISH_TIMEOUT_MILLISECONDS` | Internal wait for a runtime supervisor to publish terminal state; retry-time override, not a lifecycle gate | 5000 |
| `DX_TIMEOUT_PROCESS_SCAN_TIMEOUT_SECONDS` | Internal bound for one macOS `lsof` scan while cleaning up a supervised process tree; invalid values fall back to the default | 3 |
| `DX_TOKEN_SCAN_METHOD` | `lsof` skips the first-choice ownership scan (`/proc` on Linux, libproc on macOS) and asks `lsof` directly — for a host whose first-choice answer is known wrong, and for tests that must reach the fallback on a host where the first choice works. Anything else is `auto` | `auto` |
| `DX_SESSION_PROCESS_TOKEN` | Session process-ownership token, exported into the provider session and inherited by every process it starts; the same value is held open on fd 8 so a detached descendant stays identifiable. Set by Dex, not by a user | unset |
| `DX_SESSION_TMP` | Temp root exported to the provider, one per lifecycle phase (a provider session is one phase), removed after that phase's reaper runs. Put scratch files, browser profiles, and gate logs here so they go with the phase | `$DX_LOOP_DIR/<session>.process/tmp` |
| `DX_HOST_ACTIVE_SESSIONS` | Dex sessions owning processes on this host when the session was launched or the phase handed off. Published by Dex for the agent to read, not set by a user | measured |
| `DX_HOST_ACTIVE_HEAVY` | Heavy leases held on this host at the same moment. Published by Dex, not set by a user | measured |
| `DX_HOST_CPUS` | Logical CPUs Dex measured for the session, cgroup-clamped. Published by Dex for the agent to read; `DX_HOST_CPUS_OVERRIDE` is the input | measured |
| `DX_HOST_MEM_GB` | Whole gigabytes of memory Dex measured, cgroup-clamped. Published by Dex; `DX_HOST_MEM_GB_OVERRIDE` is the input | measured |
| `DX_HOST_LOAD1` | One-minute load average when the session was launched or the phase handed off. Published by Dex; `DX_HOST_LOAD1_OVERRIDE` is the input | measured |
| `DX_HOST_FALLBACKS` | Space-separated `fallback=<name>` markers naming each host fact that could not be measured and got a conservative default. Published **empty** when every measurement answered, so an inherited marker cannot outlive the condition that earned it | measured |
| `DEX_LOOP_ACTIVE` | Enable phase audit loop | unset |
| `DEX_LOOP_PHASE` | Current phase (1-6 or "prompt-loop") | unset |
| `DEX_PHASE_HANDOFF` | Same-session phase handoff marker (`inline` for `dx`) | unset |
| `DEX_LOOP_PROMISE` | Human-readable completion acknowledgement; the generated receipt command carries authorization | unset |
| `DEX_LOOP_MAX_ITERATIONS` | Max loop iterations | 30 |
| `DEX_PHASE_TIMEOUT` | Seconds any one phase may run; `0` disables it | `0` (the session budget covers it) |
| `DEX_PHASE_<N>_TIMEOUT` | Same, for one phase only (e.g. `DEX_PHASE_2_TIMEOUT=3600`); wins over `DEX_PHASE_TIMEOUT` | unset |
| `DEX_STOP_SOUND` | Play a sound when Claude stops (macOS only); `0` turns it off | `1` |
| `DEX_STOP_SOUND_FILE` | Play this sound file instead of a random system one | unset |
| `DEX_SKIP_TOOL_BOOTSTRAP` | `1` turns off every Claude/Codex tooling install (`dx install`, `dx init`, `dx sync --bootstrap`, `dx tools bootstrap`); checks still run | `0` |
| `DEX_CODEX_HOME_WRITES` | `1` lets the bootstrap link Dex's skills into `$CODEX_HOME/skills` and write its Codex RTK instructions, and records that choice; `0` turns them off. `dx tools bootstrap --codex-home` sets `1`, `--no-codex-home` deletes the record | unset: on when `$DX_TOOL_DIR/codex-home-writes` exists, else off |
| `DX_CLAUDE_OFFICIAL_MARKETPLACE_URL` / `_REF` | Where the official Claude plugin marketplace is cloned from, and the commit it is pinned to | GitHub `anthropics/claude-plugins-official`, the pin in `lib/agent-tools.sh` |
| `DX_OPENAI_CODEX_MARKETPLACE_URL` / `_REF` | The same for the OpenAI Codex plugin marketplace | GitHub `openai/codex-plugin-cc`, the pin in `lib/agent-tools.sh` |
| `DEX_MCP_LAUNCH_CONFIG` | Internal: the `--mcp-config` file a router launch may fold into its MCP scope | set per launch |
| `DEX_SYNC_BUDGET_MINUTES` | Runtime budget for one `dx sync` provider run | 60 |
| `DEX_MAINTAIN_BUDGET_MINUTES` | Runtime budget for one scheduled maintenance run | 60 |
| `DEX_MAINTAIN_RESPOND_BUDGET_MINUTES` | Runtime budget for one maintenance PR feedback run | 30 |
| `DEX_REVIEW_TIER` | Canonical explicit review-risk override (`trivial`, `small`, `normal`, or `complex`); takes precedence over `DEX_REVIEW_PROFILE` | agent-selected |
| `DEX_REVIEW_SCOUT_PARALLELISM` | Provider-native review scouts allowed at once (0 to 3); `0` means the wave runs its lens groups sequentially | `0`, except `thorough` on an idle host with a diff above `review_scout_min_files` |
| `DEX_REVIEW_LEDGER_FILE` | Set by the loop: the findings ledger a wave reads and appends to (`<session>.review-findings.json`) | per session |
| `DEX_REVIEW_CONFIRMATION` | Set by the loop: `1` when this wave already has clean credit. It re-verifies the ledger and the delta, then — like every pass that would be declared clean — reviews the whole ticket diff with the coherence lens | `0` |
| `DEX_REVIEW_PROFILE` | Legacy review-depth alias (`light`, `standard`, or `thorough`) | unset |
| `DX_REVIEW_PROFILE` | Older spelling of `DEX_REVIEW_PROFILE`, still read as a fallback | unset |
| `DEX_REVIEW_CLEAN_PASSES` | Optional higher clean-wave requirement; cannot lower the selected tier's global policy gate | global policy (1/1/2/3 for trivial/small/normal/complex) |
| `DEX_REVIEW_DISABLE_MCP` | Disable inherited MCP servers in review waves (`0` restores them); read-only assessors always disable them. When set, it wins over a project's `review_waves` in `## MCP` ([docs/mcp-phases.md](mcp-phases.md)) | `1` |
| `DEX_REVIEW_PASS_TIMEOUT` | Seconds a review wave or risk assessment may run before its provider process tree is stopped and review pauses; `0` disables it | Profile-based: 15m assessment/light, 30m standard, 60m thorough |
| `DEX_REVIEW_PASS_RECHECK_SECONDS` | Seconds the Stop hook holds a busy Phase 3 wait before waking the session; capped at 1740 | 270 (4m 30s); 1500 with `DEX_PROMPT_CACHE_TTL=1h` |
| `DEX_PROMPT_CACHE_TTL` | Set by Dex at launch, not by you: `1h` for lifecycle sessions (also exported as `CLAUDE_CODE_PROMPT_CACHE_TTL`, which you may set yourself to override), `5m` for review waves and assessments. The Stop hook reads it to size its Phase 3 hold | set per launch |
| `DEX_TEST_JOBS` | Test-runner workers each Dex-launched session may use (1 to 32); exported to every launch as `DX_TEST_JOBS` and the runner variables listed in [docs/host-budget.md](host-budget.md) | half the cores shared across `DEX_REVIEW_MAX_ACTIVE_WAVES` sessions, capped at 4 |
| `DEX_MAX_ACTIVE_HEAVY` | Heavy commands (project gates, test suites, builds — never a dev server, which starts directly and is session-owned) admitted at once across every Dex session on this host (1 to 8) | `max(1, min(cpus/4, mem_gb/8))`, capped at 8 |
| `DEX_GATE_TIMEOUT` | Seconds one `dx run-gate` command may run before its process tree is stopped; `0` means no deadline, which is the point — a completed result is never discarded | `0` |
| `DEX_GATE_HEARTBEAT_SECONDS` | How often `dx run-gate` prints its queue position while it waits (1 to 9999) | 30 |
| `DEX_GATE_PRIORITY` | Pin the reduced-priority wrapper heavy commands run under: `none`, `nice`, `nice+taskpolicy`, `nice+ionice`, `systemd-run`, `systemd-run+ionice`, or `auto` to probe this host | `auto` |
| `DX_HOST_CPUS_OVERRIDE` | Replace the logical-CPU probe. For a container that knows its own share, and for tests. A malformed value is ignored. Separate from the published `DX_HOST_CPUS` so a nested launch re-measures instead of repeating its parent's snapshot | measured, lowered to a cgroup v2 `cpu.max` quota when one is smaller |
| `DX_HOST_MEM_GB_OVERRIDE` | Replace the total-memory probe, in whole gigabytes. A malformed value fails the reader, the way `DX_HOST_MEMORY_FREE_PERCENT` does | measured, lowered to a cgroup v2 `memory.max` limit when one is smaller |
| `DX_HOST_LOAD1_OVERRIDE` | Replace the one-minute load-average probe. Load is the one fact that changes minute to minute, so the published `DX_HOST_LOAD1` is never read back as an input | `/proc/loadavg`, else `sysctl -n vm.loadavg` |
| `DX_HOST_CGROUP_DIR` | Where to look for the cgroup v2 limit files `cpu.max` and `memory.max` | `/sys/fs/cgroup` |
| `DEX_MIN_FREE_MEMORY_PERCENT` | Free-memory floor below which a review wave waits before joining waves already running; `0` disables the check | 10 |
| `DEX_MAX_CONCURRENT_SUBAGENTS` | Subagents one Dex-launched session may run at once (`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`); review waves use their scout parallelism instead | 4 |
| `DEX_MAX_SUBAGENT_SPAWN_DEPTH` | How deep subagents may nest in a Dex-launched session (`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`); review waves use 1 | 2 |
| `DEX_WORKTREE_SHARED_DIRS` | Ignored top-level directories a new worktree links from the main checkout instead of rebuilding; empty disables | `node_modules target .venv vendor .next .nuxt` |
| `DEX_WATCH_CYCLE_TIMEOUT_SECONDS` | Maximum runtime budget for one scheduled Phase 6 watcher invocation; a cycle past it hands over to the next tick, and a watcher that exits hands over at once. `0` means no budget | 120 (2m 0s) |
| `DEX_WATCH_COMMAND_TIMEOUT_SECONDS` | Maximum runtime for one GitHub/local shell command inside a watcher cycle | 30 (30s) |
| `DEX_WATCH_PAUSE_TTL_SECONDS` | Seconds scheduled Phase 6 watchers stay paused after a direct user prompt | 3600 (1h 0m) |
| `DEX_COMPLETE_MAX_CYCLES` | Max idle PR watch cycles before Phase 6 pauses for manual follow-up | 3 |
| `DEX_COMPLETE_WAIT_MINUTES` | Minimum wait window per Phase 6 cycle (minutes) | 5 |
| `DEX_REVIEWER_WAIT_MINUTES` | Minutes Phase 6 waits for each `wait: yes` reviewer to finish on the current head before recording a timeout (`0` = time out at once) | 20 |
| `DEX_COMPLETE_PENDING_MINUTES` | Minutes CI may stay pending on one head before Phase 6 counts the cycle as idle | 120 |
| `DEX_SESSION_ID` | Unique session ID (set by dxloop for stop hook) | unset |
| `DEX_REVIEW_ASSESSMENT_ACTIVE` | Internal marker for the read-only preflight risk assessor | unset |
| `DEX_REVIEW_PASS_ACTIVE` | Marks a session as a single-shot review-wave pass so its Stop hook can never run the parent lifecycle's inline phase handoff | unset |
| `CODEX_HOME` | Codex config root: where Dex looks for your own MCP servers, and where the opt-in skill links go | `~/.codex` |
| `DX_AGENT` / `DX_AGENT_OVERRIDE` | Agent override (`claude` or `codex`) | profile/default |
| `DX_MODEL` / `DX_MODEL_OVERRIDE` | Model override for the selected agent | profile/default |
| `DEX_SESSION_TITLE` | Title for a new lifecycle's Claude session, named `<ticket> <title>`; `dx --title` and a run spec's `source.title` set it | unset (session named after the workspace) |
| `DX_PROVIDER_PROFILE` | Provider profile override (`claude-subscription`, `codex-subscription`, or custom) | config/default |
| `DX_CLAUDE_MODEL` | Override Claude Code model passed to `--model` | profile model, else session default |
| `DX_PLAN_MODEL` | Override Phase 1/plan model | `DX_CLAUDE_MODEL`, profile plan model, else session default |
| `DX_CODEX_MODEL` | Resolved Codex model passed through `bin/dxcodex.sh` | profile codex model, else Codex default |
| `DX_CODEX_READ_ONLY` | Internal marker that switches Codex delegation to an ephemeral read-only sandbox and forbids dangerous bypass flags | `0` |
| `DX_CLAUDE_EFFORT` | Override Claude Code `--effort` | profile effort, else session default |
| `DX_PLAN_EFFORT` | Override Phase 1/plan effort | `DX_CLAUDE_EFFORT`, profile plan effort, else session default |
| `DX_EFFORT` / `DX_EFFORT_OVERRIDE` | Effort override for the selected agent; a run spec's `harness.effort` sets the override | profile effort |
| `DX_CODEX_EFFORT` | Resolved Codex reasoning effort passed as `-c model_reasoning_effort` through `bin/dxcodex.sh` | effort override, else profile effort, else Codex default |
| `DX_CODEX_JSON` | Add `--json` to a `bin/dxcodex.sh exec` delegation (`0` or `1`); no shipped caller sets it | `0` |
| `DX_CODEX_OUTPUT_LAST_MESSAGE` | Internal: file that receives Codex's last message (`-o`) from a `bin/dxcodex.sh exec` run, used by the read-only risk assessor | unset |
| `DX_ROUTER_SESSION_ID` | Internal: the routed session ID the CCR launch hands to the provider child | set by `dx router launch` |
| `DEX_ROUTER_HOME` | Router state directory (`config.json`, `backend.json`, credentials); tests point it at a temporary directory | `$DEX_HOME/router`, else `~/.dex/router` |
| `DEX_OPENROUTER_API_KEY` | API key for the router's metered `openrouter` provider | unset |
| `DEX_POLICY_SESSION_ID` | Internal: the lifecycle session whose phase route a review assessor or wave follows | the parent session |
| `DEX_REVIEW_WAVE_NUMBER` | Internal: the wave index a review pass runs as; the router rotates the phase's model chain by it for reviewer diversity | set per wave |
| `DX_ALLOW_API_BILLED_AUTH` | Allow `dx provider doctor` to tolerate API/gateway env vars | `0` |
| `DX_ALLOW_REPO_GATEWAY_PROVIDER` | Explicitly allow a trusted repo-local gateway/API provider profile for the current invocation | `0` |
| `DX_ALLOW_FORK_PR_CHECKOUT` | Skill-level opt-in letting `/dxprreview` check out fork PRs | `0` |
| `DEX_LIFECYCLE_MINIMAL_MCP` | Launch the lifecycle phases that never open a browser (4 Verify, 5 PR, 6 Complete, and 1 Plan when the launch ends with the phase) with no MCP servers, the way review waves already launch; `0` keeps whatever the session inherited, and also turns off a project's `## MCP` phase lists. A project can name each phase's servers instead ([docs/mcp-phases.md](mcp-phases.md)). Phases 0, 2 and 3, standalone sessions, and interactive `claude` are untouched | `1` |
| `DEX_UI_MCP_SCOPE` | Where `dx ui-capture install` puts the browser servers: `dex` (Dex's MCP registry, loaded by Dex launches only, for Claude and Codex), or `user`, `project` or `local` to register them with the Claude and Codex CLIs as before, same as its `--user`/`--project`/`--local` flags; `project` writes the repository's tracked `.mcp.json` at the checkout root and falls back to `user` outside a checkout | `dex` |
| `DEX_SESSION_RSS_SAMPLE_SECONDS` | How often the runtime supervisor samples the peak resident size of the session's token-carrying process tree, on the heartbeat it already runs. Clamped to 1..3600; a malformed value falls back to the default rather than refusing to supervise | 30 |
| `DEX_WORKTREE_HOOK_TIMEOUT` | Seconds one `## Worktree Hooks` command (`after_create`, `before_remove`, `on_session_end`, `orphan_resources`) may run before its process tree is stopped; `0` removes the deadline, except for `on_session_end`, which is capped at 5 s whatever this says because the host gives the whole SessionEnd hook ten seconds. A hook that is stopped, or that fails, warns and never blocks the create or remove. See [docs/worktree-hooks.md](worktree-hooks.md) | 300 (5m 0s) |
| `DX_TICKET_ID`, `DX_TICKET_TITLE`, `DX_PHASE`, `DX_REPO_ROOT`, `DX_WORKTREE_NAME`, `DX_SESSION_ID`, `DX_CHANGED_FILES` | Set by Dex for a `## Context Providers` command only, not for the session: the ticket, its title, the phase the recall is for, the main checkout, the worktree's name, the session ID, and a path to the branch's changed-file list. See [docs/context-providers.md](context-providers.md) | — |
| `DEX_TEARDOWN_GH_TIMEOUT` | Seconds Dex waits for `gh` when checking whether a lifecycle's pull request merged, and for `git ls-remote`/`git push --delete` when deleting a merged remote branch. A timeout counts as "could not confirm", which keeps everything. See [docs/worktree-teardown.md](worktree-teardown.md) | 30 (10 for the check at `dx` start) |
| `DEX_REVIEW_CHECK_TIMEOUT` | Seconds one deterministic check may run before `bin/review-check.sh` reports it `over-budget`. It no longer stops the command: a late result keeps its real exit code and duration and is cached like any other | 900 (15m 0s) |
| `DEX_REVIEW_CHECK_HARD_TIMEOUT` | The only deadline that stops a check. Reaching it is exit 124 with no reusable result, the way the execution budget used to behave | 4 × `DEX_REVIEW_CHECK_TIMEOUT` (3600) |
| `DEX_REVIEW_CHECK_QUEUE_TIMEOUT` | Seconds a check may wait for the host check pool before it gives up with the `queued` status — exit 75, nothing ran, ask again later. `0` waits with a heartbeat, because waiting is not a failure | `0` |
| `DEX_REVIEW_CHECK_HEARTBEAT_SECONDS` | How often a queued check prints its queue position and the age of the oldest running check (1 to 9999) | 30 × `DEX_REVIEW_CAPACITY_RECHECK_SECONDS` |
| `$DX_STATE_DIR/guard-heavy-commands.json` | Not a variable, but the one file `hooks/guard-handler.py` writes: each repository's parsed `heavy_commands`, keyed by its `.dex/dex.md` path, mtime and size, so the advisory does not re-import the contract parser on every Bash call. Advisory cache only — deleting it costs one re-parse. 0600, capped at 32 repositories | `$DX_STATE_DIR/guard-heavy-commands.json` |

## Attribution

A project sets how commits and PRs are attributed in an optional
`## Attribution` block in `.dex/dex.md`. Every key is optional, and a missing
block keeps the defaults below. A malformed block, or a value Dex does not
recognise, prints a warning and uses the default.

```yaml
attribution: dex         # dex | claude | both | none
model_trailer: AI-Model  # trailer key; off when absent
pr_models: false         # add a Models line to PR descriptions
hooks: true              # dx init and dx sync install the commit-msg hooks
pr_template: true        # dx init and dx sync install .github/pull_request_template.md
```

| Mode | Commit trailers | PR footer |
|------|-----------------|-----------|
| `dex` (default) | `Co-Authored-By: Dex <noreply@dexcode.ai>`; Claude's attribution removed | `Generated by Dex` |
| `claude` | Claude Code's attribution kept; no Dex trailer | none from Dex |
| `both` | Claude Code's attribution kept and the Dex trailer added | `Generated by Dex` |
| `none` | Claude's and Dex's attribution both removed | none |

The commit-msg hook reads the block on every commit, so a change applies to
the next commit. It adds trailers with `git interpret-trailers`, which places
them in the message's existing trailer block. A co-author or `Refs:` line
already there stays a trailer, and `git commit -v` works. The
`warn-claude-attribution` guard warns only in the `dex` and `none` modes.

### Model trailer

With `model_trailer: AI-Model`, a commit made inside a Dex session gets
`AI-Model: <model>`. Commits made outside a Dex session get none. The hook
looks up the model when the commit is made, so a model switch mid-session
shows on the next commit. It checks, in order:

1. the CCR router's record of the model it served, for a routed session;
2. the newest assistant turn in the session's own Claude transcript, at
   `${CLAUDE_CONFIG_DIR:-~/.claude}/projects/<launch dir>/<conversation id>.jsonl`.
   Only that one file is opened, and only read; Dex never scans the folder;
3. the model the provider configuration selects;
4. `unknown`.

An amend replaces the earlier model line. Codex transcripts are not read;
Codex sessions use the configured model.

To find code by model:

```bash
git log --format='%h %(trailers:key=AI-Model,valueonly)'
git log --grep='AI-Model: claude-opus'
```

`dx attribution mode`, `settings`, `model` and `models [<base>]` print the
mode, every setting, the current session's model, and the models on the
branch. With `pr_models: true`, the PR step adds a `Models:` line from
`dx attribution models`.

### Installing the hooks and the PR template

`dx init` and `dx sync` install both by default. `--no-attribution-hooks` and
`--no-pr-template` leave them out for that run, and `hooks: false` /
`pr_template: false` leave them out every time. A dex.md that `dx init` creates
records that run's choice. A sync with `hooks: false` does not remove hooks
already installed; `dx uninit` does, and it restores `core.hooksPath` only
while it still points at Dex's hooks.

In a linked worktree, `--local` config is the repository's shared
`.git/config`, so Dex never writes `core.hooksPath` there:

- with `extensions.worktreeConfig` already on, it installs with
  `git config --worktree`;
- otherwise it installs nothing and prints how to enable hooks:
  `git config extensions.worktreeConfig true && dx sync` for that worktree, or
  `dx sync` in the main checkout for the whole repository.

A main checkout keeps using `--local`, which every linked worktree inherits.

### Auto-init

When `dx` starts a lifecycle in a repository without `.dex/`:

- On a terminal it asks before setting up `.dex/`, then asks separately about
  the hooks and the PR template. Both default to no.
- Without a terminal, or in a headless `dx run`, it stops with an error unless
  the run opts in with `dx --init`, `DEX_AUTO_INIT=1` or
  `workflow.auto_init: true` in the run spec. An opted-in run installs neither
  the hooks nor the template.

**Behaviour change.** Earlier versions set up `.dex/`, the hooks and the PR
template silently. Headless automation that relied on that now fails until it
opts in.

## State root

Set `DEX_HOME` to an absolute directory and every Dex state path defaults
beneath it, so one `rm -rf "$DEX_HOME"` removes all of it:

```
$DEX_HOME/
  state/               DX_STATE_DIR
  loops/               DX_LOOP_DIR
  artifacts/           DX_ARTIFACT_DIR
  tools/               DX_TOOL_DIR (RTK, Playwright tooling, caches below)
  runs/                DX_RUN_ROOT
  maintenance/         DX_MAINTENANCE_DIR
  router/              DEX_ROUTER_HOME
  dexcode/             DEXCODE_CONFIG_DIR
  logs/                DX_LOG_DIR
  rescue/              DX_RESCUE_DIR
  providers.json       DX_PROVIDER_GLOBAL_CONFIG
  setup.json           DX_SETUP_FILE
  install-state.json   DX_INSTALL_STATE_FILE
  launch-settings/     per-launch Claude settings (under DX_LOOP_DIR without DEX_HOME)
```

- An individual variable still wins over `DEX_HOME`. An empty value counts as
  unset. A trailing `/` is dropped. A relative or `~` value is ignored with a
  warning, which `dx doctor` shows too, and the legacy locations apply.
- With `DEX_HOME` unset, every path keeps its legacy location (the table above).
  Nothing is migrated when you set it; `dx doctor` mentions a legacy install
  state file it no longer reads.
- `lib/common.sh` resolves the table. With `DEX_HOME` set it exports every
  path; unset, it exports only `DX_STATE_DIR`, `DX_LOOP_DIR`, `DX_ARTIFACT_DIR`,
  `DX_TOOL_DIR` and `DX_RUN_ROOT`, as before. `DX_PATHS_FROM` records the
  `DEX_HOME` and `HOME` those values came from, so a child that changes either
  recomputes every value still equal to the old default; a real override
  stays. Known limits: an override set to exactly the old default is
  recomputed too (use a different path to keep it), and the Python and Node
  resolvers do not read `DX_PATHS_FROM`, so one started directly with another
  `HOME` uses the values it inherited. `dx` and the other public `dx.sh`
  commands re-resolve on every call, so `export DEX_HOME=...` in a shell that
  already sourced `dx.sh` takes effect without `dx reload`. Hooks and Node
  scripts that run without it resolve the same table through
  `hooks/dex_paths.py` and `scripts/dex-paths.cjs`, so a session Dex did not
  launch only needs `DEX_HOME` in its environment.
- **One root per host.** Host-wide admission (`lib/host-budget.sh`) counts the
  live sessions under `DX_LOOP_DIR`, and the capacity pools live there too. Two
  roots on one host means two separate budgets, so start every session on a
  host with the same `DEX_HOME`. `dx doctor` warns when it finds live sessions
  under the legacy loop directory, and when `DX_LOOP_DIR` resolves outside
  `DEX_HOME`. Both checks run only in a session that has `DEX_HOME` set: one
  without it has no second root to look in, so run `dx doctor` from the
  `DEX_HOME` side.
- **Caches.** With `DEX_HOME` set, Dex's own `npm install`, `npx playwright
  install`, the router's `npm ci` and browser MCP launches use `PLAYWRIGHT_BROWSERS_PATH=$DX_TOOL_DIR/ms-playwright`
  and `npm_config_cache=$DX_TOOL_DIR/npm-cache`. They are set only for those
  commands, never exported into your shell, and a value you already set (a
  Nix-provided browser bundle, say) wins. Browser MCP servers registered by
  `dx ui-capture install` carry `DEX_HOME` in their entry.

## Offline mode

`DEX_OFFLINE=1` turns off every optional network call Dex's own tooling makes.
It is for restricted networks, and for anyone who wants no data to leave the
machine. `1`, `true`, `yes` and `on` (any case) turn it on. Any other value,
or no value, leaves Dex as it was. Nothing in `.dex/dex.md` changes.

What it turns off:

- DexCode run, artifact and project-context sync, and Factory event sync.
  It wins over an explicit `DEXCODE_SYNC=1`, `DEXCODE_CONTEXT_SYNC=1` or
  `DEX_FACTORY_SYNC=true`. With `DEXCODE_SYNC_REQUIRED=1` or
  `DEXCODE_CONTEXT_SYNC_REQUIRED=1` the run warns that the requirement was
  ignored rather than failing.
- The RTK release check and download. An RTK that is already installed keeps
  rewriting commands; `DX_RTK_ENABLED=0` is what turns RTK off.
- The tool bootstrap's downloads: the UI-capture `npm install` and Chromium
  download, the plugin marketplace clone and fetch, and registering the remote
  OpenAI docs MCP. Each reports `[skip] … (DEX_OFFLINE=1)`, and the bootstrap
  still succeeds. Work that is already done is reported as it always is.
- Remote MCP servers in Dex's own registry (a `url`, or type `http` or `sse`)
  are left out of every launch, including one an earlier online bootstrap
  registered. Servers you configured yourself are not touched.
- Browser MCP servers start `npx` with npm's offline mode, so
  `@latest` resolves from the npm cache. One that was never started online
  fails with npm's `ENOTCACHED` error.
- UI-capture narration, whose voice model downloads on first use, is turned
  off. The video keeps its captions.

Commands whose whole job is the network exit non-zero with
`<command> needs the network; unset DEX_OFFLINE to allow it`: `dx login`,
`dx dexcode use`, `dx worker register`, `dx worker run`, `dx run --spec-url`,
`dx ui-capture install` (and a capture that would first have to install its
tooling), and `dx router setup`, `install` and `update`. `dx whoami` shows the
saved details without refreshing them.

What it does not cover: the lifecycle's own `git` and `gh` traffic (fetch,
push, pull requests, issues), the model traffic of Claude, Codex and the CCR
router, and anything your own MCP servers or hooks do.

`dx status` shows the posture on its `Network:` row. Export the variable, or
set it in the shell that runs `dx`; `dx` passes it on to the scripts and hooks
it starts.
