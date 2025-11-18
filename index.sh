#!/bin/bash
# =========================================
# 纯 VLESS + TCP + Reality 单节点
# 翼龙面板专用：自动检测端口
# 零冲突、Reality 伪装、XTLS 极速
# 添加 Argo 隧道代理支持
# =========================================
set -uo pipefail

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

# ========== Argo 隧道配置 ==========
ARGO_DOMAIN="appwrite.777171.xyz"
ARGO_TOKEN="eyJhIjoiMTZjM2Q3ZWUyZjlmZmRiZmVlY2IzYTJlMThkMDE2ZjgiLCJ0IjoiZTI3YzI5MWUtMGNlZS00MTVjLWE1ZmEtMjllZjY4OGIzYzk3IiwicyI6Ik1UQmhNakl5WlRFdE1XWmpOaTAwTnprNUxUaGpPVEF0TVdJM05EWTVaRFkxWkRaaSJ9"
ARGO_BIN="./cloudflared"
ARGO_CONFIG="argo_tunnel.yaml"

# ========== 文件定义 ==========
MASQ_DOMAIN="www.bing.com"
VLESS_BIN="./xray"
VLESS_CONFIG="vless-reality.json"
VLESS_LINK="vless_link.txt"

# ========== 加载已有配置 ==========
load_config() {
  if [[ -f "$VLESS_CONFIG" ]]; then
    VLESS_UUID=$(grep -o '"id": "[^"]*' "$VLESS_CONFIG" | head -1 | cut -d'"' -f4)
    echo "Loaded existing UUID: $VLESS_UUID"
  fi
}

# ========== 下载 Xray ==========
get_xray() {
  if [[ ! -x "$VLESS_BIN" ]]; then
    echo "Downloading Xray v1.8.23..."
    curl -L -o xray.zip "https://github.com/XTLS/Xray-core/releases/download/v1.8.23/Xray-linux-64.zip" --fail --connect-timeout 15
    unzip -j xray.zip xray -d . >/dev/null 2>&1
    rm -f xray.zip
    chmod +x "$VLESS_BIN"
  fi
}

# ========== 下载和配置 Cloudflared ==========
setup_argo() {
  if [[ ! -x "$ARGO_BIN" ]]; then
    echo "Downloading Cloudflared..."
    local arch=$(uname -m)
    case "$arch" in
      x86_64) local pkg="cloudflared-linux-amd64" ;;
      aarch64) local pkg="cloudflared-linux-arm64" ;;
      armv7l) local pkg="cloudflared-linux-arm" ;;
      *) local pkg="cloudflared-linux-amd64" ;;
    esac
    
    curl -L -o "$ARGO_BIN" "https://github.com/cloudflare/cloudflared/releases/latest/download/$pkg" --fail --connect-timeout 15
    chmod +x "$ARGO_BIN"
  fi

  # 创建 Argo 隧道配置
  cat > "$ARGO_CONFIG" <<EOF
tunnel: $(echo "$ARGO_TOKEN" | base64 -d 2>/dev/null | grep -o '"tunnelID":"[^"]*' | cut -d'"' -f4 2>/dev/null || echo "argo-tunnel")
credentials-file: credentials.json
ingress:
  - hostname: $ARGO_DOMAIN
    service: http://localhost:$PORT
  - service: http_status:404
EOF

  # 创建凭证文件
  cat > credentials.json <<EOF
{"AccountTag":"$(echo "$ARGO_TOKEN" | base64 -d 2>/dev/null | grep -o '"a":"[^"]*' | cut -d'"' -f4 2>/dev/null || echo "unknown")","TunnelSecret":"$(echo "$ARGO_TOKEN" | base64 -d 2>/dev/null | grep -o '"s":"[^"]*' | cut -d'"' -f4 2>/dev/null || echo "unknown")","TunnelID":"$(echo "$ARGO_TOKEN" | base64 -d 2>/dev/null | grep -o '"t":"[^"]*' | cut -d'"' -f4 2>/dev/null || echo "unknown")","TunnelName":"$(echo "$ARGO_TOKEN" | base64 -d 2>/dev/null | grep -o '"tunnelID":"[^"]*' | cut -d'"' -f4 2>/dev/null || echo "argo-tunnel")"}
EOF
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
Argo Domain: $ARGO_DOMAIN
EOF
}

# ========== 生成客户端链接 ==========
gen_link() {
  local ip="$1"
  local pub=$(grep "Public Key" reality_info.txt | awk '{print $4}')
  local sid=$(grep "Short ID" reality_info.txt | awk '{print $4}')

  # 生成直接连接链接
  cat > "$VLESS_LINK" <<EOF
=== 直接连接 ===
vless://$VLESS_UUID@$ip:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$MASQ_DOMAIN&fp=chrome&pbk=$pub&sid=$sid&type=tcp&spx=/#VLESS-Reality-Direct

=== Argo 隧道连接 ===
vless://$VLESS_UUID@$ARGO_DOMAIN:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$MASQ_DOMAIN&fp=chrome&pbk=$pub&sid=$sid&type=tcp&spx=/#VLESS-Reality-Argo
EOF

  echo "========================================="
  echo "VLESS + TCP + Reality 节点信息:"
  echo "直接连接: $ip:$PORT"
  echo "Argo 隧道: $ARGO_DOMAIN:443"
  echo "========================================="
  cat "$VLESS_LINK"
  echo "========================================="
}

# ========== 启动服务 ==========
run_services() {
  echo "Starting VLESS Reality on :$PORT (XTLS-Vision)..."
  
  # 启动 Xray
  "$VLESS_BIN" run -c "$VLESS_CONFIG" &
  local xray_pid=$!
  
  echo "Starting Argo Tunnel..."
  # 启动 Argo 隧道
  "$ARGO_BIN" tunnel --config "$ARGO_CONFIG" run &
  local argo_pid=$!
  
  echo "服务启动完成!"
  echo "Xray PID: $xray_pid"
  echo "Argo Tunnel PID: $argo_pid"
  
  # 等待进程
  wait -n $xray_pid $argo_pid
  echo "有服务异常退出，正在重启..."
  kill $xray_pid $argo_pid 2>/dev/null || true
  sleep 5
}

# ========== 主函数 ==========
main() {
  echo "Deploying VLESS + TCP + Reality with Argo Tunnel"

  load_config
  [[ -z "${VLESS_UUID:-}" ]] && VLESS_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)

  get_xray
  setup_argo
  gen_vless_config

  ip=$(curl -s https://api64.ipify.org || echo "127.0.0.1")
  gen_link "$ip"

  # 持续运行服务
  while true; do
    run_services
    sleep 3
  done
}

main "$@"
