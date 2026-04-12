# AI Agent Config Framework v1 — Current Config Mapping

## Status

Proposed

This document maps the current Claude, Codex, and Pi configuration spread across:

- `~/.config/konfigue/modules/ai/*`
- `nix-darvm/guest/modules/*`
- `agent-modules-wip` (only partially known from references; direct inspection was blocked in this session)

into the proposed shared framework:

```nix
ai.agents.<name>
```

and its adapters.

## Goal

Make it obvious, for each current concern:

1. whether it belongs in the shared core
2. whether it belongs in the host adapter
3. whether it belongs in the DVM adapter
4. whether it belongs in a personal workflow layer

## Short version

### Moves into the shared core

- canonical `configDir`
- canonical `pkg`
- canonical `instructions`
- canonical `settings`
- canonical `skills`
- extra declarative config files under `files`

### Moves into adapters

- host-side file materialization
- host-side package installation
- DVM home mounts
- DVM guest package installation
- DVM-specific runtime/env glue

### Stays outside the framework

- wrapper aliases (`klaud`, `kodex`, `pai`)
- auto-resume behavior
- `nono` sandbox behavior
- desktop notifications / attention hooks
- fnox secret loading
- editor auto-connect / Neovim lockfile behavior
- shell shims and jj/git preference enforcement

## Current state by source file

## 1. `~/.config/konfigue/modules/ai/instructions.nix`

### What it contains

- shared instruction text (`shared`)
- reminder skill generation (`reminderSkills`)
- a generated instruction model used by Claude/Codex/Gemini/Pi

### Mapping

#### Shared core

- `shared` -> reusable source fragment for `ai.agents.<name>.instructions`
- agent-specific instruction fragments like `./instructions/claude.md` -> `instructions`
- generated reminder skills -> `skills`

#### Not core

- nothing in here is DVM-specific
- generation helpers can remain implementation details in the module that populates `ai.agents.*`

### Suggested target

```nix
ai.agents.claude.instructions = [
  config.flake.ai.shared
  ./instructions/claude.md
];

ai.agents.codex.instructions = [
  config.flake.ai.shared
];

ai.agents.pi.instructions = [
  config.flake.ai.shared
];

ai.agents.claude.skills = {
  remind-galls-law = ...;
  remind-suspect-every-workaround = ...;
  remind-type-safety = ...;
};
```

## 2. `~/.config/konfigue/modules/ai/agents.nix`

### What it contains

- shared skill source declarations
- Claude/Codex/Gemini/Opencode/Pi instruction wiring through `programs.agents`
- Claude/Codex/Gemini hooks
- a `sessionContextScript` for nono sandbox awareness
- notification hooks / attention hooks

### Mapping

#### Shared core

These concepts belong in the shared core:

- agent enablement intent
- shared instruction text per agent
- shared skill sources and reminder skills

Potential mapping:

- `claude.md = shared + readFile ./instructions/claude.md` -> `ai.agents.claude.instructions`
- `codex.md = shared` -> `ai.agents.codex.instructions`
- `pi.md = shared` -> `ai.agents.pi.instructions`
- `skills.custom`, `skills.reminders`, `skills.design`, `skills.visual-explainer` -> `ai.agents.<name>.skills` or `files` under the appropriate skills subtree

#### Host adapter / personal layer

These do **not** belong in the shared core:

- `SessionStart` nono sandbox hook
- `Notification` / attention mark hook
- `UserPromptSubmit` attention clear hook
- `Stop` completion hook
- `$HOME/.claude/hooks/nono-hook.sh`

Reason:
- these are workflow and environment behavior, not persistent agent-home semantics
- they are especially host/desktop specific

### Suggested target

Core:

```nix
ai.agents.claude.instructions = [ shared ./instructions/claude.md ];
ai.agents.codex.instructions = [ shared ];
ai.agents.pi.instructions = [ shared ];
```

Personal host module:

- defines Claude hook scripts and notification behavior
- materializes them through `files` or host-specific adapter plumbing

## 3. `~/.config/konfigue/modules/ai/claude-code.nix`

### What it contains

Materialized Claude files:

- `.claude/settings.json`
- `.claude/commands/`
- `.claude/agents/`
- `.claude/langs/`
- `.claude/prompts/`
- `.claude/plugins/local/`
- `basic-memory`

### Mapping

#### Shared core

- `.claude/settings.json` -> `ai.agents.claude.settings`
- `.claude/commands/*` -> `ai.agents.claude.files."commands/..."`
- `.claude/agents/*` -> `ai.agents.claude.files."agents/..."`
- `.claude/langs/*` -> `ai.agents.claude.files."langs/..."`
- `.claude/prompts/*` -> `ai.agents.claude.files."prompts/..."`
- `.claude/plugins/local/*` -> `ai.agents.claude.files."plugins/local/..."`

#### Likely outside core or deferred

- `basic-memory` should probably be reconsidered:
  - if it is part of Claude's persistent config tree, map it into `files`
  - if it is your personal workflow add-on, move it out of the framework

### Suggested target

```nix
ai.agents.claude = {
  configDir = ".claude";
  settings = import-or-generate-claude-settings;
  files = {
    "commands/..." = ...;
    "agents/..." = ...;
    "langs/..." = ...;
    "prompts/..." = ...;
    "plugins/local/..." = ...;
  };
};
```

## 4. `~/.config/konfigue/modules/ai/codex.nix`

### What it contains

Materialized Codex files:

- `.codex/config.toml`
- `.codex/notify.nu`
- `.codex/rules/default.rules`

### Mapping

#### Shared core

- `.codex/config.toml` -> `ai.agents.codex.settings`
- `.codex/notify.nu` -> `ai.agents.codex.files."notify.nu"`
- `.codex/rules/default.rules` -> `ai.agents.codex.files."rules/default.rules"`

### Suggested target

```nix
ai.agents.codex = {
  configDir = ".codex";
  settings = import-or-generate-codex-settings;
  files = {
    "notify.nu".source = ./codex/config/notify.nu;
    "rules/default.rules".source = ./codex/config/rules/default.rules;
  };
};
```

## 5. `~/.config/konfigue/modules/ai/wrappers.nix`

### What it contains

For Claude, Codex, Pi:

- alias names (`klaud`, `kodex`, `pai`)
- auto-resume behavior
- nono-on-by-default behavior
- bypass flags inside nono
- host secret loading (`getFnoxSecret`)
- Claude IDE auto-connect behavior
- Pi provider flags

### Mapping

#### Shared core

Only one piece plausibly belongs in the shared core:

- maybe `pkg`, but only if the wrapper derivation itself is the thing you want installed

Even then, the framework should only know that `pkg` is a package. It should not know why.

#### Personal layer

Everything else belongs outside the framework:

- wrapper names
- auto-resume
- nono defaults
- bypass flags
- secret loading
- Neovim auto-connect
- provider selection flags used only for your workflow

### Suggested target

- remove `wrappers.nix` from the shared story entirely
- if you still want these commands, keep them in a separate personal module
- that personal module may choose to set:

```nix
ai.agents.pi.pkg = myPiWrapper;
```

but the framework itself should not define wrapper semantics

## 6. `nix-darvm/guest/modules/claude.nix`

### What it contains

- `dvm.agents.claude` runtime options:
  - `fullAccess`
  - `extraArgs`
- guest wrapper generation
- sourcing `/var/run/dvm-state/global-credentials.env`
- optional npm/pnpm resolution
- mount derivation now comes from rendered agent config

### Mapping

#### Shared core

- `package` -> `ai.agents.claude.pkg`
- `configDir` -> `ai.agents.claude.configDir`

#### DVM adapter

Everything else stays adapter-specific:

- guest wrapper generation
- sourcing global credential env
- npm/pnpm fallback logic
- `fullAccess`
- `extraArgs`
- `dvm.mounts.home`

### Suggested target

The DVM adapter should derive:

- mount `.claude`
- install `ai.renderedAgents.claude.pkg`
- materialize normalized rendered files under `.claude`
- keep any wrapper needed for guest runtime as an internal detail

## 7. `nix-darvm/guest/modules/codex.nix`

### Mapping

Same split as Claude.

#### Shared core

- `package` -> `ai.agents.codex.pkg`
- `configDir` -> `ai.agents.codex.configDir`

#### DVM adapter only

- `fullAccess`
- `extraArgs`
- guest wrapper/env sourcing
- npm/pnpm fallback logic
- `dvm.mounts.home`

## 8. `nix-darvm/guest/modules/pi.nix`

### What it contains

- `dvm.agents.pi.extraArgs`
- guest wrapper
- credential env sourcing
- npm/pnpm resolution
- mount derivation from rendered agent config

### Mapping

#### Shared core

- `package` -> `ai.agents.pi.pkg`
- `configDir` -> `ai.agents.pi.configDir`

#### DVM adapter only

- guest wrapper/env sourcing
- npm/pnpm fallback logic
- `extraArgs`
- DVM-specific notes about `PI_CODING_AGENT_DIR`
- `dvm.mounts.home`

### Suggested target

The core owns Pi's config tree and package.
The DVM adapter owns the mechanics of making Pi run inside the guest.

## 9. `nix-darvm/guest/modules/agents.nix`

### What it contains

- imports for Claude/Codex/Opencode/Pi guest modules

### Mapping

This becomes much thinner or disappears in its current form.

Instead of defining full agent semantics itself, the DVM side should eventually:

- import the shared framework
- consume `ai.renderedAgents`
- expose guest-specific implementation details only

## 10. `agent-modules-wip`

### Current visibility

Direct inspection was blocked in this session (`Operation not permitted`), so this mapping is inferred only from references in `modules/ai/agents.nix`.

### Recommendation

Treat it as a source of reusable content, not as a third configuration framework.

Likely destinations for anything valuable in it:

- reusable instruction fragments -> `instructions`
- reusable skills -> `skills`
- reusable extra files -> `files`

If it contains launcher behavior or workflow assumptions, move those to a separate personal layer instead.

## Proposed per-agent target mapping

## Claude

### Shared core target

```nix
ai.agents.claude = {
  enable = true;
  pkg = ...;
  configDir = ".claude";

  settings = ...;                 # from settings.json
  instructions = [ shared claude-specific ];
  skills = {
    # reminder skills, shared skill dirs, etc.
  };
  files = {
    "commands/..." = ...;
    "agents/..." = ...;
    "langs/..." = ...;
    "prompts/..." = ...;
    "plugins/local/..." = ...;
    # hooks only if they are considered persistent config, not workflow behavior
  };
};
```

### Adapter-only / personal leftovers

- notification hooks
- nono session-context hook
- `nono-hook.sh`
- alias / auto-resume / IDE attach logic
- DVM full-access wrapper flags

## Codex

### Shared core target

```nix
ai.agents.codex = {
  enable = true;
  pkg = ...;
  configDir = ".codex";

  settings = ...;                 # from config.toml
  instructions = [ shared ];
  skills = {
    # shared/reminder skills if desired
  };
  files = {
    "notify.nu" = ...;
    "rules/default.rules" = ...;
  };
};
```

### Adapter-only / personal leftovers

- stop hook / desktop notification behavior
- alias / auto-resume behavior
- DVM full-access wrapper flags

## Pi

### Shared core target

```nix
ai.agents.pi = {
  enable = true;
  pkg = ...;
  configDir = ".pi/agent";

  settings = ...;                 # likely settings.json if you want to manage it declaratively
  instructions = [ shared ];
  skills = {
    # shared/reminder skills if desired
  };
  files = {
    "prompts/..." = ...;
    "themes/..." = ...;
    "extensions/..." = ...;
    # other pi-specific config files as needed
  };
};
```

### Adapter-only / personal leftovers

- wrapper aliases
- provider-selection wrapper flags
- fnox-loaded env vars
- DVM extra args and guest runtime wrapper

## Migration plan recommendation

## Phase 1 — establish shared core without changing behavior

- create `ai.agents.claude`, `ai.agents.codex`, `ai.agents.pi`
- populate them from current config sources
- do not remove existing adapters yet
- use `files` generously rather than modeling too much structure

## Phase 2 — add normalization

- implement `ai.renderedAgents`
- validate collisions
- render settings / instructions / skills into canonical file paths

## Phase 3 — host adapter

- materialize rendered file tree on the host
- optionally reuse Home Manager's Claude/Codex modules where helpful
- keep direct file materialization as the baseline implementation

## Phase 4 — DVM adapter

- derive mounts and packages from `ai.renderedAgents`
- shrink DVM per-agent modules to guest-specific mechanics only
- status: implemented in `guest/modules/ai-agents.nix` plus runtime-only Claude/Codex/Pi guest modules

## Phase 5 — remove framework pollution

- move `wrappers.nix` concerns into a separate personal layer
- remove duplicated agent semantics from DVM guest modules
- either absorb useful content from `agent-modules-wip` into the core or delete it

## Likely end state by file responsibility

### Shared framework

Owns:

- `ai.agents.*`
- normalization to `ai.renderedAgents`
- canonical file ownership rules

### Host adapter

Owns:

- package installation on laptop
- file materialization into `~/.claude`, `~/.codex`, `~/.pi/agent`
- optional reuse of HM per-program modules

### DVM adapter

Owns:

- guest package installation
- guest mount derivation
- guest runtime/env plumbing

### Personal layer

Owns:

- aliases
- auto-resume
- sandbox defaults
- notifications
- local secret manager integration
- IDE/editor integration

## Biggest simplification opportunity

The strongest subtractive move is still:

- stop treating `wrappers.nix` as part of the shared agent configuration story

That one split removes a large amount of conceptual confusion.
