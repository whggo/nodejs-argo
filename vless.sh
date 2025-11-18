#!/bin/bash

# 设置环境变量
export UPLOAD_URL=${UPLOAD_URL:-""}
export FILE_PATH=${FILE_PATH:-"./tmp"}
export SUB_PATH=${SUB_PATH:-"sub"}
# 动态获取端口号（翼龙面板环境变量优先）
if [[ -n "${SERVER_PORT:-}" ]]; then
  export PORT="$SERVER_PORT"
  echo "Port (env): $PORT"
elif [[ $# -ge 1 && -n "$1" ]]; then
  export PORT="$1"
  echo "Port (arg): $PORT"
else
  export PORT=${PORT:-"9808"}
  echo "Port (default): $PORT"
fi
export UUID=${UUID:-"eb8169c8-cffe-4a20-923d-2476a1b21e88"}
export ARGO_DOMAIN=${ARGO_DOMAIN:-"idx1.777171.xyz"}
export ARGO_AUTH=${ARGO_AUTH:-"eyJhIjoiMTZjM2Q3ZWUyZjlmZmRiZmVlY2IzYTJlMThkMDE2ZjgiLCJ0IjoiY2UyZDc4MDMtN2YwNi00NDg4LWI0NzEtNDNhOTk3NTJkNWM4IiwicyI6Ik5ESTROV0poTmprdE1XVXlNUzAwTWpVd0xUa3pOR010WWpNek5XVmlaR0ZsTUdFdyJ9"}
export ARGO_PORT=${ARGO_PORT:-"8001"}
export CFIP=${CFIP:-"cdns.doon.eu.org"}
export CFPORT=${CFPORT:-"443"}
export NAME=${NAME:-""}

# 创建运行文件夹
if [ ! -d "$FILE_PATH" ]; then
    mkdir -p "$FILE_PATH"
    echo "$FILE_PATH is created"
else
    echo "$FILE_PATH already exists"
fi

# 生成随机6位字符文件名
generateRandomName() {
    local characters='abcdefghijklmnopqrstuvwxyz'
    local result=''
    for ((i=0; i<6; i++)); do
        result+=${characters:$((RANDOM % ${#characters})):1}
    done
    echo "$result"
}

# 全局变量
webName=$(generateRandomName)
botName=$(generateRandomName)
webPath="$FILE_PATH/$webName"
botPath="$FILE_PATH/$botName"
subPath="$FILE_PATH/sub.txt"
bootLogPath="$FILE_PATH/boot.log"
configPath="$FILE_PATH/config.json"

# 清理历史文件
cleanupOldFiles() {
    if [ -d "$FILE_PATH" ]; then
        find "$FILE_PATH" -maxdepth 1 -type f -delete 2>/dev/null || true
    fi
}

# 生成xray配置文件
generateConfig() {
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
    echo "Config generated at $configPath"
}

# 判断系统架构
getSystemArchitecture() {
    local arch
    arch=$(uname -m)
    case $arch in
        arm*|aarch64)
            echo "arm"
            ;;
        *)
            echo "amd"
            ;;
    esac
}

# 下载文件
downloadFile() {
    local fileName=$1
    local fileUrl=$2
    
    echo "Downloading $fileName from $fileUrl"
    
    if command -v curl >/dev/null 2>&1; then
        curl -L -o "$fileName" "$fileUrl" >/dev/null 2>&1
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$fileName" "$fileUrl" >/dev/null 2>&1
    else
        echo "Error: Neither curl nor wget is available"
        return 1
    fi
    
    if [ $? -eq 0 ] && [ -f "$fileName" ]; then
        echo "Download $(basename "$fileName") successfully"
        chmod +x "$fileName"
        return 0
    else
        echo "Download $(basename "$fileName") failed"
        return 1
    fi
}

# 下载并运行依赖文件
downloadFilesAndRun() {
    local architecture
    architecture=$(getSystemArchitecture)
    
    local webUrl botUrl
    
    if [ "$architecture" = "arm" ]; then
        webUrl="https://arm64.ssss.nyc.mn/web"
        botUrl="https://arm64.ssss.nyc.mn/bot"
    else
        webUrl="https://amd64.ssss.nyc.mn/web"
        botUrl="https://amd64.ssss.nyc.mn/bot"
    fi
    
    # 下载web文件
    if ! downloadFile "$webPath" "$webUrl"; then
        echo "Failed to download web file"
        return 1
    fi
    
    # 下载bot文件
    if ! downloadFile "$botPath" "$botUrl"; then
        echo "Failed to download bot file"
        return 1
    fi
    
    # 运行xray
    echo "Starting $webName..."
    nohup "$webPath" -c "$configPath" >/dev/null 2>&1 &
    echo "$webName is running"
    sleep 1
    
    # 运行cloudflared
    echo "Starting $botName..."
    local args
    if [[ "$ARGO_AUTH" =~ ^[A-Z0-9a-z=]{120,250}$ ]]; then
        args="tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token $ARGO_AUTH"
    elif [[ "$ARGO_AUTH" == *"TunnelSecret"* ]]; then
        # 创建tunnel.yml
        local tunnelSecret=$(echo "$ARGO_AUTH" | grep -o '"TunnelSecret":"[^"]*"' | cut -d'"' -f4)
        cat > "$FILE_PATH/tunnel.yml" << EOF
tunnel: $tunnelSecret
credentials-file: $FILE_PATH/tunnel.json
protocol: http2

ingress:
  - hostname: $ARGO_DOMAIN
    service: http://localhost:$ARGO_PORT
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
        echo "$ARGO_AUTH" > "$FILE_PATH/tunnel.json"
        args="tunnel --edge-ip-version auto --config $FILE_PATH/tunnel.yml run"
    else
        args="tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --logfile $bootLogPath --loglevel info --url http://localhost:$ARGO_PORT"
    fi
    
    nohup "$botPath" $args >/dev/null 2>&1 &
    echo "$botName is running"
    sleep 2
}

# 获取临时隧道domain
extractDomains() {
    local argoDomain
    
    if [ -n "$ARGO_AUTH" ] && [ -n "$ARGO_DOMAIN" ]; then
        argoDomain=$ARGO_DOMAIN
        echo "ARGO_DOMAIN: $argoDomain"
        generateLinks "$argoDomain"
    else
        # 等待boot.log文件生成
        sleep 5
        
        if [ -f "$bootLogPath" ]; then
            argoDomain=$(grep -o 'https://[^ ]*trycloudflare\.com' "$bootLogPath" | head -1 | sed 's|https://||')
            if [ -n "$argoDomain" ]; then
                echo "ArgoDomain: $argoDomain"
                generateLinks "$argoDomain"
            else
                echo "ArgoDomain not found, retrying..."
                sleep 10
                extractDomains
            fi
        else
            echo "boot.log not found, waiting..."
            sleep 10
            extractDomains
        fi
    fi
}

# 生成订阅链接
generateLinks() {
    local argoDomain=$1
    
    # 获取ISP信息
    local metaInfo
    if command -v curl >/dev/null 2>&1; then
        metaInfo=$(curl -sm 5 https://speed.cloudflare.com/meta | awk -F\" '{print $26"-"$18}' | sed 's/ /_/g')
    else
        metaInfo="unknown-unknown"
    fi
    
    local ISP=$(echo "$metaInfo" | tr -d '[:space:]')
    local nodeName
    if [ -n "$NAME" ]; then
        nodeName="${NAME}-${ISP}"
    else
        nodeName="$ISP"
    fi
    
    # 生成VMESS配置
    local vmessConfig=$(cat << EOF
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
    
    local encodedVmess=$(echo "$vmessConfig" | base64 -w 0)
    
    # 生成订阅内容
    local subTxt=$(cat << EOF
vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argoDomain}&fp=firefox&type=ws&host=${argoDomain}&path=%2Fvless-argo%3Fed%3D2560#${nodeName}

vmess://${encodedVmess}

trojan://${UUID}@${CFIP}:${CFPORT}?security=tls&sni=${argoDomain}&fp=firefox&type=ws&host=${argoDomain}&path=%2Ftrojan-argo%3Fed%3D2560#${nodeName}
EOF
    )
    
    # 保存base64编码的订阅
    local encodedSub=$(echo "$subTxt" | base64 -w 0)
    echo "$encodedSub" > "$subPath"
    echo "Sub content saved to $subPath"
    echo "Sub content (base64): $encodedSub"
    
    # 启动HTTP服务器
    startHttpServer "$encodedSub"
}

# 启动HTTP服务器
startHttpServer() {
    local encodedSub=$1
    
    # 检查Node.js是否可用
    if ! command -v node >/dev/null 2>&1; then
        echo "Node.js is not available, skipping HTTP server"
        return
    fi
    
    # 创建简单的HTTP服务器
    cat > "$FILE_PATH/server.js" << EOF
const http = require('http');
const url = require('url');

const encodedSub = "$encodedSub";
const PORT = $PORT;
const SUB_PATH = "$SUB_PATH";

const server = http.createServer((req, res) => {
    const parsedUrl = url.parse(req.url, true);
    
    if (parsedUrl.pathname === '/') {
        res.writeHead(200, { 'Content-Type': 'text/plain' });
        res.end('Hello world!');
    } else if (parsedUrl.pathname === '/' + SUB_PATH) {
        res.writeHead(200, { 
            'Content-Type': 'text/plain; charset=utf-8',
            'Access-Control-Allow-Origin': '*'
        });
        res.end(encodedSub);
    } else {
        res.writeHead(404, { 'Content-Type': 'text/plain' });
        res.end('Not Found');
    }
});

server.listen(PORT, () => {
    console.log('HTTP server is running on port: ' + PORT);
    console.log('Subscription available at: http://[server-ip]:' + PORT + '/' + SUB_PATH);
});

// 优雅退出
process.on('SIGINT', () => {
    console.log('Shutting down server...');
    server.close(() => {
        process.exit(0);
    });
});
EOF
    
    # 启动服务器
    echo "Starting HTTP server on port $PORT..."
    node "$FILE_PATH/server.js" &
    echo "HTTP server started"
}

# 上传节点
uploadNodes() {
    if [ -z "$UPLOAD_URL" ]; then
        echo "UPLOAD_URL not set, skipping upload"
        return
    fi
    
    if [ ! -f "$subPath" ]; then
        echo "Sub file not found, skipping upload"
        return
    fi
    
    local content
    content=$(cat "$subPath")
    local decoded=$(echo "$content" | base64 -d 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        echo "Failed to decode sub file"
        return
    fi
    
    # 提取节点
    local nodes=()
    while IFS= read -r line; do
        if [[ $line =~ (vless|vmess|trojan|hysteria2|tuic):// ]]; then
            nodes+=("$line")
        fi
    done <<< "$decoded"
    
    if [ ${#nodes[@]} -eq 0 ]; then
        echo "No nodes found to upload"
        return
    fi
    
    # 构建JSON数据
    local jsonData="{\"nodes\":["
    for ((i=0; i<${#nodes[@]}; i++)); do
        jsonData+="\"${nodes[i]}\""
        if [ $i -lt $((${#nodes[@]} - 1)) ]; then
            jsonData+=","
        fi
    done
    jsonData+="]}"
    
    # 上传节点
    if command -v curl >/dev/null 2>&1; then
        curl -X POST \
            -H "Content-Type: application/json" \
            -d "$jsonData" \
            "$UPLOAD_URL/api/add-nodes" >/dev/null 2>&1
        
        if [ $? -eq 0 ]; then
            echo "Nodes uploaded successfully"
        else
            echo "Failed to upload nodes"
        fi
    else
        echo "curl not available, cannot upload nodes"
    fi
}

# 清理文件
cleanFiles() {
    echo "Cleaning up files in 90 seconds..."
    sleep 90
    
    rm -f "$bootLogPath" "$configPath" "$webPath" "$botPath" \
          "$FILE_PATH/tunnel.json" "$FILE_PATH/tunnel.yml" \
          "$FILE_PATH/server.js" 2>/dev/null || true
    
    echo "Cleanup completed"
    echo "App is running"
    echo "Thank you for using this script, enjoy!"
}

# 主运行逻辑
main() {
    echo "Starting server setup..."
    
    cleanupOldFiles
    generateConfig
    downloadFilesAndRun
    extractDomains
    uploadNodes
    
    # 在后台运行清理任务
    cleanFiles &
    
    echo "Setup completed successfully!"
    echo "HTTP server should be running on port $PORT"
    echo "Check the output above for subscription information"
    
    # 保持脚本运行
    wait
}

# 捕获退出信号
trap 'echo "Script interrupted"; exit 0' INT TERM

# 运行主函数
main "$@"
