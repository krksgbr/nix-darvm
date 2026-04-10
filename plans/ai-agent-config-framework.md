# AI Agent Config Framework v1

## Status

Proposed

## Goal

Define one declarative configuration framework that can configure coding agents on:

- the host laptop
- DVM guests

The framework should:

- be generic Nix / nix-darwin oriented, not DVM-specific
- avoid encoding personal workflow ergonomics
- support a small initial set of agents well
- compile to a simple internal representation that multiple adapters can consume

## Initial scope

Supported agents in v1:

1. Claude
2. Codex
3. Pi

Everything else is deferred.

## Non-goals

This framework is **not** responsible for:

- launch aliases (`klaud`, `kodex`, `pai`)
- auto-resume behavior
- sandbox policy (`nono`, `confine`)
- secret manager integration (`fnox`, host env bootstrapping, etc.)
- editor attachment / IDE integration
- notifications
- DVM runtime wrapper UX

Those belong in separate host-specific, DVM-specific, or personal workflow modules.

## Namespace

Use:

```nix
ai.agents.<name>
```

Examples:

```nix
ai.agents.claude
ai.agents.codex
ai.agents.pi
```

Rationale:

- this is not a single `programs.*` module
- it should work across host and guest adapters
- it leaves room for future `ai.*` configuration without pretending this is one program

## Public schema

V1 public schema:

```nix
ai.agents.<name> = {
  enable = true;

  pkg = null;        # package or wrapper derivation
  configDir = null;  # optional override; defaults per agent

  settings = null;      # structured, agent-specific settings
  instructions = null;  # canonical persistent guidance / memory
  skills = { };         # named skill entries
  files = { };          # arbitrary extra files relative to configDir
};
```

## Defaults

Per-agent defaults:

- Claude: `configDir = ".claude"`
- Codex: `configDir = ".codex"`
- Pi: `configDir = ".pi/agent"`

## Field semantics

### `pkg`

The runtime package to install or expose.

This may be:

- a normal package
- a custom wrapper derivation
- any other package-like output the caller wants to use

The framework does not care how the executable is produced.

### `settings`

The canonical machine-readable settings for the agent.

This is intentionally agent-specific structured data. The adapter knows how to render it.

Canonical output paths:

- Claude -> `settings.json`
- Codex -> `config.toml`
- Pi -> `settings.json`

### `instructions`

The canonical persistent guidance / memory for the agent.

This should support composition from fragments and render to the agent's canonical instructions file.

Canonical output paths:

- Claude -> `CLAUDE.md`
- Codex -> `AGENTS.md`
- Pi -> `AGENTS.md`

Recommended v1 shape:

```nix
null | string | path | listOf (string | path)
```

The normalized renderer concatenates fragments with newline separation.

### `skills`

The canonical skill set for the agent.

Recommended v1 shape:

```nix
{
  <skill-name> = <inline text | path-to-SKILL.md | path-to-skill-dir>;
}
```

Rendered under the agent's `skills/` subtree.

Examples:

- inline text -> generate `skills/<name>/SKILL.md`
- path to file -> generate `skills/<name>/SKILL.md` from file contents
- path to directory -> materialize that directory at `skills/<name>/`

### `files`

Arbitrary extra files relative to `configDir`.

This is the escape hatch for agent-specific features that are not modeled yet.

Examples:

- Claude commands, hooks, rules, output styles
- Codex rules or other extra files
- Pi prompts, themes, extensions, extra config files

Recommended v1 shape:

```nix
files."relative/path" = {
  text = "...";
};

files."relative/path" = {
  source = ./path;
};
```

Only one of `text` or `source` is allowed per file entry.

## Internal normalized representation

The public schema is compiled into a simple internal form.

```nix
ai.renderedAgents.<name> = {
  enable = true;
  pkg = ...;
  configDir = ".claude";
  files = {
    "settings.json" = { source = ...; };
    "CLAUDE.md" = { text = ...; };
    "skills/foo/SKILL.md" = { text = ...; };
    "commands/review.md" = { source = ...; };
  };
};
```

This rendered file tree is the only thing adapters should consume.

## Ownership and collision rules

Higher-level fields own canonical paths.

### Claude owned paths

- `settings.json`
- `CLAUDE.md`
- `skills/**`

### Codex owned paths

- `config.toml`
- `AGENTS.md`
- `skills/**`

### Pi owned paths

- `settings.json`
- `AGENTS.md`
- `skills/**`

Rules:

1. `files` may not target paths owned by `settings`, `instructions`, or `skills`.
2. If two higher-level fields render the same path, evaluation fails.
3. There is no silent precedence.
4. To fully hand-manage a canonical file, leave the higher-level field unset and use `files` explicitly.

This keeps the model explicit and fail-loud.

## Adapter model

The framework should have separate adapters that consume `ai.renderedAgents`.

### Host adapter

Responsibilities:

- install `pkg` when non-null
- materialize the rendered file tree under each agent's `configDir`
- optionally reuse Home Manager program modules internally when helpful

Important: Home Manager modules are implementation helpers for the host adapter, not the canonical schema.

For example:

- Claude host adapter may map to `programs.claude-code`
- Codex host adapter may map to `programs.codex`
- Pi host adapter may materialize files directly

### DVM adapter

Responsibilities:

- install `pkg` when non-null
- mount each enabled agent's `configDir`
- materialize the same rendered file tree in the guest-visible home
- keep any guest runtime wrappers as adapter implementation details

Important: DVM-specific runtime plumbing is not part of the shared framework API.

## Relationship to existing Home Manager modules

Existing Home Manager modules for Claude and Codex are useful, but they should not define the shared schema.

Use them as:

- inspiration for option coverage
- optional host adapter backends

Do **not** make their option trees the canonical cross-environment model. They are:

- Home Manager specific
- per-program
- asymmetrical across agents

The shared framework should remain smaller and more uniform.

## Why not make everything just `files`?

Because the user-facing schema should capture intent, not only output bytes.

These are distinct concepts even though they all lower to files:

- `settings` = canonical machine-readable agent configuration
- `instructions` = canonical persistent guidance / memory
- `skills` = canonical skill bundles
- `files` = arbitrary extras / escape hatch

The framework should preserve those semantic distinctions in its public API while compiling to a simple file-tree representation internally.

## Why not add more structured fields now?

Fields like these are intentionally deferred:

- hooks
- commands
- rules
- prompts
- themes
- extensions
- MCP configuration

These concepts are either:

- too agent-specific
- not shared consistently across Claude, Codex, and Pi
- easy to express via `files` for now

V1 should stay small.

## Suggested implementation strategy

1. Implement the `ai.agents` schema and validation.
2. Implement normalization into `ai.renderedAgents`.
3. Build a host adapter against the normalized representation.
4. Build a DVM adapter against the same normalized representation.
5. Keep personal ergonomics in separate modules.

## Out of scope for v1

- arbitrary custom agent names
- launcher abstractions
- shell aliases
- auto-resume policies
- sandbox policies
- notifications
- secret injection / auth bootstrapping
- plan mode / task systems / workflow orchestration
- modeling every tool-specific directory or file type

## Open questions

1. Exact validation rules for skill names and directory layout
2. Whether `instructions` should support richer fragment metadata later
3. Whether the normalized file representation should allow executable-bit metadata
4. Whether host materialization should be via Home Manager, hjem, or a simpler shared file adapter in each environment

## Recommendation

Start with the smallest useful shared model:

- `pkg`
- `configDir`
- `settings`
- `instructions`
- `skills`
- `files`

Compile that to a rendered file tree, and keep both host and DVM adapters thin.
