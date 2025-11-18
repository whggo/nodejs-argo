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

# ========== 系统检查 ==========
check_system() {
  echo "=== 系统信息 ==="
  echo "系统架构: $(uname -m)"
  echo "当前用户: $(whoami)"
  echo "工作目录: $(pwd)"
  echo "================"
}

# ========== 依赖检查 ==========
check_dependencies() {
  local deps=("curl" "unzip" "openssl")
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" &> /dev/null; then
      echo "错误: 缺少依赖 $dep"
      return 1
    fi
  done
  echo "所有依赖检查通过"
  return 0
}

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
    echo "下载 Xray v1.8.23..."
    if ! curl -L -o xray.zip "https://github.com/XTLS/Xray-core/releases/download/v1.8.23/Xray-linux-64.zip" --fail --connect-timeout 15; then
      echo "错误: 下载 Xray 失败"
      return 1
    fi
    
    if ! unzip -j xray.zip xray -d . >/dev/null 2>&1; then
      echo "错误: 解压 Xray 失败"
      rm -f xray.zip
      return 1
    fi
    
    rm -f xray.zip
    chmod +x "$VLESS_BIN"
    
    # 验证 Xray 是否可用
    if ! "$VLESS_BIN" version >/dev/null 2>&1; then
      echo "错误: Xray 验证失败"
      return 1
    fi
    echo "Xray 下载和验证成功"
  else
    echo "Xray 已存在"
  fi
}

# ========== 下载和配置 Cloudflared ==========
setup_argo() {
  if [[ ! -x "$ARGO_BIN" ]]; then
    echo "下载 Cloudflared..."
    local arch=$(uname -m)
    case "$arch" in
      x86_64) local pkg="cloudflared-linux-amd64" ;;
      aarch64) local pkg="cloudflared-linux-arm64" ;;
      armv7l) local pkg="cloudflared-linux-arm" ;;
      *) local pkg="cloudflared-linux-amd64" ;;
    esac
    
    if ! curl -L -o "$ARGO_BIN" "https://github.com/cloudflare/cloudflared/releases/latest/download/$pkg" --fail --connect-timeout 15; then
      echo "错误: 下载 Cloudflared 失败"
      return 1
    fi
    
    chmod +x "$ARGO_BIN"
    echo "Cloudflared 下载成功"
  fi

  # 创建凭证文件
  echo "创建 Argo 隧道凭证..."
  cat > credentials.json <<EOF
$ARGO_TOKEN
EOF

  # 解析隧道信息
  local tunnel_info=$(echo "$ARGO_TOKEN" | base64 -d 2>/dev/null || echo "")
  local tunnel_id=""
  
  if [[ -n "$tunnel_info" ]]; then
    tunnel_id=$(echo "$tunnel_info" | grep -o '"tunnelID":"[^"]*' | cut -d'"' -f4 2>/dev/null || echo "")
  fi
  
  # 如果解析失败，使用默认值
  if [[ -z "$tunnel_id" ]]; then
    tunnel_id="argo-tunnel"
  fi

  # 创建正确的 Argo 隧道配置（参考 JavaScript 版本）
  cat > "$ARGO_CONFIG" <<EOF
tunnel: $tunnel_id
credentials-file: credentials.json
protocol: http2

ingress:
  - hostname: $ARGO_DOMAIN
    service: http://localhost:$PORT
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF

  echo "Argo 隧道配置完成"
  echo "隧道ID: $tunnel_id"
}

# ========== 生成 VLESS Reality 配置 ==========
gen_vless_config() {
  echo "生成 VLESS Reality 配置..."
  
  local shortId=$(openssl rand -hex 8)
  
  # 生成密钥对
  local keys
  if ! keys=$("$VLESS_BIN" x25519 2>/dev/null); then
    echo "错误: 无法生成 X25519 密钥"
    return 1
  fi
  
  local priv=$(echo "$keys" | grep -i private | awk '{print $3}')
  local pub=$(echo "$keys" | grep -i public | awk '{print $3}')
  
  # 验证密钥是否有效
  if [[ -z "$priv" || -z "$pub" ]]; then
    echo "错误: 生成的密钥无效"
    return 1
  fi

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
Masquerade Domain: $MASQ_DOMAIN
EOF

  echo "VLESS 配置生成成功"
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
  echo "UUID: $VLESS_UUID"
  echo "Public Key: $pub"
  echo "Short ID: $sid"
  echo "========================================="
  cat "$VLESS_LINK"
  echo "========================================="
}

# ========== 检查端口占用 ==========
check_port() {
  if command -v netstat >/dev/null 2>&1; then
    if netstat -tln | grep -q ":$PORT "; then
      echo "警告: 端口 $PORT 已被占用"
    fi
  elif command -v ss >/dev/null 2>&1; then
    if ss -tln | grep -q ":$PORT "; then
      echo "警告: 端口 $PORT 已被占用"
    fi
  fi
}

# ========== 启动 Argo 隧道（使用 token 方式）==========
start_argo_tunnel() {
  echo "启动 Argo 隧道..."
  
  # 方法1：使用 token 直接运行（推荐）
  if [[ "$ARGO_TOKEN" =~ ^eyJ[a-zA-Z0-9_-]*\.[a-zA-Z0-9_-]*\.[a-zA-Z0-9_-]*$ ]]; then
    echo "使用 Token 方式启动 Argo 隧道..."
    "$ARGO_BIN" tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token "$ARGO_TOKEN" &
    local argo_pid=$!
  # 方法2：使用配置文件
  elif [[ -f "$ARGO_CONFIG" ]]; then
    echo "使用配置文件启动 Argo 隧道..."
    "$ARGO_BIN" tunnel --config "$ARGO_CONFIG" run &
    local argo_pid=$!
  # 方法3：使用快速隧道
  else
    echo "使用快速隧道..."
    "$ARGO_BIN" tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --url "http://localhost:$PORT" &
    local argo_pid=$!
  fi
  
  # 等待隧道启动
  sleep 10
  
  # 检查隧道是否正常运行
  if ! kill -0 $argo_pid 2>/dev/null; then
    echo "错误: Argo 隧道启动失败"
    return 1
  fi
  
  echo "Argo 隧道启动成功 (PID: $argo_pid)"
  return $argo_pid
}

# ========== 启动服务 ==========
run_services() {
  echo "启动 VLESS Reality 服务..."
  
  # 检查端口
  check_port
  
  # 先启动 Xray
  echo "Starting Xray on port :$PORT..."
  "$VLESS_BIN" run -c "$VLESS_CONFIG" &
  local xray_pid=$!
  
  # 等待 Xray 启动
  sleep 3
  
  # 检查 Xray 是否正常运行
  if ! kill -0 $xray_pid 2>/dev/null; then
    echo "错误: Xray 启动失败"
    return 1
  fi
  
  echo "Xray 启动成功 (PID: $xray_pid)"
  
  # 启动 Argo 隧道
  local argo_pid
  if start_argo_tunnel; then
    argo_pid=$?
  else
    echo "尝试使用备用方式启动 Argo 隧道..."
    # 备用方式：直接使用 token
    "$ARGO_BIN" tunnel run --token "$ARGO_TOKEN" &
    argo_pid=$!
    sleep 10
    
    if ! kill -0 $argo_pid 2>/dev/null; then
      echo "Argo 隧道启动失败，但 Xray 仍在运行"
      # 即使 Argo 失败，也继续运行 Xray
      wait $xray_pid
      return 1
    fi
  fi
  
  echo "所有服务启动完成!"
  echo "Xray PID: $xray_pid"
  echo "Argo Tunnel PID: $argo_pid"
  
  # 健康检查循环
  local error_count=0
  while [[ $error_count -lt 3 ]]; do
    if ! kill -0 $xray_pid 2>/dev/null; then
      echo "Xray 进程异常退出"
      ((error_count++))
    fi
    if ! kill -0 $argo_pid 2>/dev/null; then
      echo "Argo Tunnel 进程异常退出"
      ((error_count++))
    fi
    
    if [[ $error_count -eq 0 ]]; then
      echo "服务运行正常..."
      sleep 30
    else
      sleep 5
    fi
  done
  
  # 清理进程
  kill $xray_pid $argo_pid 2>/dev/null || true
  echo "服务停止，准备重启..."
  return 1
}

# ========== 清理函数 ==========
cleanup() {
  echo "正在清理..."
  pkill -f "xray" || true
  pkill -f "cloudflared" || true
  sleep 2
}

# ========== 测试 Argo 连接 ==========
test_argo_connection() {
  echo "测试 Argo 隧道连接..."
  local max_retries=3
  local retry_count=0
  
  while [[ $retry_count -lt $max_retries ]]; do
    if curl -s --connect-timeout 10 "https://$ARGO_DOMAIN" > /dev/null; then
      echo "Argo 隧道连接测试成功"
      return 0
    else
      echo "Argo 隧道连接测试失败 (尝试 $((retry_count + 1))/$max_retries)"
      ((retry_count++))
      sleep 5
    fi
  done
  
  echo "Argo 隧道连接测试最终失败"
  return 1
}

# ========== 主函数 ==========
main() {
  echo "开始部署 VLESS + TCP + Reality with Argo Tunnel"
  
  # 设置退出时清理
  trap cleanup EXIT
  
  # 系统检查
  check_system
  
  # 检查依赖
  if ! check_dependencies; then
    echo "请安装缺失的依赖后重试"
    exit 1
  fi

  # 加载配置和生成 UUID
  load_config
  [[ -z "${VLESS_UUID:-}" ]] && VLESS_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)
  echo "使用 UUID: $VLESS_UUID"

  # 下载和设置组件
  if ! get_xray; then
    echo "Xray 设置失败"
    exit 1
  fi
  
  if ! setup_argo; then
    echo "Argo 隧道设置失败"
    # 不退出，尝试继续运行
  fi
  
  if ! gen_vless_config; then
    echo "VLESS 配置生成失败"
    exit 1
  fi

  # 获取 IP 并生成链接
  ip=$(curl -s --connect-timeout 5 https://api64.ipify.org || echo "127.0.0.1")
  gen_link "$ip"

  # 持续运行服务
  while true; do
    if run_services; then
      echo "服务正常重启中..."
    else
      echo "服务启动失败，等待后重试..."
    fi
    sleep 10
  done
}

# 运行主函数
main "$@"
