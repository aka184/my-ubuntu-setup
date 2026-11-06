#!/usr/bin/env bash
# setup-ubuntu.sh — replicate Indranil's Arch apps + terminal on Ubuntu 24.04
#
# - Does NOT run `apt upgrade` / `dist-upgrade` / do-release-upgrade.
# - Uses `apt-get install --no-upgrade`, so already-installed packages are left alone.
# - `apt-get update` is only run after adding a new repo (index refresh, not an upgrade).
# - Every step is non-fatal; failures are listed at the end.
#
# Usage:  chmod +x setup-ubuntu.sh && ./setup-ubuntu.sh
# Run as your normal user (NOT with sudo). It calls sudo when needed.

set -uo pipefail

# ------------------------------ toggles ------------------------------
INSTALL_TERMINAL=1
INSTALL_APPS=1
INSTALL_FLATPAKS=1
INSTALL_GNOME_EXTENSIONS=1
INSTALL_DOCKER=1
INSTALL_OLLAMA=1
PULL_OLLAMA_MODELS=0     # big downloads: lfm2.5:8b granite4.1-guardian:8b qwen3:14b qwen3:8b (+qwen3-cad)
EXPOSE_OLLAMA=0          # 1 = listen on 0.0.0.0:11434 (what you had for Odysseus); exposes it to your LAN
INSTALL_ROS=1            # ROS 2 Jazzy (native on 24.04)
INSTALL_AI_TOOLS=1       # uv, miniconda, HF CLI, unsloth

# ------------------------------ helpers ------------------------------
if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal user, not root/sudo." >&2
  exit 1
fi

FAILED=()
log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!! %s\033[0m\n' "$*" >&2; }
try()  { "$@" || { FAILED+=("$*"); warn "failed: $*"; }; }
apt_i() { sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-upgrade "$@"; }
apt_each() { for p in "$@"; do apt_i "$p" || { FAILED+=("apt:$p"); warn "apt package failed: $p"; }; done; }
have() { command -v "$1" >/dev/null 2>&1; }

mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications" "$HOME/.config" "$HOME/bin"
export PATH="$HOME/.local/bin:$PATH"

sudo -v || exit 1

# ------------------------------ base ------------------------------
log "Base packages"
apt_each curl wget git unzip ca-certificates gnupg software-properties-common \
         build-essential pipx fontconfig xclip wl-clipboard usbutils
pipx ensurepath >/dev/null 2>&1 || true

# ------------------------------ terminal ------------------------------
if [[ $INSTALL_TERMINAL == 1 ]]; then
  log "Terminal tools"
  apt_each zsh fzf bat fd-find ripgrep zoxide eza btop

  # Ubuntu names: batcat / fdfind
  have batcat && ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat"
  have fdfind && ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"

  # eza fallback repo if universe didn't have it
  if ! have eza; then
    sudo mkdir -p /etc/apt/keyrings
    wget -qO- https://raw.githubusercontent.com/eza-community/eza/main/deb.asc \
      | sudo gpg --dearmor -o /etc/apt/keyrings/gierens.gpg
    echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" \
      | sudo tee /etc/apt/sources.list.d/gierens.list >/dev/null
    sudo chmod 644 /etc/apt/keyrings/gierens.gpg /etc/apt/sources.list.d/gierens.list
    sudo apt-get update && apt_i eza || FAILED+=("eza")
  fi

  # fastfetch (PPA — not in 24.04 repos)
  if ! have fastfetch; then
    try sudo add-apt-repository -y ppa:zhangsongcui3371/fastfetch
    try apt_i fastfetch
  fi

  # starship
  have starship || try sh -c 'curl -sS https://starship.rs/install.sh | sh -s -- -y'

  # lazygit (not in apt)
  if ! have lazygit; then
    LG_VER=$(curl -s https://api.github.com/repos/jesseduffield/lazygit/releases/latest | grep -Po '"tag_name": *"v\K[^"]*')
    if [[ -n "${LG_VER:-}" ]]; then
      curl -fLo /tmp/lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LG_VER}_Linux_x86_64.tar.gz" \
        && tar -xf /tmp/lazygit.tar.gz -C /tmp lazygit \
        && sudo install /tmp/lazygit /usr/local/bin \
        || FAILED+=("lazygit")
    else
      FAILED+=("lazygit (couldn't resolve version)")
    fi
  fi

  # ---------- Nerd Fonts ----------
  log "Nerd Fonts (JetBrainsMono, FantasqueSansM)"
  FONT_DIR="$HOME/.local/share/fonts/NerdFonts"
  mkdir -p "$FONT_DIR"
  for f in JetBrainsMono FantasqueSansMono; do
    curl -fL "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/${f}.zip" -o "/tmp/${f}.zip" \
      && unzip -oq "/tmp/${f}.zip" -d "$FONT_DIR/$f" \
      || FAILED+=("font:$f")
  done
  fc-cache -f >/dev/null 2>&1

  # ---------- kitty (official installer: newer than apt, supports cursor_trail) ----------
  log "kitty"
  if [[ ! -x "$HOME/.local/kitty.app/bin/kitty" ]]; then
    try sh -c 'curl -fsSL https://sw.kovidgoyal.net/kitty/installer.sh | sh /dev/stdin launch=n'
  fi
  KITTY_APP="$HOME/.local/kitty.app"
  if [[ -x "$KITTY_APP/bin/kitty" ]]; then
    ln -sf "$KITTY_APP/bin/kitty" "$KITTY_APP/bin/kitten" "$HOME/.local/bin/"
    cp "$KITTY_APP/share/applications/kitty.desktop" "$HOME/.local/share/applications/"
    cp "$KITTY_APP/share/applications/kitty-open.desktop" "$HOME/.local/share/applications/"
    sed -i "s|Icon=kitty|Icon=$KITTY_APP/share/icons/hicolor/256x256/apps/kitty.png|g" "$HOME"/.local/share/applications/kitty*.desktop
    sed -i "s|Exec=kitty|Exec=$KITTY_APP/bin/kitty|g" "$HOME"/.local/share/applications/kitty*.desktop
  fi

  mkdir -p "$HOME/.config/kitty/kitty-themes"
  touch "$HOME/.config/kitty/kitty-themes/00-Default.conf"
  [[ -f $HOME/.config/kitty/kitty.conf ]] && cp "$HOME/.config/kitty/kitty.conf" "$HOME/.config/kitty/kitty.conf.bak"
  cat > "$HOME/.config/kitty/kitty.conf" <<'EOF'
# you can choose themes from $HOME/.config/kitty/kitty-themes/
include ./kitty-themes/00-Default.conf

font_family FantasqueSansM Nerd Font Mono Bold
font_size 12.0
bold_font auto
italic_font auto
bold_italic_font auto

background_opacity 0.9
dynamic_background_opacity 1
confirm_os_window_close 0

# Animated cursor
cursor_trail 1

# change to x11 or wayland or leave auto
linux_display_server auto

scrollback_lines 2000
wheel_scroll_min_lines 1
enable_audio_bell no
window_padding_width 4
selection_foreground none
selection_background none

foreground #dddddd
background #000000
cursor #dddddd
EOF

  # ---------- fastfetch config ----------
  mkdir -p "$HOME/.config/fastfetch"
  curl -fLo "$HOME/.config/fastfetch/config-compact.jsonc" \
    https://raw.githubusercontent.com/JaKooLit/Hyprland-Dots/main/config/fastfetch/config-compact.jsonc \
    || FAILED+=("fastfetch config")

  # ---------- Oh My Zsh + plugins ----------
  log "Oh My Zsh + plugins"
  if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
    RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended \
      || FAILED+=("oh-my-zsh")
  fi
  ZSH_CUSTOM_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
  for repo in zsh-autosuggestions zsh-syntax-highlighting zsh-completions zsh-history-substring-search; do
    [[ -d "$ZSH_CUSTOM_DIR/plugins/$repo" ]] || \
      git clone --depth=1 "https://github.com/zsh-users/$repo" "$ZSH_CUSTOM_DIR/plugins/$repo" || FAILED+=("plugin:$repo")
  done

  # ---------- .zshrc ----------
  log "Writing ~/.zshrc (old one backed up)"
  [[ -f $HOME/.zshrc ]] && cp "$HOME/.zshrc" "$HOME/.zshrc.bak.$(date +%Y%m%d-%H%M%S)"
  cat > "$HOME/.zshrc" <<'EOF'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME=""   # prompt is handled by starship
export PATH="$HOME/.local/bin:$HOME/bin:$PATH"

fpath+=${ZSH_CUSTOM:-$ZSH/custom}/plugins/zsh-completions/src

# zsh-syntax-highlighting must stay last
plugins=(git zsh-autosuggestions zsh-completions zsh-history-substring-search zsh-syntax-highlighting)
source $ZSH/oh-my-zsh.sh

# history substring search on up/down
bindkey '^[[A' history-substring-search-up
bindkey '^[[B' history-substring-search-down

# fzf (Ubuntu paths)
[ -f /usr/share/doc/fzf/examples/key-bindings.zsh ] && source /usr/share/doc/fzf/examples/key-bindings.zsh
[ -f /usr/share/doc/fzf/examples/completion.zsh ]   && source /usr/share/doc/fzf/examples/completion.zsh

eval "$(zoxide init zsh)"
eval "$(starship init zsh)"

alias ls='eza --icons --group-directories-first'
alias ll='eza -l --icons --group-directories-first'
alias la='eza -la --icons --group-directories-first'

# ROS 2 Jazzy
[ -f /opt/ros/jazzy/setup.zsh ] && source /opt/ros/jazzy/setup.zsh

command -v fastfetch >/dev/null && fastfetch -c "$HOME/.config/fastfetch/config-compact.jsonc"
EOF

  log "Setting zsh as default shell"
  try sudo chsh -s "$(command -v zsh)" "$USER"
fi

# ------------------------------ apt apps ------------------------------
if [[ $INSTALL_APPS == 1 ]]; then
  log "Apt apps"
  apt_each vlc mpv blender freecad libreoffice flameshot tesseract-ocr tesseract-ocr-eng \
           ntfs-3g bluez upower pavucontrol qpwgraph gromit-mpx snapserver snapclient \
           barrier gnome-shell-extension-manager nautilus-admin libfuse2t64 flatpak
  apt_i unrar || apt_i unrar-free || FAILED+=("unrar")

  # ---------- Brave (stable + beta + nightly) ----------
  log "Brave"
  try sh -c 'curl -fsS https://dl.brave.com/install.sh | sh'
  try sh -c 'curl -fsS https://dl.brave.com/install.sh | CHANNEL=beta sh'
  try sh -c 'curl -fsS https://dl.brave.com/install.sh | CHANNEL=nightly sh'

  # ---------- VS Code (tarball in /opt/vscode, same as on Arch) ----------
  log "VS Code"
  if [[ ! -x /opt/vscode/bin/code ]]; then
    sudo mkdir -p /opt/vscode
    curl -L "https://update.code.visualstudio.com/latest/linux-x64/stable" -o /tmp/vscode.tar.gz \
      && sudo tar -xzf /tmp/vscode.tar.gz -C /opt/vscode --strip-components=1 \
      || FAILED+=("vscode download")
  fi
  if [[ -x /opt/vscode/bin/code ]]; then
    sudo ln -sf /opt/vscode/bin/code /usr/local/bin/code
    # Ubuntu 24.04 blocks unprivileged userns -> Electron needs a setuid chrome-sandbox
    sudo chown root:root /opt/vscode/chrome-sandbox
    sudo chmod 4755 /opt/vscode/chrome-sandbox
    sudo tee /usr/share/applications/code.desktop >/dev/null <<'EOF'
[Desktop Entry]
Name=Visual Studio Code
GenericName=Text Editor , vs code
Comment=Code Editing. Redefined.
Exec=/usr/local/bin/code --unity-launch %F
Icon=/opt/vscode/resources/app/resources/linux/code.png
Type=Application
StartupNotify=true
Categories=Utility;TextEditor;Development;IDE;
MimeType=text/plain;application/x-code-workspace;inode/directory;
Actions=new-empty-window;

[Desktop Action new-empty-window]
Name=New Empty Window
Exec=/usr/local/bin/code --new-window %F
Icon=/opt/vscode/resources/app/resources/linux/code.png
EOF
    sudo tee /usr/local/bin/update-vscode >/dev/null <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
TMP="$(mktemp -d)"
cd "$TMP"
curl -L "https://update.code.visualstudio.com/latest/linux-x64/stable" -o vscode.tar.gz
sudo rm -rf /opt/vscode
sudo mkdir -p /opt/vscode
sudo tar -xzf vscode.tar.gz -C /opt/vscode --strip-components=1
sudo chown root:root /opt/vscode/chrome-sandbox
sudo chmod 4755 /opt/vscode/chrome-sandbox
echo "VS Code updated in /opt/vscode"
EOS
    sudo chmod +x /usr/local/bin/update-vscode
    update-desktop-database "$HOME/.local/share/applications/" 2>/dev/null || true
    for ext in ms-python.python ms-python.vscode-pylance ms-toolsai.jupyter charliermarsh.ruff; do
      code --install-extension "$ext" >/dev/null 2>&1 || FAILED+=("vscode-ext:$ext")
    done
  fi

  # ---------- Arduino IDE 2 (AppImage) + arduino-cli ----------
  log "Arduino IDE 2 + arduino-cli"
  mkdir -p "$HOME/Applications"
  curl -fL "https://downloads.arduino.cc/arduino-ide/arduino-ide_latest_Linux_64bit.AppImage" \
       -o "$HOME/Applications/arduino-ide.AppImage" && chmod +x "$HOME/Applications/arduino-ide.AppImage" \
    || FAILED+=("arduino-ide")
  # 24.04 userns restriction -> run Electron AppImage with --no-sandbox
  cat > "$HOME/.local/bin/arduino-ide" <<'EOF'
#!/usr/bin/env bash
exec "$HOME/Applications/arduino-ide.AppImage" --no-sandbox "$@"
EOF
  chmod +x "$HOME/.local/bin/arduino-ide"
  cat > "$HOME/.local/share/applications/arduino-ide.desktop" <<EOF
[Desktop Entry]
Name=Arduino IDE
Exec=$HOME/.local/bin/arduino-ide %U
Type=Application
Categories=Development;IDE;Electronics;
Terminal=false
EOF
  have arduino-cli || try sh -c "curl -fsSL https://raw.githubusercontent.com/arduino/arduino-cli/master/install.sh | BINDIR=\$HOME/.local/bin sh"
  sudo usermod -aG dialout "$USER"   # serial access (/dev/ttyUSB*, /dev/ttyACM*) — Ubuntu uses dialout, not uucp

  # ---------- Ventoy ----------
  log "Ventoy 1.1.11 -> ~/Downloads"
  mkdir -p "$HOME/Downloads"
  curl -fL "https://github.com/ventoy/Ventoy/releases/download/v1.1.11/ventoy-1.1.11-linux.tar.gz" -o /tmp/ventoy.tar.gz \
    && tar -xzf /tmp/ventoy.tar.gz -C "$HOME/Downloads" || FAILED+=("ventoy")

  # ---------- OCR screenshot helper (~/bin/img2txt.sh) ----------
  cat > "$HOME/bin/img2txt.sh" <<'EOF'
#!/usr/bin/env bash
# select region with flameshot -> OCR with tesseract -> clipboard
tmp="$(mktemp --suffix=.png)"
flameshot gui --raw > "$tmp"
text="$(tesseract "$tmp" - 2>/dev/null)"
rm -f "$tmp"
if [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-copy >/dev/null; then
  printf '%s' "$text" | wl-copy
else
  printf '%s' "$text" | xclip -selection clipboard
fi
EOF
  chmod +x "$HOME/bin/img2txt.sh"
fi

# ------------------------------ flatpaks ------------------------------
if [[ $INSTALL_FLATPAKS == 1 ]]; then
  log "Flatpaks"
  apt_i flatpak
  try flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
  for app in md.obsidian.Obsidian com.orcaslicer.OrcaSlicer io.github.alainm23.planify \
             org.deskflow.deskflow com.leinardi.gst; do
    try flatpak install -y --noninteractive flathub "$app"
  done
fi

# ------------------------------ GNOME ------------------------------
if [[ $INSTALL_GNOME_EXTENSIONS == 1 ]]; then
  log "GNOME dark mode + extensions"
  gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' || true

  # gext picks the build matching your GNOME version (46 on 24.04), no metadata patching needed
  have gext || try pipx install gnome-extensions-cli --system-site-packages
  export PATH="$HOME/.local/bin:$PATH"
  for uuid in \
    appindicatorsupport@rgcjonas.gmail.com \
    Bluetooth-Battery-Meter@maniacx.github.com \
    blur-my-shell@aunetx \
    caffeine@patapon.info \
    dash-to-dock@micxgx.gmail.com \
    desktop-cube@schneegans.github.com \
    gsconnect@andyholmes.github.io \
    pip-on-top@rafostar.github.com \
    Vitals@CoreCoding.com \
    ignore-lid@gnome-extensions.mfloto.com \
    nosleep@ilyasturki.com
  do
    gext install "$uuid" || { FAILED+=("gext:$uuid"); warn "extension failed: $uuid"; }
  done
fi

# ------------------------------ Docker ------------------------------
if [[ $INSTALL_DOCKER == 1 ]]; then
  log "Docker (official repo) + compose"
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  apt_each docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable --now docker.service
  sudo usermod -aG docker "$USER"

  if have nvidia-smi; then
    log "NVIDIA container toolkit"
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | sudo gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
    sudo apt-get update
    apt_i nvidia-container-toolkit && {
      sudo nvidia-ctk runtime configure --runtime=docker
      sudo systemctl restart docker
    } || FAILED+=("nvidia-container-toolkit")
  else
    warn "nvidia-smi not found — skipping NVIDIA container toolkit (install the NVIDIA driver first, then re-run)."
  fi
fi

# ------------------------------ Ollama ------------------------------
if [[ $INSTALL_OLLAMA == 1 ]]; then
  log "Ollama"
  have ollama || try sh -c 'curl -fsSL https://ollama.com/install.sh | sh'

  if [[ $EXPOSE_OLLAMA == 1 ]]; then
    sudo mkdir -p /etc/systemd/system/ollama.service.d
    sudo tee /etc/systemd/system/ollama.service.d/override.conf >/dev/null <<'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
EOF
    sudo systemctl daemon-reload
    sudo systemctl restart ollama
  fi

  if [[ $PULL_OLLAMA_MODELS == 1 ]]; then
    sleep 3
    for m in lfm2.5:8b granite4.1-guardian:8b qwen3:14b qwen3:8b; do
      try ollama pull "$m"
    done
    cat > /tmp/Modelfile <<'EOF'
FROM qwen3:8b
PARAMETER num_ctx 8192
PARAMETER temperature 0.2
EOF
    try ollama create qwen3-cad -f /tmp/Modelfile
  fi
fi

# ------------------------------ ROS 2 Jazzy ------------------------------
if [[ $INSTALL_ROS == 1 ]]; then
  log "ROS 2 Jazzy (native)"
  sudo add-apt-repository -y universe
  sudo curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
    -o /usr/share/keyrings/ros-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo "$UBUNTU_CODENAME") main" \
    | sudo tee /etc/apt/sources.list.d/ros2.list >/dev/null
  sudo apt-get update
  try apt_i ros-jazzy-desktop
  # `source /opt/ros/jazzy/setup.zsh` is already in the generated ~/.zshrc
fi

# ------------------------------ AI / Python tooling ------------------------------
if [[ $INSTALL_AI_TOOLS == 1 ]]; then
  log "uv, miniconda, HF CLI, unsloth"
  have uv || try sh -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'

  if [[ ! -x "$HOME/miniconda3/bin/conda" ]]; then
    mkdir -p "$HOME/miniconda3"
    wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O "$HOME/miniconda3/miniconda.sh" \
      && bash "$HOME/miniconda3/miniconda.sh" -b -u -p "$HOME/miniconda3" \
      && rm -f "$HOME/miniconda3/miniconda.sh" \
      || FAILED+=("miniconda")
  fi
  if [[ -x "$HOME/miniconda3/bin/conda" ]]; then
    "$HOME/miniconda3/bin/conda" init zsh bash >/dev/null
    "$HOME/miniconda3/bin/conda" config --set auto_activate_base false
  fi

  have hf || try pipx install "huggingface_hub[cli]"
  try sh -c 'curl -fsSL https://unsloth.ai/install.sh | sh'
fi

# ------------------------------ done ------------------------------
log "Done"
if ((${#FAILED[@]})); then
  warn "These steps failed (re-run the script or do them by hand):"
  printf '   - %s\n' "${FAILED[@]}"
else
  echo "Everything installed cleanly."
fi

cat <<'EOF'

Next:
  1. LOG OUT and back in  -> zsh becomes your login shell, docker/dialout groups apply,
                             GNOME extensions load.
  2. Open kitty (or run `kitty`) to see the starship prompt + fastfetch.
  3. After re-login:  docker run hello-world
  4. Enable extensions in the Extension Manager if any show as disabled.
EOF
