# MCP servers per phase

Every MCP server a Claude session loads is a process, often a Node sidecar,
and its tool list costs context tokens. So Dex launches the phases that never
open a browser (Plan, Verify, PR and Complete) with no MCP servers at all, and
review waves the same. That default also takes away servers a project relies
on, such as a tracker or a memory server while planning.

A project can name the servers each phase gets instead. A fenced YAML block
under `## MCP` in `.dex/dex.md` lists them:

```yaml
default: inherit              # inherit | none | [server, ...]
plan: [linear, github, memory]
implement: inherit
verify: none
pr: [github]
complete: [github, linear]
review_waves: none
```

Every key is optional, and so is the whole section. Without it, every phase
launches the way it always has.

## The keys

| Key | What it sets |
|-----|--------------|
| `plan`, `implement`, `verify`, `pr`, `complete` | The servers a launch at that phase loads. |
| `default` | The value for any of those five phases the block does not name. |
| `review_waves` | The servers each Phase 3 review wave loads. The read-only risk assessor always launches with none. |

The block is a flat mapping: one key per line, as in `## Resources` and
`## Worktree Hooks`. Write `plan: [linear]`, not a `phases:` map. Setup and the
Phase 3 review host session are not configurable; they always keep the user's
servers, as they always have.

## The values

| Value | Meaning |
|-------|---------|
| `inherit` | Whatever the user configured, plus Dex's MCP registry. This is the launch Dex makes today. |
| `none` | No MCP servers: `--strict-mcp-config` with an empty configuration. |
| `[a, b]`, a block list, or a bare `a` | Only these servers: `--strict-mcp-config` with a configuration that holds exactly them. |
| `[]` or an empty key | The same as `none`. |

A phase the block does not name takes `default`. With no `default`, it falls
back to Dex's built-in table:

| Phase | Built-in |
|-------|----------|
| Setup | inherit |
| Plan | none |
| Implement | inherit |
| Review (host session) | inherit |
| Verify | none |
| PR | none |
| Complete | none |
| Review waves | none |

So `plan: [linear]` on its own changes Plan and nothing else.

## Where a name is looked up

A name is resolved the way Claude would resolve it, from these layers, lowest
first: Dex's MCP registry (`dx tools bootstrap`, `dx ui-capture install`), the
user's `~/.claude.json` (or `$CLAUDE_CONFIG_DIR/.claude.json`), the project's
`.mcp.json`, and the local servers Claude keeps for this checkout. A later
layer wins a name the earlier ones also define.

Dex never drops a name without telling you. A name that no layer defines is
reported as missing. So is a name the user disabled, either with
`disabledMcpServers` or `disabledMcpjsonServers` (including the ones a linked
worktree shares with its main checkout) or with `"enabled": false` on the
entry. Each one gets a `[warn]` line at launch, and the launch goes on without
it. A server whose entry reads an unset `${VARIABLE}` gets a warning too.

`--strict-mcp-config` loads only the servers in the configuration Dex passes.
That means plugin-provided servers and claude.ai connectors do not load in a
`none` or list phase, because they live in no configuration file. A name that
exists only that way is reported as missing. Use `inherit` for a phase that
needs one.

## A session keeps the servers it launched with

A Claude session's MCP set is fixed when the session starts. Dex runs a
lifecycle inline: one Claude process starts at a phase and carries on through
every later phase in the same session. So a launch cannot load Plan's servers
and then swap them for Implement's.

Dex gives an inline launch the servers of its own phase and of every later
one. If any of those phases is `inherit`, the launch inherits. Otherwise it
gets the union of their lists, and if all of them are `none`, it gets none.
The Phase 3 review host session always inherits, so an inline launch at
Setup, Plan, Implement or Review always inherits.

**Per-phase lists therefore narrow only relaunched or late-phase sessions.**
That covers:
- a session resumed or relaunched at a later phase;
- a standalone `dxplan` or `dxcomplete`;
- a launch that ends with its phase rather than handing off inline;
- an inline launch at Verify, PR or Complete.

For example, with the block above, an inline launch at Verify loads `github`
and `linear`: the union of `none`, `[github]` and `[github, linear]`. A
standalone `dxplan` loads `linear`, `github` and `memory`.

The one case this cannot cover is a `dx control jump` backwards. The session
keeps the servers it launched with until it is relaunched.

## What wins

In order, highest first:
1. **The environment.** `DEX_LIFECYCLE_MINIMAL_MCP=0` turns phase scoping off,
   and every phase inherits. A set `DEX_REVIEW_DISABLE_MCP` (`1` for none, `0`
   to inherit) decides review waves whatever `review_waves` says.
2. **A caller's own `--mcp-config` or `--strict-mcp-config`.** The caller's
   configuration is used unchanged.
3. **The project's `## MCP`.**
4. **`dx context scope`.** This applies on routed (Claude Code Router)
   launches only, and only to phases that resolve to `inherit`. A `none` or
   list phase passes the router a strict configuration as the caller's own, so
   the router keeps it.
5. **Inherit.**

## Codex

Codex launches ignore `## MCP`. Codex has no equivalent of
`--strict-mcp-config`, so Dex cannot remove the servers in a user's
`config.toml` for one launch. Dex's registry still reaches Codex as before.

## Seeing what resolves

`dx status` lists, under Project, what each phase and review waves load: the
servers that resolve, any that are missing or disabled, and whether a value
came from the block, from `default` or from the built-in table. `dx doctor`
warns about missing, disabled and ignored entries for the repository it runs
in.

An unknown key, an invalid server name, or a block that is not a flat mapping
is reported and ignored. The phases it would have set fall back as if it were
not written. If a Claude configuration file cannot be read, the launch warns
and uses the built-in value for its phase.

## Files

A list phase's configuration is written for that launch only. It is a private
(mode 0600) file under `$DEX_HOME/launch-settings/`, removed when the launch
returns, and the launch-settings sweep removes one a killed launch left behind.
It copies the selected server entries, including any headers or environment
they carry, from the user's own configuration. Dex reads that configuration
and never writes to it. Review waves use one such file per session in Dex's
loop directory, and session cleanup removes it.

The resolver is `scripts/mcp-scope.py`. `dx context scope` uses the same
selection code, through `scripts/ccr/mcp-scope.cjs`.
