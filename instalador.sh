#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# INSTALADOR COMPLETO - emendas.anaidison.com.br (Vite/React)
# - Instala Nginx + Node 20 + Certbot
# - Coloca o projeto em /var/www/emendas-app
# - Gera .env (Supabase)
# - Build (npm install + npm run build)
# - Configura Nginx (SPA fallback)
# - Emite SSL (Let's Encrypt) se o DNS já estiver apontado
#
# COMO USAR:
# 1) Suba seu projeto para a VPS de um destes jeitos:
#    A) Via GIT (recomendado): você informa o REPO_URL na execução
#    B) Via ZIP local: você informa o caminho do zip na VPS (ex: /root/meuprojeto.zip)
#    C) Se o projeto já está na máquina (pasta com package.json), você informa o caminho da pasta
#
# 2) Rode:
#    chmod +x install_emendas.sh && ./install_emendas.sh
# ============================================================

DOMAIN="emendas.anaidison.com.br"
WEB_ROOT_BASE="/var/www/emendas-app"
CERTBOT_EMAIL="seuemail@exemplo.com"     # <-- TROQUE (recomendado)
ENABLE_SSL="yes"                         # yes | no

# Supabase (o PROJECT_ID e URL você já tem; a ANON KEY o script vai perguntar)
VITE_SUPABASE_PROJECT_ID="mimatrpfmfjvwphnvrht"
VITE_SUPABASE_URL="https://mimatrpfmfjvwphnvrht.supabase.co"

# Build do Vite
BUILD_DIR_NAME="dist"

# --------- helpers ----------
info() { echo -e "\n[INFO] $*\n"; }
warn() { echo -e "\n[AVISO] $*\n"; }
die()  { echo -e "\n[ERRO] $*\n"; exit 1; }

need_sudo() {
  if [[ "${EUID}" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      SUDO="sudo"
    else
      die "Precisa rodar como root ou ter sudo instalado."
    fi
  else
    SUDO=""
  fi
}

ask() {
  local prompt="$1"
  local default="${2:-}"
  local var
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " var
    echo "${var:-$default}"
  else
    read -r -p "$prompt: " var
    echo "$var"
  fi
}

install_system() {
  info "Instalando dependências do sistema..."
  $SUDO apt update -y
  $SUDO apt install -y nginx curl git unzip ca-certificates

  if ! command -v node >/dev/null 2>&1; then
    info "Instalando Node.js 20 (NodeSource)..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | $SUDO -E bash -
    $SUDO apt install -y nodejs
  fi

  info "Versões: node=$(node -v) | npm=$(npm -v) | nginx=$(nginx -v 2>&1)"
}

ensure_dirs() {
  info "Criando pasta base do site: ${WEB_ROOT_BASE}"
  $SUDO mkdir -p "${WEB_ROOT_BASE}"
  $SUDO chown -R "$USER:$USER" "${WEB_ROOT_BASE}"
}

choose_source() {
  echo ""
  echo "Como seu projeto está aí na VPS?"
  echo "1) Já existe uma PASTA com package.json"
  echo "2) Tenho um ZIP na VPS e quero extrair"
  echo "3) Quero clonar pelo GIT"
  echo ""
  local opt
  opt="$(ask 'Escolha 1/2/3' '1')"

  case "$opt" in
    1)
      PROJECT_DIR="$(ask 'Digite o caminho da pasta do projeto (onde tem package.json)' "${WEB_ROOT_BASE}")"
      ;;
    2)
      local zip_path
      zip_path="$(ask 'Digite o caminho do ZIP na VPS (ex: /root/projeto.zip)')"
      [[ -f "$zip_path" ]] || die "ZIP não encontrado em: $zip_path"

      # limpa pasta base e extrai
      info "Extraindo ZIP para ${WEB_ROOT_BASE}..."
      rm -rf "${WEB_ROOT_BASE:?}/"*
      unzip -q "$zip_path" -d "${WEB_ROOT_BASE}"

      # tenta achar a pasta do projeto (primeira com package.json)
      PROJECT_DIR="$(find "${WEB_ROOT_BASE}" -maxdepth 3 -type f -name package.json -print -quit | xargs -r dirname || true)"
      [[ -n "${PROJECT_DIR}" ]] || die "Não achei package.json após extrair. Verifique o ZIP."
      ;;
    3)
      local repo_url
      repo_url="$(ask 'Cole o URL do repositório (https/ssh)')"
      [[ -n "$repo_url" ]] || die "Repo URL vazio."

      info "Clonando repositório para ${WEB_ROOT_BASE}..."
      rm -rf "${WEB_ROOT_BASE:?}/"*
      git clone "$repo_url" "${WEB_ROOT_BASE}"

      # se clonou dentro da base, define dir
      PROJECT_DIR="${WEB_ROOT_BASE}"
      # se o package.json estiver em subpasta, tenta localizar
      if [[ ! -f "${PROJECT_DIR}/package.json" ]]; then
        PROJECT_DIR="$(find "${WEB_ROOT_BASE}" -maxdepth 3 -type f -name package.json -print -quit | xargs -r dirname || true)"
      fi
      [[ -f "${PROJECT_DIR}/package.json" ]] || die "Não achei package.json no repositório."
      ;;
    *)
      die "Opção inválida."
      ;;
  esac

  info "Projeto detectado em: ${PROJECT_DIR}"
  [[ -f "${PROJECT_DIR}/package.json" ]] || die "package.json não encontrado em: ${PROJECT_DIR}"
}

write_env() {
  info "Configurando .env do Vite (Supabase)..."

  # Lê a anon key sem mostrar na tela
  echo ""
  echo "Cole agora a SUPABASE ANON KEY (publishable)."
  echo "Ela fica no Supabase: Project Settings > API > anon public."
  read -r -s -p "SUPABASE_ANON_KEY: " SUPABASE_ANON_KEY
  echo ""

  [[ -n "${SUPABASE_ANON_KEY}" ]] || die "Você não informou a anon key."

  cat > "${PROJECT_DIR}/.env" <<EOF
VITE_SUPABASE_PROJECT_ID="${VITE_SUPABASE_PROJECT_ID}"
VITE_SUPABASE_PUBLISHABLE_KEY="${SUPABASE_ANON_KEY}"
VITE_SUPABASE_URL="${VITE_SUPABASE_URL}"
EOF

  info ".env criado em ${PROJECT_DIR}/.env"
}

build_project() {
  info "Instalando dependências do projeto e gerando build..."
  cd "${PROJECT_DIR}"
  npm install
  npm run build

  [[ -d "${PROJECT_DIR}/${BUILD_DIR_NAME}" ]] || die "Build não gerou ${BUILD_DIR_NAME}. Verifique seu Vite config."
  info "Build OK: ${PROJECT_DIR}/${BUILD_DIR_NAME}"
}

configure_nginx() {
  info "Configurando Nginx para ${DOMAIN}..."

  local site_avail="/etc/nginx/sites-available/${DOMAIN}"
  local site_enabled="/etc/nginx/sites-enabled/${DOMAIN}"
  local root_path="${PROJECT_DIR}/${BUILD_DIR_NAME}"

  # remove default se existir
  if [[ -f "/etc/nginx/sites-enabled/default" ]]; then
    $SUDO rm -f /etc/nginx/sites-enabled/default || true
  fi

  $SUDO tee "${site_avail}" >/dev/null <<EOF
server {
  listen 80;
  server_name ${DOMAIN};

  root ${root_path};
  index index.html;

  # SPA fallback (React Router)
  location / {
    try_files \$uri \$uri/ /index.html;
  }

  # Cache de estáticos
  location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
    expires 7d;
    add_header Cache-Control "public, max-age=604800";
    try_files \$uri =404;
  }
}
EOF

  if [[ ! -L "${site_enabled}" ]]; then
    $SUDO ln -s "${site_avail}" "${site_enabled}"
  fi

  $SUDO nginx -t
  $SUDO systemctl enable nginx
  $SUDO systemctl reload nginx

  info "Nginx OK. Teste (HTTP): http://${DOMAIN}"
}

open_firewall_if_any() {
  # Não força UFW (nem todo servidor usa), mas tenta ajudar se existir
  if command -v ufw >/dev/null 2>&1; then
    info "UFW detectado. Liberando portas 80 e 443 (se UFW estiver ativo)..."
    $SUDO ufw allow 80/tcp || true
    $SUDO ufw allow 443/tcp || true
  fi
}

configure_ssl() {
  if [[ "${ENABLE_SSL}" != "yes" ]]; then
    warn "SSL desativado (ENABLE_SSL=no). Pulando Certbot."
    return 0
  fi

  info "Instalando Certbot e tentando emitir SSL..."
  $SUDO apt install -y certbot python3-certbot-nginx

  if [[ "${CERTBOT_EMAIL}" == "seuemail@exemplo.com" ]]; then
    warn "Você não trocou CERTBOT_EMAIL. Vou continuar sem email (menos recomendado)."
    $SUDO certbot --nginx -d "${DOMAIN}" --non-interactive --agree-tos --register-unsafely-without-email || {
      warn "Falhou emitir SSL. Causas comuns:"
      warn "- DNS do subdomínio ainda não aponta para esta VPS"
      warn "- Porta 80 bloqueada no firewall/provedor"
      warn "- Domínio não resolve corretamente"
      return 0
    }
  else
    $SUDO certbot --nginx -d "${DOMAIN}" --non-interactive --agree-tos -m "${CERTBOT_EMAIL}" || {
      warn "Falhou emitir SSL. Causas comuns:"
      warn "- DNS do subdomínio ainda não aponta para esta VPS"
      warn "- Porta 80 bloqueada no firewall/provedor"
      warn "- Domínio não resolve corretamente"
      return 0
    }
  fi

  info "SSL OK. Teste (HTTPS): https://${DOMAIN}"
}

final_notes() {
  cat <<EOF

==============================
INSTALAÇÃO FINALIZADA ✅
==============================

Domínio:      ${DOMAIN}
Projeto:      ${PROJECT_DIR}
Build:        ${PROJECT_DIR}/${BUILD_DIR_NAME}

Atualizar depois (quando mudar o projeto):
  cd "${PROJECT_DIR}"
  git pull   # se estiver usando git
  npm install
  npm run build
  sudo systemctl reload nginx

Se o SSL falhou:
- Confira se o A record "emendas" aponta para o IP da VPS
- Aguarde propagação do DNS
- Depois rode:
  sudo certbot --nginx -d ${DOMAIN}

EOF
}

# --------- main ----------
need_sudo
install_system
ensure_dirs
choose_source
write_env
build_project
configure_nginx
open_firewall_if_any
configure_ssl
final_notes
