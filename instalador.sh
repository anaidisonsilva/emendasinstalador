#!/usr/bin/env bash
set -e

# ============================================================
# INSTALADOR AUTOMÁTICO – emendas.anaidison.com.br
# Ubuntu 22/24 | Vite + React | Nginx | SSL
# ============================================================

DOMAIN="emendas.anaidison.com.br"
WEB_ROOT="/var/www/emendas"
BUILD_DIR="dist"

# Supabase (fixos)
VITE_SUPABASE_PROJECT_ID="mimatrpfmfjvwphnvrht"
VITE_SUPABASE_URL="https://mimatrpfmfjvwphnvrht.supabase.co"

CERTBOT_EMAIL="vivianribeiro14@gmail.com"

# ============================================================
# FUNÇÕES
# ============================================================

info() { echo -e "\n\033[1;32m[INFO]\033[0m $1\n"; }
warn() { echo -e "\n\033[1;33m[AVISO]\033[0m $1\n"; }
error() { echo -e "\n\033[1;31m[ERRO]\033[0m $1\n"; exit 1; }

# root ou sudo
if [ "$EUID" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    error "Execute como root ou instale sudo."
  fi
else
  SUDO=""
fi

# ============================================================
# SISTEMA
# ============================================================

info "Atualizando sistema e instalando dependências..."
$SUDO apt update -y
$SUDO apt install -y curl git unzip nginx ca-certificates

# Node.js 20
if ! command -v node >/dev/null 2>&1; then
  info "Instalando Node.js 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | $SUDO bash -
  $SUDO apt install -y nodejs
fi

info "Versões:"
node -v
npm -v
nginx -v

# ============================================================
# PROJETO
# ============================================================

info "Preparando diretório do projeto..."
$SUDO mkdir -p $WEB_ROOT
$SUDO chown -R $USER:$USER $WEB_ROOT

echo ""
echo "Como você quer fornecer o projeto?"
echo "1) ZIP já está na VPS"
echo "2) Clonar repositório Git"
echo "3) Projeto já está em uma pasta"
read -p "Escolha [1/2/3]: " SOURCE_OPTION

if [ "$SOURCE_OPTION" = "1" ]; then
  read -p "Caminho do ZIP (ex: /root/projeto.zip): " ZIP_PATH
  [ -f "$ZIP_PATH" ] || error "ZIP não encontrado."
  rm -rf $WEB_ROOT/*
  unzip -q "$ZIP_PATH" -d $WEB_ROOT
elif [ "$SOURCE_OPTION" = "2" ]; then
  read -p "URL do repositório Git: " GIT_URL
  rm -rf $WEB_ROOT/*
  git clone "$GIT_URL" $WEB_ROOT
elif [ "$SOURCE_OPTION" = "3" ]; then
  read -p "Caminho da pasta do projeto: " PROJECT_DIR
  [ -f "$PROJECT_DIR/package.json" ] || error "package.json não encontrado."
  WEB_ROOT="$PROJECT_DIR"
else
  error "Opção inválida."
fi

# localizar package.json
if [ ! -f "$WEB_ROOT/package.json" ]; then
  PROJECT_DIR=$(find "$WEB_ROOT" -maxdepth 3 -name package.json | head -n 1 | xargs dirname)
else
  PROJECT_DIR="$WEB_ROOT"
fi

[ -f "$PROJECT_DIR/package.json" ] || error "package.json não encontrado."

info "Projeto localizado em: $PROJECT_DIR"

# ============================================================
# ENV
# ============================================================

echo ""
echo "Cole a SUPABASE ANON KEY (não aparece ao digitar):"
read -s SUPABASE_KEY
echo ""

[ -n "$SUPABASE_KEY" ] || error "Anon key vazia."

cat > "$PROJECT_DIR/.env" <<EOF
VITE_SUPABASE_PROJECT_ID="$VITE_SUPABASE_PROJECT_ID"
VITE_SUPABASE_PUBLISHABLE_KEY="$SUPABASE_KEY"
VITE_SUPABASE_URL="$VITE_SUPABASE_URL"
EOF

info ".env criado com sucesso"

# ============================================================
# BUILD
# ============================================================

info "Instalando dependências e gerando build..."
cd "$PROJECT_DIR"
npm install
npm run build

[ -d "$PROJECT_DIR/$BUILD_DIR" ] || error "Build não gerou $BUILD_DIR."

# ============================================================
# NGINX
# ============================================================

info "Configurando Nginx..."

NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"

$SUDO tee "$NGINX_CONF" >/dev/null <<EOF
server {
  listen 80;
  server_name $DOMAIN;

  root $PROJECT_DIR/$BUILD_DIR;
  index index.html;

  location / {
    try_files \$uri \$uri/ /index.html;
  }

  location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
    expires 7d;
    add_header Cache-Control "public, max-age=604800";
  }
}
EOF

$SUDO rm -f /etc/nginx/sites-enabled/default
$SUDO ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/

$SUDO nginx -t
$SUDO systemctl reload nginx

# ============================================================
# SSL
# ============================================================

info "Instalando SSL (Let's Encrypt)..."
$SUDO apt install -y certbot python3-certbot-nginx

$SUDO certbot --nginx \
  -d $DOMAIN \
  --non-interactive \
  --agree-tos \
  -m $CERTBOT_EMAIL || warn "SSL não emitido (DNS pode não estar propagado)"

# ============================================================
# FINAL
# ============================================================

echo ""
echo "======================================"
echo " INSTALAÇÃO FINALIZADA COM SUCESSO ✅"
echo "======================================"
echo ""
echo "🌐 Site: https://$DOMAIN"
echo "📁 Projeto: $PROJECT_DIR"
echo ""
echo "Para atualizar no futuro:"
echo "cd $PROJECT_DIR"
echo "npm install && npm run build"
echo "sudo systemctl reload nginx"
echo ""
