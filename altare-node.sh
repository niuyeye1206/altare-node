#!/bin/bash
# Altare / 无 systemd 容器 VLESS 节点管理脚本（菜单版）
# 仿 eooce 老王 sing-box 四合一的操作方式：装、管、改、看节点信息都在一个菜单里。
#
# 首次使用：先去 Cloudflare 建一条固定隧道，拿到 token 和域名，再跑这个脚本选 1 安装。
#   bash altare-node.sh
# 以后管理：直接跑 bash altare-node.sh 进菜单。
#
# 要求：Debian/Ubuntu 容器，root 运行，有 apt 和外网。
# 注意：Altare 容器没有 systemd，全部用 nohup 后台跑；
#       自启靠 /root/start-node.sh + 看门狗，面板 Startup Command 里先跑它。

# ---------- 固定路径 ----------
SB_BIN="/root/sing-box"
CF_BIN="/root/cloudflared"
CONF_DIR="/root/sing-box-conf"
CONF="$CONF_DIR/config.json"
TOKEN_FILE="/root/.argo-token"
INFO_FILE="/root/.node-info"   # 存 UUID / 域名 / WS 路径 / 端口，供菜单读取
START_SH="/root/start-node.sh"
WATCHDOG_SH="/root/watchdog.sh"
SB_LOG="/root/sing-box.log"
CF_LOG="/root/cloudflared.log"

# ---------- 读已保存的信息 ----------
load_info() {
  UUID=""; ARGO_DOMAIN=""; WS_PATH="/vless-argo"; SB_PORT="8001"
  [ -f "$INFO_FILE" ] && . "$INFO_FILE"
  # 兜底：从 sing-box 配置里读 UUID 与端口
  if [ -f "$CONF" ]; then
    [ -z "$UUID" ] && UUID=$(grep -o '"uuid": *"[^"]*"' "$CONF" | head -1 | cut -d'"' -f4)
    [ -z "$SB_PORT" ] && SB_PORT=$(grep -o '"listen_port": *[0-9]*' "$CONF" | head -1 | grep -o '[0-9]*')
  fi
}

save_info() {
  cat > "$INFO_FILE" <<EOF
UUID="$UUID"
ARGO_DOMAIN="$ARGO_DOMAIN"
WS_PATH="$WS_PATH"
SB_PORT="$SB_PORT"
EOF
  chmod 600 "$INFO_FILE"
}

# ---------- 状态 ----------
is_running() { pgrep -x "$1" >/dev/null 2>&1; }

status_line() {
  local sb="未运行" cf="未运行"
  is_running sing-box && sb="running"
  is_running cloudflared && cf="running"
  echo "--- Argo 状态：$cf"
  echo "--- sing-box 状态：$sb"
}

# ---------- 生成链接 ----------
vless_link() {
  load_info
  local enc
  enc=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$WS_PATH?ed=2560', safe=''))" 2>/dev/null || echo "%2Fvless-argo%3Fed%3D2560")
  local name="Altare-$(echo "$ARGO_DOMAIN" | cut -d. -f1 | sed 's/altare-//;s/^./\U&/')"
  echo "vless://$UUID@$ARGO_DOMAIN:443?encryption=none&security=tls&sni=$ARGO_DOMAIN&fp=chrome&type=ws&host=$ARGO_DOMAIN&path=$enc#$name"
}

write_config() {
  mkdir -p "$CONF_DIR"
  cat > "$CONF" <<EOF
{
  "log": {"level": "info"},
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "127.0.0.1",
      "listen_port": $SB_PORT,
      "users": [{"uuid": "$UUID", "flow": ""}],
      "transport": {"type": "ws", "path": "$WS_PATH"}
    }
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF
}

write_start_scripts() {
  cat > "$START_SH" <<'EOS'
#!/bin/bash
# 幂等启动：启动前杀旧进程，再 nohup 起 sing-box + cloudflared + 看门狗。
cd /root
pkill -x sing-box 2>/dev/null || true
pkill -x cloudflared 2>/dev/null || true
sleep 1
nohup /root/sing-box run -c /root/sing-box-conf/config.json > /root/sing-box.log 2>&1 &
nohup /root/cloudflared tunnel --no-autoupdate run --token "$(cat /root/.argo-token)" > /root/cloudflared.log 2>&1 &
if ! pgrep -f "watchdog.sh" >/dev/null 2>&1; then
  nohup /root/watchdog.sh > /root/watchdog.log 2>&1 &
fi
EOS
  chmod +x "$START_SH"
  cat > "$WATCHDOG_SH" <<'EOS'
#!/bin/bash
# 每 30 秒查一次，挂了就拉起。
while true; do
  pgrep -x sing-box >/dev/null 2>&1 || nohup /root/sing-box run -c /root/sing-box-conf/config.json > /root/sing-box.log 2>&1 &
  pgrep -x cloudflared >/dev/null 2>&1 || nohup /root/cloudflared tunnel --no-autoupdate run --token "$(cat /root/.argo-token)" > /root/cloudflared.log 2>&1 &
  sleep 30
done
EOS
  chmod +x "$WATCHDOG_SH"
}

start_node() {
  bash "$START_SH"
  sleep 4
}

stop_node() {
  pkill -x sing-box 2>/dev/null || true
  pkill -x cloudflared 2>/dev/null || true
  pkill -f "watchdog.sh" 2>/dev/null || true
  sleep 1
}

# ---------- 1. 安装节点 ----------
do_install() {
  echo "=== 安装节点 ==="
  read -rp "CF 隧道 token（必填）: " ARGO_TOKEN
  read -rp "隧道域名（如 altare-bne.noc.us.ci，必填）: " ARGO_DOMAIN
  read -rp "UUID（回车自动生成）: " UUID
  read -rp "WS 路径（回车默认 /vless-argo）: " WS_PATH
  read -rp "本地端口（回车默认 8001）: " SB_PORT
  [ -z "$ARGO_TOKEN" ] && { echo "token 不能为空。"; return; }
  [ -z "$ARGO_DOMAIN" ] && { echo "域名不能为空。"; return; }
  [ -z "$WS_PATH" ] && WS_PATH="/vless-argo"
  [ -z "$SB_PORT" ] && SB_PORT="8001"
  if [ -z "$UUID" ]; then
    if command -v uuidgen >/dev/null 2>&1; then UUID="$(uuidgen)";
    else UUID="$(python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null || cat /proc/sys/kernel/random/uuid)"; fi
  fi
  echo "UUID: $UUID"

  export DEBIAN_FRONTEND=noninteractive
  if ! command -v curl >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates procps iproute2 uuid-runtime
  fi
  cd /root
  if [ ! -x "$SB_BIN" ]; then
    echo "下载 sing-box 1.14.4..."
    curl -sL -o /tmp/sb.tar.gz https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-linux-amd64.tar.gz
    tar xzf /tmp/sb.tar.gz -C /tmp
    cp /tmp/sing-box-1.14.4-linux-amd64/sing-box "$SB_BIN"
    chmod +x "$SB_BIN"
    rm -rf /tmp/sing-box-1.14.4-linux-amd64 /tmp/sb.tar.gz
  fi
  if [ ! -x "$CF_BIN" ]; then
    echo "下载 cloudflared 2026.11.1..."
    curl -sL -o "$CF_BIN" https://github.com/cloudflare/cloudflared/releases/download/2026.11.1/cloudflared-linux-amd64
    chmod +x "$CF_BIN"
  fi
  "$SB_BIN" version | head -1
  "$CF_BIN" --version

  write_config
  printf '%s' "$ARGO_TOKEN" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  "$SB_BIN" check -c "$CONF" && echo "配置 OK"
  save_info
  write_start_scripts
  start_node
  echo "--- 进程 ---"
  is_running sing-box && echo "sing-box running" || echo "sing-box 没起来，看 $SB_LOG"
  is_running cloudflared && echo "cloudflared running" || echo "cloudflared 没起来，看 $CF_LOG"
  echo ""
  echo "=============================="
  echo "节点链接："
  vless_link
  echo "=============================="
  echo "面板自启：Altare 面板 Startup Command 里，先跑 /root/start-node.sh 再跑原来的启动命令。"
}

# ---------- 2. 卸载节点 ----------
do_uninstall() {
  read -rp "确定卸载？停掉进程并删除 sing-box、cloudflared、配置与 token（y/N）: " yn
  [ "$yn" != "y" ] && [ "$yn" != "Y" ] && { echo "已取消。"; return; }
  stop_node
  rm -f "$SB_BIN" "$CF_BIN" "$TOKEN_FILE" "$INFO_FILE"
  rm -rf "$CONF_DIR" "$START_SH" "$WATCHDOG_SH" "$SB_LOG" "$CF_LOG" /root/watchdog.log
  echo "已卸载。"
}

# ---------- 3. 节点管理 ----------
do_manage() {
  echo "--- 节点管理 ---"
  status_line
  echo "1. 重启节点（sing-box + 隧道）"
  echo "2. 只重启 sing-box"
  echo "3. 只重启隧道"
  echo "4. 停止节点"
  echo "0. 返回"
  read -rp "请输入选择 (0-4): " c
  case "$c" in
    1) stop_node; start_node; echo "已重启。"; status_line;;
    2) pkill -x sing-box 2>/dev/null; sleep 1; nohup "$SB_BIN" run -c "$CONF" > "$SB_LOG" 2>&1 & sleep 3; is_running sing-box && echo "sing-box running" || tail -5 "$SB_LOG";;
    3) pkill -x cloudflared 2>/dev/null; sleep 1; nohup "$CF_BIN" tunnel --no-autoupdate run --token "$(cat "$TOKEN_FILE")" > "$CF_LOG" 2>&1 & sleep 3; is_running cloudflared && echo "cloudflared running" || tail -5 "$CF_LOG";;
    4) stop_node; echo "已停止。";;
    *) echo "返回。";;
  esac
}

# ---------- 4. Argo 隧道管理 ----------
do_tunnel() {
  echo "--- Argo 隧道管理 ---"
  status_line
  echo "1. 重启隧道"
  echo "2. 查看隧道日志"
  echo "3. 更换隧道 token / 域名"
  echo "0. 返回"
  read -rp "请输入选择 (0-3): " c
  case "$c" in
    1) pkill -x cloudflared 2>/dev/null; sleep 1; nohup "$CF_BIN" tunnel --no-autoupdate run --token "$(cat "$TOKEN_FILE")" > "$CF_LOG" 2>&1 & sleep 3; is_running cloudflared && echo "cloudflared running" || tail -5 "$CF_LOG";;
    2) tail -30 "$CF_LOG" 2>/dev/null || echo "暂无日志。";;
    3)
      read -rp "新 token（回车不改）: " nt
      read -rp "新域名（回车不改）: " nd
      [ -n "$nt" ] && { printf '%s' "$nt" > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"; }
      if [ -n "$nd" ]; then ARGO_DOMAIN="$nd"; load_info; ARGO_DOMAIN="$nd"; save_info; fi
      write_start_scripts
      stop_node; start_node
      echo "已更换并重启，当前域名：$ARGO_DOMAIN"
      vless_link
      ;;
    *) echo "返回。";;
  esac
}

# ---------- 5. 查看节点信息 ----------
do_info() {
  load_info
  echo "--- 节点信息 ---"
  status_line
  echo "UUID: $UUID"
  echo "域名: $ARGO_DOMAIN"
  echo "WS 路径: $WS_PATH"
  echo "本地端口: $SB_PORT"
  echo ""
  echo "VLESS 链接："
  vless_link
  echo ""
  echo "订阅：把上面这行存成 txt 即可。"
}

# ---------- 6. 修改节点配置 ----------
do_change() {
  load_info
  echo "--- 修改节点配置（回车保持不变） ---"
  echo "当前 UUID: $UUID"
  read -rp "新 UUID: " nu
  echo "当前域名: $ARGO_DOMAIN"
  read -rp "新域名: " nd
  echo "当前 WS 路径: $WS_PATH"
  read -rp "新 WS 路径: " np
  echo "当前本地端口: $SB_PORT"
  read -rp "新本地端口: " nport
  [ -n "$nu" ] && UUID="$nu"
  [ -n "$nd" ] && ARGO_DOMAIN="$nd"
  [ -n "$np" ] && WS_PATH="$np"
  [ -n "$nport" ] && SB_PORT="$nport"
  write_config
  "$SB_BIN" check -c "$CONF" && echo "配置 OK"
  save_info
  stop_node; start_node
  echo "已修改并重启。"
  vless_link
}

# ---------- 7. 管理节点订阅 ----------
do_sub() {
  load_info
  echo "--- 节点订阅 ---"
  echo "下面是当前节点的订阅内容（一行一个链接），存成 txt 挂到你的订阅服务上即可："
  echo ""
  vless_link
  echo ""
  read -rp "要不要直接写到 /root/sub.txt？(y/N): " yn
  if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then
    vless_link > /root/sub.txt
    echo "已写到 /root/sub.txt"
  fi
}

# ---------- 8. 增加/删除协议 ----------
do_proto() {
  echo "--- 增加/删除协议 ---"
  echo "当前只有 VLESS（走 CF 隧道）。"
  echo "HY2 走直连 UDP，Altare 容器一般只映射了 SSH 的 TCP 端口，UDP 大概率不通，"
  echo "加上后也连不上，之前布里斯班那台实测就是不通。"
  echo "1. 增加 HY2（仍要你自己测通不通）"
  echo "2. 删除 HY2"
  echo "0. 返回"
  read -rp "请输入选择 (0-2): " c
  case "$c" in
    1)
      read -rp "HY2 监听 UDP 端口（默认 25160，即 SSH 那个端口号的 UDP）: " hp
      [ -z "$hp" ] && hp="25160"
      load_info
      if [ ! -f "$CONF_DIR/cert.pem" ]; then
        openssl req -x509 -newkey rsa:2048 -keyout "$CONF_DIR/key.pem" -out "$CONF_DIR/cert.pem" -days 365 -nodes -subj "/CN=www.bing.com" 2>/dev/null && echo "证书已生成"
      fi
      python3 - "$hp" <<'PYEOF'
import json, sys
hp = int(sys.argv[1])
p = "/root/sing-box-conf/config.json"
d = json.load(open(p))
d["inbounds"] = [i for i in d["inbounds"] if i.get("type") != "hysteria2"]
d["inbounds"].append({
  "type": "hysteria2", "tag": "hy2-in",
  "listen": "0.0.0.0", "listen_port": hp,
  "users": [{"password": d["inbounds"][0]["users"][0]["uuid"]}],
  "tls": {"enabled": True,
          "certificate_path": "/root/sing-box-conf/cert.pem",
          "key_path": "/root/sing-box-conf/key.pem"}
})
json.dump(d, open(p, "w"), indent=2)
print("HY2 已写入配置，端口", hp)
PYEOF
      /root/sing-box check -c "$CONF" && echo "配置 OK"
      stop_node; start_node
      echo ""
      echo "HY2 链接（服务器地址填你这台机的 SSH 域名和端口）："
      echo "hysteria2://$UUID@<你的SSH域名>:$hp?sni=www.bing.com&insecure=1#Altare-HY2"
      echo "在手机上测一下，超时就是 UDP 没映射出来，用不了。"
      ;;
    2)
      python3 - <<'PYEOF'
import json
p = "/root/sing-box-conf/config.json"
d = json.load(open(p))
d["inbounds"] = [i for i in d["inbounds"] if i.get("type") != "hysteria2"]
json.dump(d, open(p, "w"), indent=2)
print("HY2 已删除")
PYEOF
      /root/sing-box check -c "$CONF" && echo "配置 OK"
      stop_node; start_node
      echo "已删除 HY2 并重启。"
      ;;
    *) echo "返回。";;
  esac
}

# ---------- 9. 查看日志 ----------
do_logs() {
  echo "--- 查看日志 ---"
  echo "1. sing-box 日志"
  echo "2. cloudflared 日志"
  echo "0. 返回"
  read -rp "请输入选择 (0-2): " c
  case "$c" in
    1) tail -40 "$SB_LOG" 2>/dev/null || echo "暂无日志。";;
    2) tail -40 "$CF_LOG" 2>/dev/null || echo "暂无日志。";;
    *) echo "返回。";;
  esac
}

# ---------- 主菜单 ----------
while true; do
  clear
  echo "Telegram群组：https://t.me/eooceu"
  echo "Github地址：https://github.com/eooce/sing-box"
  echo ""
  echo "=== Altare 节点管理脚本 ==="
  status_line
  echo "=========================="
  echo "1. 安装节点"
  echo "2. 卸载节点"
  echo "=========================="
  echo "3. 节点管理（重启/停止）"
  echo "4. Argo隧道管理"
  echo "=========================="
  echo "5. 查看节点信息"
  echo "6. 修改节点配置"
  echo "7. 管理节点订阅"
  echo "8. 增加/删除协议"
  echo "=========================="
  echo "9. 查看日志"
  echo "=========================="
  echo "0. 退出脚本"
  echo "=========================="
  read -rp "请输入选择 (0-9): " choice
  case "$choice" in
    1) do_install;;
    2) do_uninstall;;
    3) do_manage;;
    4) do_tunnel;;
    5) do_info;;
    6) do_change;;
    7) do_sub;;
    8) do_proto;;
    9) do_logs;;
    0) echo "退出。"; exit 0;;
    *) echo "无效选择。";;
  esac
  echo ""
  read -rp "按回车返回菜单..." _
done
