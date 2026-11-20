# altare-node

Altare / 无 systemd 容器一键部署 VLESS 节点（固定 CF 隧道），菜单版管理脚本。

仿 eooce 老王 sing-box 四合一的操作方式：装、管、改、看节点信息都在一个菜单里。

## 一键部署

先去 Cloudflare 建一条固定隧道（Argo Tunnel），拿到 token 和域名，再跑：

```bash
bash <(curl -sL https://raw.githubusercontent.com/niuyeye1206/altare-node/main/altare-node.sh)
```

或下载后运行：

```bash
bash altare-node.sh
```

首次进菜单选 **1. 安装节点**，按提示填：
- CF 隧道 token（必填）
- 隧道域名，如 `altare-bne.noc.us.ci`（必填）
- UUID（回车自动生成）
- WS 路径（回车默认 `/vless-argo`）
- 本地端口（回车默认 `8001`）

跑完直接打印 VLESS 节点链接。

## 菜单

```
=== Altare 节点管理脚本 ===
1. 安装节点
2. 卸载节点
3. 节点管理（重启/停止）
4. Argo隧道管理
5. 查看节点信息
6. 修改节点配置
7. 管理节点订阅
8. 增加/删除协议
9. 查看日志
0. 退出脚本
```

## 说明

- 部署内容：sing-box 1.14.4 + cloudflared 2026.11.1，VLESS + WS + TLS 走固定 CF 隧道。
- Altare 容器没有 systemd，全部用 nohup 后台跑；自启靠 `/root/start-node.sh` + 看门狗（`/root/watchdog.sh`，每 30 秒查一次）。
- 面板自启：去 Altare 面板 Startup Command 里，先跑 `/root/start-node.sh` 再跑原来的启动命令，例如：
  ```
  bash /root/start-node.sh; ./.sandbox/start.sh
  ```
- HY2 走直连 UDP，Altare 容器一般只映射了 SSH 的 TCP 端口，UDP 大概率不通，菜单里可以加，但要自己实测。
- 配置保存在 `/root/sing-box-conf/config.json`，token 在 `/root/.argo-token`（600），节点信息在 `/root/.node-info`。
