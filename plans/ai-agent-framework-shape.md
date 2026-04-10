# AI Agent Config Framework v1 — Flake and Module Shape

## Status

Proposed

This document specifies the **package/module shape** of the new framework.

It is intended as the successor to:

- `~/.config/konfigue/flakes/agent-modules-wip`

but with a new core model centered on:

```nix
ai.agents.<name>
```

rather than the older:

```nix
programs.agents.*
```

## Goal

Provide a reusable flake that:

- exports **flake-parts modules**
- exports **nix-darwin modules**
- does **not** assume DVM
- can still be consumed by DVM as a downstream adapter
- cleanly separates:
  - shared agent-home configuration
  - host materialization
  - DVM-specific behavior
  - personal workflow behavior

## Key decision

The shared framework should export:

- a **core nix-darwin module** that defines `ai.agents` and `ai.renderedAgents`
- one or more **host materialization nix-darwin modules**
- a **flake-parts module** that registers those nix-darwin modules into `flake.modules.darwin`

It should **not** contain a DVM adapter.

DVM should consume the shared framework as a downstream nix-darwin module and define its own adapter in the `nix-darvm` repo.

## Why this is the right split

This respects the desired boundaries:

- the framework is generic nix-darwin infrastructure
- DVM remains a consumer, not a defining assumption
- the host can choose a file materialization backend
- personal launch wrappers do not leak into the framework

## Proposed repository layout

```text
flake.nix
README.md

lib/
  ai-agents.nix

modules/
  ai-agents/
    README.md
    core.nix
    darwin-home-manager.nix
    darwin-hjem.nix
    flake-parts.nix
```

### Responsibilities

#### `lib/ai-agents.nix`

Pure helper library.

Owns:

- per-agent conventions
- settings/instructions/skills rendering helpers
- collision detection helpers
- file-tree normalization helpers

It should not define options directly.

#### `modules/ai-agents/core.nix`

Core nix-darwin module.

Owns:

- `options.ai.agents.{claude,codex,pi}`
- `options.ai.renderedAgents`
- validation
- normalization from semantic config to rendered file tree

This module is the stable contract for downstream adapters.

#### `modules/ai-agents/darwin-home-manager.nix`

Host adapter for nix-darwin systems that use Home Manager.

Owns:

- importing `core.nix`
- installing `pkg` values into `home.packages` or equivalent
- materializing rendered files into the user's home via `home.file`

This module is allowed to depend on Home Manager semantics.

#### `modules/ai-agents/darwin-hjem.nix`

Host adapter for nix-darwin systems that use hjem.

Owns:

- importing `core.nix`
- materializing rendered files via hjem-managed user files

This module is allowed to depend on hjem semantics.

#### `modules/ai-agents/flake-parts.nix`

Consumer convenience module for flake-parts-based configs.

Owns:

- registering the nix-darwin modules into `flake.modules.darwin`
- exposing stable names for the modules

It should not add new behavior beyond wiring and discoverability.

## Proposed flake outputs

The flake should export a small, boring surface.

## `lib`

```nix
lib.ai-agents
```

Exports normalization / convention helpers.

## `darwinModules`

```nix
darwinModules.ai-agents-core
darwinModules.ai-agents-home-manager
darwinModules.ai-agents-hjem
```

These are the main public integration surfaces.

## `flakeModules`

```nix
flakeModules.ai-agents
```

This is the flake-parts adapter that registers the darwin modules into the consuming flake.

## What not to export in v1

Do not export in v1:

- Home Manager modules directly
- hjem modules directly
- DVM modules
- launcher/wrapper packages
- skill sync shell hooks
- project-level `.claude`/`.codex` synchronization helpers

Reason:
- the public API should stay aligned with the new boundary: nix-darwin + flake-parts
- DVM and personal workflow belong downstream

## Proposed `flake.nix` shape

Sketch:

```nix
{
  description = "Declarative AI agent config for nix-darwin";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    hjem.url = "github:feel-co/hjem";
  };

  outputs = { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;
    in {
      lib.ai-agents = import ./lib/ai-agents.nix { inherit lib; };

      darwinModules = {
        ai-agents-core = import ./modules/ai-agents/core.nix;
        ai-agents-home-manager = import ./modules/ai-agents/darwin-home-manager.nix;
        ai-agents-hjem = import ./modules/ai-agents/darwin-hjem.nix;
      };

      flakeModules = {
        ai-agents = import ./modules/ai-agents/flake-parts.nix;
      };
    };
}
```

This mirrors the simplicity of `agent-modules-wip`, but updates the exported surfaces to match the new architecture.

## Proposed `flake-parts` module shape

This module should act as a re-export / registration layer for consumers using flake-parts.

Sketch:

```nix
_: {
  flake.modules.darwin = {
    "ai/agents/core" = import ./core.nix;
    "ai/agents/home-manager" = import ./darwin-home-manager.nix;
    "ai/agents/hjem" = import ./darwin-hjem.nix;
  };
}
```

This matches your existing `flake.modules.darwin."..."` usage style in `konfigue`.

## Proposed core nix-darwin module responsibilities

`modules/ai-agents/core.nix` should be pure in the sense that it does **not** choose a home file backend.

It should:

- define:

```nix
ai.agents.claude
ai.agents.codex
ai.agents.pi
```

- compute:

```nix
ai.renderedAgents.claude
ai.renderedAgents.codex
ai.renderedAgents.pi
```

- expose a normalized file tree per enabled agent:

```nix
{
  enable = true;
  pkg = ...;
  configDir = ".claude";
  files = {
    "settings.json" = { source = ...; };
    "CLAUDE.md" = { text = ...; };
    ...
  };
}
```

It should **not**:

- install packages
- write files into the home directory
- mount DVM home dirs
- create runtime wrappers
- patch mutable runtime state

## Proposed host adapter module responsibilities

### `darwin-home-manager.nix`

This should:

- import `core.nix`
- consume `config.ai.renderedAgents`
- install packages for enabled agents
- project the rendered file tree into `home.file`

Sketch:

```nix
{
  lib,
  config,
  ...
}:
{
  imports = [ ./core.nix ];

  config = {
    home.packages = ...;
    home.file = ...;
  };
}
```

### `darwin-hjem.nix`

This should:

- import `core.nix`
- consume `config.ai.renderedAgents`
- project the rendered file tree into hjem file declarations

Sketch:

```nix
{
  lib,
  config,
  ...
}:
{
  imports = [ ./core.nix ];

  config = {
    files = ...;
  };
}
```

## Should there be a single default host adapter?

### Recommendation

No, not in v1.

Export both:

- `ai-agents-home-manager`
- `ai-agents-hjem`

Why:

- this preserves the successful adapter pattern from `agent-modules-wip`
- it avoids forcing a premature choice between Home Manager and hjem
- it keeps the shared core independent of the file materialization backend

## Where the DVM adapter should live

In `nix-darvm`, not in this framework.

Suggested shape in `nix-darvm` later:

```text
guest/modules/ai-agents-dvm.nix
```

Responsibilities:

- import the shared `ai-agents-core` module
- consume `config.ai.renderedAgents`
- derive:
  - `dvm.mounts.home`
  - guest package installation
  - any guest-specific runtime wrapper glue

This keeps DVM-specific semantics downstream.

## How a consumer should use this

## Option A: plain nix-darwin module import

Home Manager-backed host:

```nix
{
  imports = [ inputs.ai-agent-framework.darwinModules.ai-agents-home-manager ];

  ai.agents.claude = {
    enable = true;
    pkg = pkgs.claude-code;
    instructions = [ ./instructions/shared.md ./instructions/claude.md ];
    settings = { ... };
  };
}
```

Hjem-backed host:

```nix
{
  imports = [ inputs.ai-agent-framework.darwinModules.ai-agents-hjem ];

  ai.agents.codex = {
    enable = true;
    pkg = pkgs.codex;
    instructions = ./instructions/shared.md;
    settings = { ... };
  };
}
```

## Option B: flake-parts import

```nix
{
  imports = [ inputs.ai-agent-framework.flakeModules.ai-agents ];

  flake.modules.darwin."my/agent-stack" = {
    imports = [
      config.flake.modules.darwin."ai/agents/home-manager"
    ];

    ai.agents.pi = {
      enable = true;
      pkg = myPiWrapper;
      instructions = ./instructions/shared.md;
      files."prompts/review.md".source = ./pi/prompts/review.md;
    };
  };
}
```

## Relationship to `agent-modules-wip`

## What should be preserved

Preserve these good ideas from `agent-modules-wip`:

- small boring flake outputs
- adapter pattern
- clear separation between common logic and backend-specific materialization
- flake-parts integration for registration/convenience

## What should change

Replace these old assumptions:

### Old

```nix
programs.agents = {
  skills = ...;
  claude.md = ...;
  codex.md = ...;
  pi.md = ...;
}
```

### New

```nix
ai.agents.claude = {
  instructions = ...;
  settings = ...;
  skills = ...;
  files = ...;
};
```

### Old

- public HM / hjem-specific configuration shape
- hook-patching-centric abstraction
- skills-first shared model

### New

- agent-home-centric shared model
- normalized rendered file tree
- host adapters and DVM adapter consume the same internal representation

## What to defer from `agent-modules-wip`

Do not carry forward in v1:

- Gemini
- Opencode
- hook patching as a first-class framework concept
- project-level skill sync shell hooks
- extra package outputs unrelated to the core framework

These can return later if the new model proves a need for them.

## Recommended implementation order

1. Create the new flake with the proposed output shape.
2. Implement `lib/ai-agents.nix`.
3. Implement `modules/ai-agents/core.nix`.
4. Implement one host adapter first:
   - whichever backend you want to use first in practice
5. Add the second host adapter.
6. Update `konfigue` to consume the new framework.
7. Only then add the DVM adapter in `nix-darvm`.

## Recommendation

Treat the new framework as the direct successor to `agent-modules-wip`, but narrow and sharpen it:

- **same overall adapter architecture**
- **new `ai.agents` core model**
- **nix-darwin + flake-parts as the public integration surfaces**
- **DVM as a downstream consumer, not a built-in concern**
