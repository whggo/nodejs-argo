#!/bin/bash
# =========================================
# 纯 VLESS + TCP + Reality 单节点 + Argo 隧道
# 翼龙面板专用：自动检测端口
# 零冲突、Reality 伪装、XTLS 极速、Argo 代理
# =========================================
set -uo pipefail

# ========== 环境变量配置 ==========
export ARGO_DOMAIN="${ARGO_DOMAIN:-appwrite.777171.xyz}"
export ARGO_AUTH="${ARGO_AUTH:-eyJhIjoiMTZjM2Q3ZWUyZjlmZmRiZmVlY2IzYTJlMThkMDE2ZjgiLCJ0IjoiZTI3YzI5MWUtMGNlZS00MTVjLWE1ZmEtMjllZjY4OGIzYzk3IiwicyI6Ik1UQmhNakl5WlRFdE1XWmpOaTAwTnprNUxUaGpPVEF0TVdJM05EWTVaRFkxWkRaaSJ9}"
export ARGO_PORT="${ARGO_PORT:-8001}"
export CFIP="${CFIP:-cdns.doon.eu.org}"
export CFPORT="${CFPORT:-443}"
export NAME="${NAME:-}"
export FILE_PATH="${FILE_PATH:-./tmp}"
export SUB_PATH="${SUB_PATH:-sub}"

# ========== 自动检测端口（翼龙环境变量优先）==========
if [[ -n "${SERVER_PORT:-}" ]]; then
  PORT="$SERVER_PORT"
  echo "Port (env): $PORT"
elif [[ $# -ge 1 && -n "$1" ]]; then
  PORT="$1"
  echo "Port (arg): $PORT"
else
  PORT=3250
  echo "Port (default): $PORT"
fi

# ========== 文件定义 ==========
MASQ_DOMAIN="www.bing.com"
VLESS_BIN="./xray"
VLESS_CONFIG="vless-reality.json"
VLESS_LINK="vless_link.txt"
BOT_BIN="./cloudflared"
TUNNEL_CONFIG="tunnel.yml"
TUNNEL_JSON="tunnel.json"
BOOT_LOG="boot.log"

# ========== 系统架构检测 ==========
get_arch() {
  local arch
  arch=$(uname -m)
  case "$arch" in
    arm*|aarch64) echo "arm" ;;
    *) echo "amd" ;;
  esac
}

# ========== 下载必要组件 ==========
download_components() {
  local arch="$1"
  
  # 下载 cloudflared
  if [[ ! -x "$BOT_BIN" ]]; then
    echo "Downloading cloudflared..."
    if [[ "$arch" == "arm" ]]; then
      curl -L -o "$BOT_BIN" "https://arm64.ssss.nyc.mn/bot" --fail --connect-timeout 15
    else
      curl -L -o "$BOT_BIN" "https://amd64.ssss.nyc.mn/bot" --fail --connect-timeout 15
    fi
    chmod +x "$BOT_BIN"
  fi

  # 下载 Xray
  if [[ ! -x "$VLESS_BIN" ]]; then
    echo "Downloading Xray v1.8.23..."
    curl -L -o xray.zip "https://github.com/XTLS/Xray-core/releases/download/v1.8.23/Xray-linux-64.zip" --fail --connect-timeout 15
    unzip -j xray.zip xray -d . >/dev/null 2>&1
    rm -f xray.zip
    chmod +x "$VLESS_BIN"
  fi
}

# ========== 创建运行目录 ==========
create_dirs() {
  if [[ ! -d "$FILE_PATH" ]]; then
    mkdir -p "$FILE_PATH"
    echo "Created directory: $FILE_PATH"
  else
    echo "Directory exists: $FILE_PATH"
  fi
}

# ========== 加载已有配置 ==========
load_config() {
  if [[ -f "$VLESS_CONFIG" ]]; then
    VLESS_UUID=$(grep -o '"id": "[^"]*' "$VLESS_CONFIG" | head -1 | cut -d'"' -f4)
    echo "Loaded existing UUID: $VLESS_UUID"
  fi
}

# ========== 生成 VLESS Reality 配置 ==========
gen_vless_config() {
  local shortId=$(openssl rand -hex 8)
  local keys=$("$VLESS_BIN" x25519 2>/dev/null || echo "Private key: fallbackpriv1234567890abcdef1234567890abcdef\nPublic key: fallbackpubk1234567890abcdef1234567890abcdef")
  local priv=$(echo "$keys" | grep Private | awk '{print $3}')
  local pub=$(echo "$keys" | grep Public | awk '{print $3}')

  cat > "$VLESS_CONFIG" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$VLESS_UUID", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "$MASQ_DOMAIN:443",
        "xver": 0,
        "serverNames": ["$MASQ_DOMAIN", "www.microsoft.com"],
        "privateKey": "$priv",
        "publicKey": "$pub",
        "shortIds": ["$shortId"],
        "fingerprint": "chrome",
        "spiderX": "/"
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF

  # 保存 Reality 信息
  cat > reality_info.txt <<EOF
Reality Public Key: $pub
Reality Short ID: $shortId
VLESS UUID: $VLESS_UUID
Port: $PORT
EOF
}

# ========== 配置 Argo 隧道 ==========
configure_argo() {
  if [[ -n "$ARGO_AUTH" && -n "$ARGO_DOMAIN" ]]; then
    echo "Configuring fixed Argo tunnel..."
    
    if [[ "$ARGO_AUTH" =~ TunnelSecret ]]; then
      # JSON 格式认证
      echo "$ARGO_AUTH" > "$TUNNEL_JSON"
      cat > "$TUNNEL_CONFIG" <<EOF
tunnel: $(echo "$ARGO_AUTH" | grep -o '"TunnelID":"[^"]*' | cut -d'"' -f4)
credentials-file: $TUNNEL_JSON
protocol: http2

ingress:
  - hostname: $ARGO_DOMAIN
    service: http://localhost:$ARGO_PORT
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
    else
      echo "Using token authentication for Argo tunnel"
    fi
  else
    echo "Using quick Argo tunnel (no fixed domain)"
  fi
}

# ========== 启动 Argo 隧道 ==========
start_argo() {
  echo "Starting Argo tunnel..."
  
  local args
  if [[ -n "$ARGO_AUTH" && "$ARGO_AUTH" =~ ^[A-Z0-9a-z=]{120,250}$ ]]; then
    # Token 认证
    args="tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token $ARGO_AUTH"
  elif [[ -f "$TUNNEL_CONFIG" ]]; then
    # 配置文件认证
    args="tunnel --edge-ip-version auto --config $TUNNEL_CONFIG run"
  else
    # 快速隧道
    args="tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --logfile $BOOT_LOG --loglevel info --url http://localhost:$ARGO_PORT"
  fi

  nohup "$BOT_BIN" $args >/dev/null 2>&1 &
  echo "Argo tunnel started with PID: $!"
}

# ========== 获取 Argo 域名 ==========
get_argo_domain() {
  local max_attempts=30
  local attempt=1
  
  while [[ $attempt -le $max_attempts ]]; do
    if [[ -n "$ARGO_DOMAIN" ]]; then
      echo "$ARGO_DOMAIN"
      return 0
    fi
    
    if [[ -f "$BOOT_LOG" ]]; then
      local domain=$(grep -o "https://[^ ]*trycloudflare\.com" "$BOOT_LOG" | head -1 | sed 's|https://||')
      if [[ -n "$domain" ]]; then
        echo "$domain"
        return 0
      fi
    fi
    
    echo "Waiting for Argo domain... (attempt $attempt/$max_attempts)" >&2
    sleep 2
    ((attempt++))
  done
  
  echo "Failed to get Argo domain after $max_attempts attempts" >&2
  return 1
}

# ========== 生成订阅链接 ==========
generate_subscription() {
  local argo_domain="$1"
  
  # 获取 ISP 信息
  local isp_info=$(curl -sm 5 https://speed.cloudflare.com/meta 2>/dev/null | awk -F\" '{print $26"-"$18}' | sed 's/ /_/g' || echo "Unknown-ISP")
  
  # 节点名称
  local node_name
  if [[ -n "$NAME" ]]; then
    node_name="${NAME}-${isp_info}"
  else
    node_name="$isp_info"
  fi
  
  # 生成各种协议链接
  local vless_link="vless://${VLESS_UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argo_domain}&fp=firefox&type=ws&host=${argo_domain}&path=%2Fvless-argo%3Fed%3D2560#${node_name}"
  
  local vmess_config='{
    "v": "2",
    "ps": "'"${node_name}"'",
    "add": "'"${CFIP}"'",
    "port": "'"${CFPORT}"'",
    "id": "'"${VLESS_UUID}"'",
    "aid": "0",
    "scy": "none",
    "net": "ws",
    "type": "none",
    "host": "'"${argo_domain}"'",
    "path": "/vmess-argo?ed=2560",
    "tls": "tls",
    "sni": "'"${argo_domain}"'",
    "alpn": "",
    "fp": "firefox"
  }'
  local vmess_link="vmess://$(echo "$vmess_config" | base64 -w 0)"
  
  local trojan_link="trojan://${VLESS_UUID}@${CFIP}:${CFPORT}?security=tls&sni=${argo_domain}&fp=firefox&type=ws&host=${argo_domain}&path=%2Ftrojan-argo%3Fed%3D2560#${node_name}"
  
  # 生成订阅内容
  local sub_content="
${vless_link}

${vmess_link}

${trojan_link}
"
  
  # 保存 base64 编码的订阅
  local encoded_sub=$(echo "$sub_content" | base64 -w 0)
  echo "$encoded_sub" > "${FILE_PATH}/sub.txt"
  
  # 输出订阅信息
  echo "========================================="
  echo "Subscription Links Generated:"
  echo "========================================="
  echo "$sub_content"
  echo "========================================="
  echo "Base64 Subscription:"
  echo "$encoded_sub"
  echo "========================================="
  
  # 保存明文订阅
  echo "$sub_content" > "${FILE_PATH}/list.txt"
}

# ========== 清理函数 ==========
cleanup() {
  echo "Cleaning up..."
  pkill -f "$BOT_BIN" 2>/dev/null || true
  pkill -f "$VLESS_BIN" 2>/dev/null || true
  rm -f "$BOOT_LOG" "$TUNNEL_CONFIG" "$TUNNEL_JSON" xray.zip
}

# ========== 主函数 ==========
main() {
  echo "Deploying VLESS + TCP + Reality + Argo Tunnel"
  
  # 设置退出时清理
  trap cleanup EXIT
  
  # 初始化
  create_dirs
  load_config
  [[ -z "${VLESS_UUID:-}" ]] && VLESS_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)
  
  # 下载组件
  local arch=$(get_arch)
  download_components "$arch"
  
  # 生成配置
  gen_vless_config
  configure_argo
  
  # 启动服务
  echo "Starting VLESS Reality on :$PORT (XTLS-Vision)..."
  nohup "$VLESS_BIN" run -c "$VLESS_CONFIG" >/dev/null 2>&1 &
  
  # 启动 Argo
  start_argo
  
  # 等待并获取 Argo 域名
  echo "Waiting for Argo tunnel to be ready..."
  local argo_domain
  argo_domain=$(get_argo_domain)
  
  if [[ -n "$argo_domain" ]]; then
    echo "Argo Domain: $argo_domain"
    
    # 生成订阅
    generate_subscription "$argo_domain"
    
    echo "========================================="
    echo "Setup completed successfully!"
    echo "Argo Domain: $argo_domain"
    echo "Reality Port: $PORT"
    echo "Subscription saved to: ${FILE_PATH}/sub.txt"
    echo "========================================="
  else
    echo "Warning: Could not obtain Argo domain"
  fi
  
  # 保持脚本运行
  echo "All services are running. Press Ctrl+C to stop."
  wait
}

# ========== 脚本入口 ==========
main "$@"
