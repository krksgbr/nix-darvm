# AI Agent Config Framework v1 — Nix Schema Sketch

## Status

Proposed

This document turns `plans/ai-agent-config-framework.md` into a more concrete Nix schema sketch.

It is still a design document, not final implementation code.

## Design choices carried forward

- Namespace: `ai.agents.<name>`
- Supported agents in v1: `claude`, `codex`, `pi`
- Keep semantic top-level fields distinct:
  - `pkg`
  - `configDir`
  - `settings`
  - `instructions`
  - `skills`
  - `files`
- Normalize to a rendered file tree consumed by adapters
- Fail loudly on path collisions

## Recommended module shape

Use explicit per-agent options, not an open-ended `attrsOf submodule`.

That means:

```nix
options.ai.agents.claude = ...
options.ai.agents.codex = ...
options.ai.agents.pi = ...
```

This is simpler than supporting arbitrary agent names and keeps the normalization logic honest.

## Shared helper types

Sketch:

```nix
{ lib, pkgs, ... }:
let
  inherit (lib)
    mkOption
    mkEnableOption
    types
    ;

  jsonFormat = pkgs.formats.json { };
  tomlFormat = pkgs.formats.toml { };

  instructionFragmentType = types.either types.lines types.path;

  instructionsType = types.nullOr (
    types.either
      instructionFragmentType
      (types.listOf instructionFragmentType)
  );

  skillContentType = types.either types.lines types.path;

  skillsType = types.attrsOf skillContentType;

  fileEntryType = types.submodule {
    options = {
      text = mkOption {
        type = types.nullOr types.lines;
        default = null;
      };

      source = mkOption {
        type = types.nullOr types.path;
        default = null;
      };
    };
  };

  filesType = types.attrsOf fileEntryType;
in
{
  # ...
}
```

Implementation note:
- `fileEntryType` should assert that exactly one of `text` or `source` is set.
- `types.path` is enough for v1; whether the path is a file or directory is handled during rendering/validation.

## Shared per-agent option builder

Sketch:

```nix
mkAgentOptions = {
  defaultConfigDir,
  settingsType,
}: {
  enable = mkEnableOption "AI agent";

  pkg = mkOption {
    type = types.nullOr types.package;
    default = null;
    description = ''
      Package or wrapper derivation to install for this agent.
    '';
  };

  configDir = mkOption {
    type = types.str;
    default = defaultConfigDir;
    description = ''
      Agent config directory relative to the user's home directory.
    '';
  };

  settings = mkOption {
    type = types.nullOr settingsType;
    default = null;
    description = ''
      Canonical machine-readable settings for this agent.
    '';
  };

  instructions = mkOption {
    type = instructionsType;
    default = null;
    description = ''
      Persistent instructions / memory for this agent.
      May be inline text, a path, or a list of text/path fragments.
    '';
  };

  skills = mkOption {
    type = skillsType;
    default = { };
    description = ''
      Named skill entries for this agent.
      Values may be inline text, a path to a SKILL.md file, or a path to a skill directory.
    '';
  };

  files = mkOption {
    type = filesType;
    default = { };
    description = ''
      Extra files relative to configDir.
      Cannot overlap with paths owned by settings, instructions, or skills.
    '';
  };
};
```

## Public option sketch

```nix
options.ai.agents = {
  claude = mkOption {
    type = types.submodule {
      options = mkAgentOptions {
        defaultConfigDir = ".claude";
        settingsType = jsonFormat.type;
      };
    };
    default = { };
  };

  codex = mkOption {
    type = types.submodule {
      options = mkAgentOptions {
        defaultConfigDir = ".codex";
        settingsType = tomlFormat.type;
      };
    };
    default = { };
  };

  pi = mkOption {
    type = types.submodule {
      options = mkAgentOptions {
        defaultConfigDir = ".pi/agent";
        settingsType = jsonFormat.type;
      };
    };
    default = { };
  };
};
```

## Internal rendered schema

Adapters should consume a normalized internal representation.

Sketch:

```nix
options.ai.renderedAgents = mkOption {
  internal = true;
  readOnly = true;
  type = types.attrsOf (types.submodule {
    options = {
      enable = mkOption {
        type = types.bool;
      };

      pkg = mkOption {
        type = types.nullOr types.package;
      };

      configDir = mkOption {
        type = types.str;
      };

      files = mkOption {
        type = filesType;
      };
    };
  });
  default = { };
};
```

Example normalized value:

```nix
config.ai.renderedAgents.claude = {
  enable = true;
  pkg = pkgs.claude-code;
  configDir = ".claude";
  files = {
    "settings.json".source = ...;
    "CLAUDE.md".text = ...;
    "skills/review/SKILL.md".text = ...;
    "commands/commit.md".source = ./commands/commit.md;
  };
};
```

## Canonical output mapping

### Claude

- `settings` -> `settings.json`
- `instructions` -> `CLAUDE.md`
- `skills` -> `skills/**`

### Codex

- `settings` -> `config.toml`
- `instructions` -> `AGENTS.md`
- `skills` -> `skills/**`

### Pi

- `settings` -> `settings.json`
- `instructions` -> `AGENTS.md`
- `skills` -> `skills/**`

## Normalization helpers

### Render settings

Sketch:

```nix
renderSettings = name: cfg:
  if cfg.settings == null then
    { }
  else
    let
      path =
        if name == "claude" then "settings.json"
        else if name == "codex" then "config.toml"
        else if name == "pi" then "settings.json"
        else throw "unsupported agent: ${name}";

      source =
        if name == "claude" then jsonFormat.generate "claude-settings.json" cfg.settings
        else if name == "codex" then tomlFormat.generate "codex-config.toml" cfg.settings
        else if name == "pi" then jsonFormat.generate "pi-settings.json" cfg.settings
        else throw "unsupported agent: ${name}";
    in
    {
      ${path}.source = source;
    };
```

### Render instructions

Sketch:

```nix
normalizeInstructionFragments = value:
  if value == null then
    [ ]
  else if builtins.isList value then
    value
  else
    [ value ];

renderInstructionText = fragments:
  lib.concatStringsSep "\n\n" (
    map (fragment:
      if lib.isPath fragment then builtins.readFile fragment else fragment
    ) fragments
  );

renderInstructions = name: cfg:
  let
    fragments = normalizeInstructionFragments cfg.instructions;
  in
  if fragments == [ ] then
    { }
  else
    let
      path =
        if name == "claude" then "CLAUDE.md"
        else if name == "codex" then "AGENTS.md"
        else if name == "pi" then "AGENTS.md"
        else throw "unsupported agent: ${name}";
    in
    {
      ${path}.text = renderInstructionText fragments;
    };
```

### Render skills

Sketch:

```nix
mkSkillEntry = skillName: content:
  if lib.isPath content && lib.pathIsDirectory content then
    {
      "skills/${skillName}".source = content;
    }
  else
    {
      "skills/${skillName}/SKILL.md" = {
        text = if lib.isPath content then builtins.readFile content else content;
      };
    };

renderSkills = cfg:
  lib.foldl'
    lib.recursiveUpdate
    { }
    (lib.mapAttrsToList mkSkillEntry cfg.skills);
```

Note: using directory sources under `skills/<name>` is fine in the public schema, but adapters must be prepared to materialize directory-backed file entries correctly.

### Render extras

```nix
renderFiles = cfg: cfg.files;
```

## Collision detection

The normalization step should calculate owned paths and fail if `files` overlaps them.

Sketch:

```nix
ownedPathsFor = name: cfg:
  let
    settingsPaths = lib.optional (cfg.settings != null) (
      if name == "claude" then "settings.json"
      else if name == "codex" then "config.toml"
      else "settings.json"
    );

    instructionPaths = lib.optional (cfg.instructions != null) (
      if name == "claude" then "CLAUDE.md" else "AGENTS.md"
    );

    skillPaths = lib.flatten (
      lib.mapAttrsToList (skillName: content:
        if lib.isPath content && lib.pathIsDirectory content then
          [ "skills/${skillName}" ]
        else
          [ "skills/${skillName}/SKILL.md" ]
      ) cfg.skills
    );
  in
  settingsPaths ++ instructionPaths ++ skillPaths;

extraFilePaths = cfg: builtins.attrNames cfg.files;

assertNoOwnedPathOverlap = name: cfg:
  let
    overlaps = lib.intersectLists (ownedPathsFor name cfg) (extraFilePaths cfg);
  in
  {
    assertion = overlaps == [ ];
    message = ''
      ai.agents.${name}.files overlaps with paths owned by higher-level fields: ${lib.concatStringsSep ", " overlaps}
    '';
  };
```

Implementation note:
- prefix overlap should also be checked for directory-backed skill entries, not only exact path equality.
- Example: `files."skills/foo/SKILL.md"` must conflict with `skills.foo = ./dir`.
- Example: `files."skills/foo/extra.txt"` must also conflict with `skills.foo = ./dir`.

So the real implementation should check both exact path collisions and parent/child subtree collisions.

## Final rendered agent computation

Sketch:

```nix
renderAgent = name: cfg: {
  enable = cfg.enable;
  pkg = cfg.pkg;
  configDir = cfg.configDir;
  files =
    lib.recursiveUpdate
      (renderSettings name cfg)
      (lib.recursiveUpdate
        (renderInstructions name cfg)
        (lib.recursiveUpdate
          (renderSkills cfg)
          (renderFiles cfg)));
};
```

With assertions registered separately.

## Adapter sketches

### Host adapter

Minimal host adapter sketch:

```nix
config = {
  home.packages = lib.flatten (
    lib.mapAttrsToList (_: rendered:
      lib.optional (rendered.enable && rendered.pkg != null) rendered.pkg
    ) config.ai.renderedAgents
  );

  home.file = lib.mkMerge (
    lib.mapAttrsToList (_: rendered:
      lib.mapAttrs'
        (relPath: entry:
          lib.nameValuePair "${rendered.configDir}/${relPath}" entry
        )
        rendered.files
    ) (lib.filterAttrs (_: v: v.enable) config.ai.renderedAgents)
  );
};
```

This direct file-materialization path should work even without reusing Home Manager's program modules.

If desired, the host adapter can later special-case Claude and Codex and map them into `programs.claude-code` / `programs.codex`, but that is not necessary for v1.

### DVM adapter

Minimal DVM adapter sketch:

```nix
config = {
  environment.systemPackages = lib.flatten (
    lib.mapAttrsToList (_: rendered:
      lib.optional (rendered.enable && rendered.pkg != null) rendered.pkg
    ) config.ai.renderedAgents
  );

  dvm.mounts.home = lib.flatten (
    lib.mapAttrsToList (_: rendered:
      lib.optional rendered.enable rendered.configDir
    ) config.ai.renderedAgents
  );

  # File materialization strategy left to the DVM adapter implementation.
  # It should consume the same rendered file tree under rendered.configDir.
};
```

Important: any guest runtime wrappers needed for env sourcing or DVM-specific behavior should remain adapter internals, not public schema.

## Example user configuration

```nix
{
  ai.agents.claude = {
    enable = true;
    pkg = pkgs.claude-code;
    instructions = [
      ./instructions/shared.md
      ./instructions/claude.md
    ];
    settings = {
      model = "claude-sonnet-4";
      includeCoAuthoredBy = false;
    };
    skills = {
      review = ./skills/review;
      remind-galls-law = ./skills/remind-galls-law/SKILL.md;
    };
    files."commands/commit.md".source = ./claude/commands/commit.md;
  };

  ai.agents.codex = {
    enable = true;
    pkg = pkgs.codex;
    instructions = ./instructions/shared.md;
    settings = {
      model = "gpt-5-codex";
    };
    files."rules/default.rules".source = ./codex/default.rules;
  };

  ai.agents.pi = {
    enable = true;
    pkg = myPiWrapper;
    instructions = ./instructions/shared.md;
    settings = {
      theme = "dark";
    };
    skills = {
      review = ./skills/review;
    };
    files."prompts/review.md".source = ./pi/prompts/review.md;
  };
}
```

## Recommendation

Implement the first version with:

- explicit per-agent options
- direct file-tree normalization
- strict collision checks
- simple host adapter using rendered file materialization
- simple DVM adapter consuming the same rendered output

That is the smallest complete system that preserves the right abstractions without dragging wrappers or personal workflow into the core.
