# Sensible defaults for sandbox VMs.
# Imported by default; consumers can override or omit.
{ lib, pkgs, username ? "admin", ... }:
{
  # -- Zsh --
  programs.zsh.enable = true;
  # Disable default prompt — starship takes over.
  programs.zsh.promptInit = lib.mkForce "";
  programs.zsh.interactiveShellInit = ''
    # Vi mode
    bindkey -v
    KEY_TIMEOUT=10

    # History
    HISTSIZE=10000
    SAVEHIST=10000
    setopt SHARE_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_SPACE

    # Completions
    autoload -Uz compinit && compinit -u
    zstyle ':completion:*' menu select
    zstyle ':completion:*' matcher-list 'm:{[:lower:]}={[:upper:]}'
    zstyle ':completion:*' group-name ""
    zstyle ':completion:*' verbose yes

    # Starship prompt
    eval "$(starship init zsh)"
  '';

  # -- Starship --
  environment.systemPackages = [ pkgs.starship ];

  # -- User-level config (via hjem) --
  users.users.${username}.home = "/Users/${username}";

  hjem.users.${username} = {
    enable = true;

    # Starship prompt config
    xdg.config.files."starship.toml".text = ''
      format = "$hostname$directory$git_branch$git_status$nix_shell\n$character"

      [hostname]
      disabled = false
      format = "[](fg:bright-red)[ sandbox ](bold fg:0 bg:bright-red)[](fg:bright-red) "
      ssh_only = true

      [directory]
      format = "[$path]($style) "

      [git_branch]
      format = "[·](bright-green) [$branch]($style) "

      [git_status]
      format = "[$all_status$ahead_behind]($style)"

      [nix_shell]
      format = " [·](bright-green) [❄](blue)"

      [character]
      success_symbol = '[\[dvm\]](bright-purple) [\$](green)'
      error_symbol = '[\[dvm\]](bright-purple) [\$](red)'
    '';
  };
}
