#!/bin/bash
# =========================================
# 代理节点自动部署脚本
# 功能：Xray代理 + Cloudflare隧道 + 哪吒监控
# 支持：VLESS/VMess/Trojan协议 + 订阅生成
# =========================================
set -uo pipefail

# ========== 环境变量配置 ==========
UPLOAD_URL="${UPLOAD_URL:-}"
PROJECT_URL="${PROJECT_URL:-}"
AUTO_ACCESS="${AUTO_ACCESS:-false}"
FILE_PATH="${FILE_PATH:-./tmp}"
SUB_PATH="${SUB_PATH:-sub}"
PORT="${SERVER_PORT:-${PORT:-9767}}"
UUID="${UUID:-133d8041-e8f3-4b60-b8ac-444e717f2551}"
NEZHA_SERVER="${NEZHA_SERVER:-}"
NEZHA_PORT="${NEZHA_PORT:-}"
NEZHA_KEY="${NEZHA_KEY:-}"
ARGO_DOMAIN="${ARGO_DOMAIN:-}"
ARGO_AUTH="${ARGO_AUTH:-}"
ARGO_PORT="${ARGO_PORT:-}"
CFIP="${CFIP:-cdns.doon.eu.org}"
CFPORT="${CFPORT:-443}"
NAME="${NAME:-}"

# ========== 文件路径定义 ==========
generate_random_name() {
    cat /dev/urandom | tr -dc 'a-z' | fold -w 6 | head -n 1
}

npmName=$(generate_random_name)
webName=$(generate_random_name)
botName=$(generate_random_name)
phpName=$(generate_random_name)

npmPath="$FILE_PATH/$npmName"
phpPath="$FILE_PATH/$phpName"
webPath="$FILE_PATH/$webName"
botPath="$FILE_PATH/$botName"
subPath="$FILE_PATH/sub.txt"
listPath="$FILE_PATH/list.txt"
bootLogPath="$FILE_PATH/boot.log"
configPath="$FILE_PATH/config.json"

# ========== 创建目录 ==========
create_directory() {
    if [[ ! -d "$FILE_PATH" ]]; then
        mkdir -p "$FILE_PATH"
        echo "$FILE_PATH is created"
    else
        echo "$FILE_PATH already exists"
    fi
}

# ========== 删除历史节点 ==========
delete_nodes() {
    if [[ -z "$UPLOAD_URL" || ! -f "$subPath" ]]; then
        return
    fi
    
    local fileContent
    fileContent=$(cat "$subPath" 2>/dev/null) || return
    
    local decoded
    decoded=$(echo "$fileContent" | base64 -d 2>/dev/null) || return
    
    local nodes=()
    while IFS= read -r line; do
        if [[ "$line" =~ (vless|vmess|trojan|hysteria2|tuic):// ]]; then
            nodes+=("$line")
        fi
    done <<< "$decoded"
    
    if [[ ${#nodes[@]} -eq 0 ]]; then
        return
    fi
    
    local json_data
    json_data=$(printf '{"nodes":["%s"]}' "$(printf "%s","${nodes[@]}" | sed 's/,$//')")
    
    curl -s -X POST "${UPLOAD_URL}/api/delete-nodes" \
        -H "Content-Type: application/json" \
        -d "$json_data" > /dev/null 2>&1 || true
}

# ========== 清理历史文件 ==========
cleanup_old_files() {
    if [[ -d "$FILE_PATH" ]]; then
        find "$FILE_PATH" -maxdepth 1 -type f -delete 2>/dev/null || true
    fi
}

# ========== 生成 Xray 配置 ==========
generate_config() {
    cat > "$configPath" << EOF
{
  "log": {
    "access": "/dev/null",
    "error": "/dev/null",
    "loglevel": "none"
  },
  "inbounds": [
    {
      "port": $ARGO_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none",
        "fallbacks": [
          {
            "dest": 3001
          },
          {
            "path": "/vless-argo",
            "dest": 3002
          },
          {
            "path": "/vmess-argo",
            "dest": 3003
          },
          {
            "path": "/trojan-argo",
            "dest": 3004
          }
        ]
      },
      "streamSettings": {
        "network": "tcp"
      }
    },
    {
      "port": 3001,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none"
      }
    },
    {
      "port": 3002,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "/vless-argo"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "metadataOnly": false
      }
    },
    {
      "port": 3003,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/vmess-argo"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "metadataOnly": false
      }
    },
    {
      "port": 3004,
      "listen": "127.0.0.1",
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "password": "$UUID"
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "/trojan-argo"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "metadataOnly": false
      }
    }
  ],
  "dns": {
    "servers": ["https+local://8.8.8.8/dns-query"]
  },
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF
    echo "Xray configuration generated: $configPath"
}

# ========== 判断系统架构 ==========
get_system_architecture() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        arm*|aarch64) echo "arm" ;;
        *) echo "amd" ;;
    esac
}

# ========== 下载文件 ==========
download_file() {
    local fileName="$1"
    local fileUrl="$2"
    
    echo "Downloading $fileName from $fileUrl"
    
    if curl -L -o "$fileName" "$fileUrl" --fail --connect-timeout 30 --retry 3; then
        echo "Download $(basename "$fileName") successfully"
        chmod +x "$fileName"
        return 0
    else
        echo "Download $(basename "$fileName") failed"
        return 1
    fi
}

# ========== 获取架构对应文件 ==========
get_files_for_architecture() {
    local architecture="$1"
    local baseFiles=()
    
    if [[ "$architecture" == "arm" ]]; then
        baseFiles=(
            "$webPath https://arm64.ssss.nyc.mn/web"
            "$botPath https://arm64.ssss.nyc.mn/bot"
        )
    else
        baseFiles=(
            "$webPath https://amd64.ssss.nyc.mn/web"
            "$botPath https://amd64.ssss.nyc.mn/bot"
        )
    fi
    
    if [[ -n "$NEZHA_SERVER" && -n "$NEZHA_KEY" ]]; then
        if [[ -n "$NEZHA_PORT" ]]; then
            local npmUrl
            if [[ "$architecture" == "arm" ]]; then
                npmUrl="https://arm64.ssss.nyc.mn/agent"
            else
                npmUrl="https://amd64.ssss.nyc.mn/agent"
            fi
            baseFiles=("$npmPath $npmUrl" "${baseFiles[@]}")
        else
            local phpUrl
            if [[ "$architecture" == "arm" ]]; then
                phpUrl="https://arm64.ssss.nyc.mn/v1"
            else
                phpUrl="https://amd64.ssss.nyc.mn/v1"
            fi
            baseFiles=("$phpPath $phpUrl" "${baseFiles[@]}")
        fi
    fi
    
    printf '%s\n' "${baseFiles[@]}"
}

# ========== 下载并运行依赖文件 ==========
download_files_and_run() {
    local architecture
    architecture=$(get_system_architecture)
    
    echo "System architecture: $architecture"
    
    local files
    files=$(get_files_for_architecture "$architecture")
    
    if [[ -z "$files" ]]; then
        echo "Can't find files for the current architecture"
        return 1
    fi
    
    # 下载文件
    while IFS= read -r fileInfo; do
        if [[ -n "$fileInfo" ]]; then
            local fileName fileUrl
            fileName=$(echo "$fileInfo" | awk '{print $1}')
            fileUrl=$(echo "$fileInfo" | awk '{print $2}')
            download_file "$fileName" "$fileUrl" || return 1
        fi
    done <<< "$files"
    
    # 运行哪吒监控
    if [[ -n "$NEZHA_SERVER" && -n "$NEZHA_KEY" ]]; then
        if [[ -z "$NEZHA_PORT" ]]; then
            # 哪吒 v1
            local port nezhatls
            port=$(echo "$NEZHA_SERVER" | grep -oE '[0-9]+$' || echo "")
            case "$port" in
                443|8443|2096|2087|2083|2053) nezhatls="true" ;;
                *) nezhatls="false" ;;
            esac
            
            cat > "$FILE_PATH/config.yaml" << EOF
client_secret: $NEZHA_KEY
debug: false
disable_auto_update: true
disable_command_execute: false
disable_force_update: true
disable_nat: false
disable_send_query: false
gpu: false
insecure_tls: true
ip_report_period: 1800
report_delay: 4
server: $NEZHA_SERVER
skip_connection_count: true
skip_procs_count: true
temperature: false
tls: $nezhatls
use_gitee_to_upgrade: false
use_ipv6_country_code: false
uuid: $UUID
EOF
            nohup "$phpPath" -c "$FILE_PATH/config.yaml" >/dev/null 2>&1 &
            echo "$phpName is running"
            sleep 1
        else
            # 哪吒 v0
            local NEZHA_TLS=""
            case "$NEZHA_PORT" in
                443|8443|2096|2087|2083|2053) NEZHA_TLS="--tls" ;;
            esac
            
            nohup "$npmPath" -s "${NEZHA_SERVER}:${NEZHA_PORT}" -p "$NEZHA_KEY" $NEZHA_TLS --disable-auto-update --report-delay 4 --skip-conn --skip-procs >/dev/null 2>&1 &
            echo "$npmName is running"
            sleep 1
        fi
    else
        echo 'NEZHA variable is empty, skip running'
    fi
    
    # 运行 Xray
    nohup "$webPath" -c "$FILE_PATH/config.json" >/dev/null 2>&1 &
    echo "$webName is running"
    sleep 1
    
    # 运行 Cloudflared
    if [[ -f "$botPath" ]]; then
        local args
        if [[ "$ARGO_AUTH" =~ ^[A-Z0-9a-z=]{120,250}$ ]]; then
            args="tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token $ARGO_AUTH"
        elif [[ "$ARGO_AUTH" =~ TunnelSecret ]]; then
            args="tunnel --edge-ip-version auto --config $FILE_PATH/tunnel.yml run"
        else
            args="tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --logfile $FILE_PATH/boot.log --loglevel info --url http://localhost:$ARGO_PORT"
        fi
        
        nohup "$botPath" $args >/dev/null 2>&1 &
        echo "$botName is running"
        sleep 2
    fi
    
    sleep 5
}

# ========== 配置 Argo 隧道 ==========
argo_type() {
    if [[ -z "$ARGO_AUTH" || -z "$ARGO_DOMAIN" ]]; then
        echo "ARGO_DOMAIN or ARGO_AUTH variable is empty, use quick tunnels"
        return
    fi

    if [[ "$ARGO_AUTH" == *"TunnelSecret"* ]]; then
        echo "$ARGO_AUTH" > "$FILE_PATH/tunnel.json"
        
        cat > "$FILE_PATH/tunnel.yml" << EOF
tunnel: $(echo "$ARGO_AUTH" | grep -o '"TunnelID":"[^"]*' | cut -d'"' -f4)
credentials-file: $FILE_PATH/tunnel.json
protocol: http2

ingress:
  - hostname: $ARGO_DOMAIN
    service: http://localhost:$ARGO_PORT
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
    else
        echo "ARGO_AUTH mismatch TunnelSecret, use token connect to tunnel"
    fi
}

# ========== 提取域名并生成链接 ==========
extract_domains() {
    local argoDomain
    
    if [[ -n "$ARGO_AUTH" && -n "$ARGO_DOMAIN" ]]; then
        argoDomain="$ARGO_DOMAIN"
        echo "ARGO_DOMAIN: $argoDomain"
        generate_links "$argoDomain"
    else
        if [[ ! -f "$bootLogPath" ]]; then
            echo "boot.log not found, waiting for tunnel startup..."
            sleep 10
        fi
        
        if [[ -f "$bootLogPath" ]]; then
            argoDomain=$(grep -oE 'https?://[^ ]*trycloudflare\.com' "$bootLogPath" | head -1 | sed 's|https\?://||')
        fi
        
        if [[ -n "$argoDomain" ]]; then
            echo "ArgoDomain: $argoDomain"
            generate_links "$argoDomain"
        else
            echo "ArgoDomain not found, re-running bot to obtain ArgoDomain"
            pkill -f "$botName" 2>/dev/null || true
            rm -f "$bootLogPath"
            sleep 3
            
            local args="tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --logfile $FILE_PATH/boot.log --loglevel info --url http://localhost:$ARGO_PORT"
            nohup "$botPath" $args >/dev/null 2>&1 &
            echo "$botName is running"
            sleep 10
            extract_domains
        fi
    fi
}

# ========== 生成订阅链接 ==========
generate_links() {
    local argoDomain="$1"
    
    local metaInfo
    metaInfo=$(curl -sm 5 https://speed.cloudflare.com/meta | awk -F\" '{print $26"-"$18}' | sed 's/ /_/g')
    local ISP="${metaInfo:-Unknown}"
    local nodeName
    if [[ -n "$NAME" ]]; then
        nodeName="${NAME}-${ISP}"
    else
        nodeName="$ISP"
    fi
    
    # VMESS 配置
    local vmess_config
    vmess_config=$(cat << EOF
{
  "v": "2",
  "ps": "$nodeName",
  "add": "$CFIP",
  "port": "$CFPORT",
  "id": "$UUID",
  "aid": "0",
  "scy": "none",
  "net": "ws",
  "type": "none",
  "host": "$argoDomain",
  "path": "/vmess-argo?ed=2560",
  "tls": "tls",
  "sni": "$argoDomain",
  "alpn": "",
  "fp": "firefox"
}
EOF
    )
    
    local vmess_encoded
    vmess_encoded=$(echo "$vmess_config" | base64 -w 0)
    
    local subTxt
    subTxt=$(cat << EOF
vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argoDomain}&fp=firefox&type=ws&host=${argoDomain}&path=%2Fvless-argo%3Fed%3D2560#${nodeName}

vmess://${vmess_encoded}

trojan://${UUID}@${CFIP}:${CFPORT}?security=tls&sni=${argoDomain}&fp=firefox&type=ws&host=${argoDomain}&path=%2Ftrojan-argo%3Fed%3D2560#${nodeName}
EOF
    )
    
    echo "$subTxt" | base64 -w 0 > "$subPath"
    echo "Sub content (base64):"
    echo "$subTxt" | base64 -w 0
    echo "$FILE_PATH/sub.txt saved successfully"
    
    upload_nodes
}

# ========== 上传节点 ==========
upload_nodes() {
    if [[ -n "$UPLOAD_URL" && -n "$PROJECT_URL" ]]; then
        local subscriptionUrl="${PROJECT_URL}/${SUB_PATH}"
        local json_data="{\"subscription\":[\"$subscriptionUrl\"]}"
        
        if curl -s -X POST "${UPLOAD_URL}/api/add-subscriptions" \
            -H "Content-Type: application/json" \
            -d "$json_data" > /dev/null; then
            echo "Subscription uploaded successfully"
        else
            echo "Subscription upload failed"
        fi
    elif [[ -n "$UPLOAD_URL" && -f "$listPath" ]]; then
        local nodes=()
        while IFS= read -r line; do
            if [[ "$line" =~ (vless|vmess|trojan|hysteria2|tuic):// ]]; then
                nodes+=("$line")
            fi
        done < "$listPath"
        
        if [[ ${#nodes[@]} -gt 0 ]]; then
            local json_data
            json_data=$(printf '{"nodes":["%s"]}' "$(printf "%s","${nodes[@]}" | sed 's/,$//')")
            
            if curl -s -X POST "${UPLOAD_URL}/api/add-nodes" \
                -H "Content-Type: application/json" \
                -d "$json_data" > /dev/null; then
                echo "Nodes uploaded successfully"
            else
                echo "Nodes upload failed"
            fi
        fi
    else
        echo "Skipping upload nodes"
    fi
}

# ========== 自动访问任务 ==========
add_visit_task() {
    if [[ "$AUTO_ACCESS" != "true" || -z "$PROJECT_URL" ]]; then
        echo "Skipping adding automatic access task"
        return
    fi

    if curl -s -X POST "https://oooo.serv00.net/add-url" \
        -H "Content-Type: application/json" \
        -d "{\"url\":\"$PROJECT_URL\"}" > /dev/null; then
        echo "Automatic access task added successfully"
    else
        echo "Add automatic access task failed"
    fi
}

# ========== 清理文件 ==========
clean_files() {
    (
        sleep 90
        local filesToDelete=("$bootLogPath" "$configPath" "$webPath" "$botPath")
        
        if [[ -n "$NEZHA_PORT" && -f "$npmPath" ]]; then
            filesToDelete+=("$npmPath")
        elif [[ -n "$NEZHA_SERVER" && -n "$NEZHA_KEY" && -f "$phpPath" ]]; then
            filesToDelete+=("$phpPath")
        fi
        
        rm -rf "${filesToDelete[@]}" 2>/dev/null || true
        
        echo "App is running"
        echo "Thank you for using this script, enjoy!"
    ) &
}

# ========== 启动HTTP服务 ==========
start_http_server() {
    echo "Starting HTTP server on port: $PORT"
    
    # 简单的HTTP服务器实现
    while true; do
        {
            echo -e "HTTP/1.1 200 OK\r"
            echo -e "Content-Type: text/plain; charset=utf-8\r"
            echo -e "\r"
            echo -e "Hello world!"
        } | nc -l -p "$PORT" -q 1 2>/dev/null || sleep 1
    done &
}

# ========== 主函数 ==========
main() {
    echo "Starting proxy node deployment..."
    
    create_directory
    delete_nodes
    cleanup_old_files
    generate_config
    argo_type
    download_files_and_run
    extract_domains
    add_visit_task
    clean_files
    start_http_server
    
    echo "Deployment completed!"
    echo "HTTP server running on port: $PORT"
    echo "Subscription path: /$SUB_PATH"
    
    # 保持脚本运行
    wait
}

main "$@"
