# Credentials Injection Design

Mechanism for securely injecting credentials into the guest VM without leaking the actual secrets or baking them into the immutable Nix store. Credentials can be scoped locally to a specific project or globally for interactive shells and agent entrypoints.

## 1. Project-Local Secrets

Mechanism for scoping credentials to individual projects so that multiple projects can use the proxy simultaneously without cross-project leakage.

### credentials.toml format

```toml
version = 0
project = "nix-darvm"

[proxy.ANTHROPIC_API_KEY]
hosts = ["api.anthropic.com"]

[passthrough.GITHUB_TOKEN]
from.env = "GH_TOKEN"

[proxy.OPENAI_API_KEY]
hosts = ["api.openai.com"]
from.command = ["op", "read", "op://Engineering/OpenAI/api key"]
```

- **`project`** (required for local scopes): human-readable project name. Serves as the namespace in placeholder tokens. Must be unique across loaded projects. Compared after normalization (lowercase, strip whitespace).
- **`proxy.<ENV_VAR>`**: the TOML key is the env var injected into the guest as a placeholder. This is also the secret's identity for placeholder derivation. The proxy does string replacement of placeholder → real value.
- **`passthrough.<ENV_VAR>`**: real value is injected directly as an env var, no proxy interception.
- **`hosts`** (proxy only): which upstream hosts this secret applies to.
- **`from`** (optional): how the host resolves the real secret value.
  - Omitted: read the host env var with the same name as the TOML key.
  - `from.env = "HOST_ENV_VAR"`: read a different host env var.
  - `from.command = ["program", "arg1", ...]`: run a host command and use trimmed stdout.

### Why `project` is required

From the design history, the `project` key is explicitly required in project-local scopes for three reasons:

1. **Path-independence (Multiple Checkouts)**: If you check out the same repo in `~/src/work/nix-darvm` and `~/Downloads/nix-darvm-test`, both have the same `.dvm/credentials.toml` (since it contains no secrets and is meant to be committed). Because the `project` key is explicitly "nix-darvm", both checkouts generate the exact same placeholder (`SANDBOX_CRED_nix-darvm_anthropic_8f3a...`). If DVM inferred the project from the directory path, the two checkouts would generate different placeholders for the same logical project, breaking shared caches or causing unexpected proxy collisions.
2. **Traceability**: The project name is directly injected into the placeholder prefix (`SANDBOX_CRED_{project}_{secret}_{hmac}`). This makes debugging inside the guest much easier, as you can instantly see which project a placeholder belongs to just by running `env`.
3. **Collision Detection**: The `project` key acts as a rigid namespace. If two different codebases accidentally use the same project name in their `credentials.toml`, DVM can loudly fail at load time with a conflict error, rather than silently routing secrets to the wrong domains.

### Credential lifecycle

`dvm start` boots the VM and proxy with no project credentials. 
Project credentials are resolved implicitly at `dvm exec` / `dvm shell` time:
1. Discover manifest (`--credentials` flag > `DVM_CREDENTIALS` env > `.dvm/credentials.toml` in cwd).
2. Resolve each secret from its `from` source. If omitted, read the same-named host env var. If any source is missing, empty, or exits non-zero, fail loudly.
3. Generate deterministic placeholders using HMAC-SHA256 and the host-side `HostKey`.
4. Push placeholder→value mappings to the sidecar proxy.
5. Inject placeholder env vars into the guest session.

---

## 2. Global Secrets

Mechanism for securely injecting global credentials (e.g. LLM API keys for coding agents) into all guest VM sessions, using the same sidecar proxy infrastructure as project-local secrets.

Some tools, especially coding-agent CLIs like Claude Code or Codex, are run from generic shells or dedicated wrapper commands rather than a `dvm exec` tied to a specific project. They need global API keys.

### Context and Constraints

We evaluated two alternative paths:
1. **Nix-native Configuration**: Define global secrets via `dvm.secrets` in the Nix flake and let the host parse the closure JSON. Rejected because secrets are fundamentally a runtime/host concern, whereas Nix is for structural/immutable configuration. Baking placeholder generation into the immutable Nix layer breaks the separation of concerns.
2. **External Resolver File**: Split manifest declaration from host-specific resolution into a second `~/.config/dvm/resolvers.toml`. Rejected because it fragments the mental model. The chosen design keeps resolution colocated with each secret entry while still defaulting to same-name host env lookup.

### Central Configuration (`~/.config/dvm/credentials.toml`)

Users define global secrets using the exact same TOML schema as project secrets, but located centrally on the host. 

```toml
version = 0

[proxy.ANTHROPIC_API_KEY]
hosts = ["api.anthropic.com"]

[proxy.OPENAI_API_KEY]
hosts = ["api.openai.com"]
from.command = ["op", "read", "op://Engineering/OpenAI/api key"]
```

The global manifest omits `project`. Its location at `~/.config/dvm/credentials.toml` implies the reserved scope `__global__`.

### Boot-Time Resolution

Unlike project secrets which are pushed per-`dvm exec`, global secrets are resolved once at `dvm start` time:
1. `dvm-core` checks for `~/.config/dvm/credentials.toml`.
2. It parses the manifest and generates unguessable HMAC placeholders (`SANDBOX_CRED_global_anthropic_api_key_...`).
3. It resolves the real secrets from each secret's `from` source. If `from` is omitted, it reads `ProcessInfo.processInfo.environment` from the terminal running `dvm start`.
4. It sends a `load` command to the sidecar proxy with the project name `__global__` and the real secrets.

### Guest Environment Injection (`dvm-state`)

To make these placeholders available to interactive shells and agent wrapper commands inside the VM:
1. `dvm-core` writes the exported placeholders to a `.env` file on the host's state directory, which is VirtioFS-mounted directly into the guest.
   ```bash
   # Host writes to ~/.local/state/dvm/global-credentials.env
   export ANTHROPIC_API_KEY=SANDBOX_CRED_global_anthropic_api_key_123abc...
   ```
2. The boot-time image script mounts that state directory at `/var/run/dvm-state`.
3. Interactive shell init and coding-agent wrapper scripts source `/var/run/dvm-state/global-credentials.env` directly when they start.

### Lifecycle Trade-offs

Because global secrets are evaluated at `dvm start`:
- If you use the default env-based resolution, you must export your global API keys in your host terminal *before* running `dvm start`.
- If you use `from.command`, `dvm start` can fetch secrets directly without pre-exporting them into the shell environment.
- If you rotate a global API key, you must restart the VM (`Ctrl-C` and `dvm start` again) to inject the new value. (Project-local secrets, by contrast, are dynamically picked up on the next `dvm exec` without a restart). This is an acceptable tradeoff for the simplicity of eliminating `fetch_command` polling.
