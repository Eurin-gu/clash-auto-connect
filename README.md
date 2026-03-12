# Clash 智能自动连接脚本

![GitHub](https://img.shields.io/github/license/Eurin-gu/clash-auto-connect)
![Shell Script](https://img.shields.io/badge/made%20with-bash-1f425f.svg)

适用于 Ubuntu 22.04 的 Clash 管理脚本，通过 `clashctl` 实现订阅更新、节点测速、自动切换最快节点、系统代理设置等功能，并支持开机自启动无人值守模式。

---

## 📦 功能特性

- ✅ 启动/停止/重启 Clash 服务
- ✅ 更新订阅配置
- ✅ 获取代理组和节点列表
- ✅ 批量测试节点延迟（并发 5 个，超时 5000ms）
- ✅ 自动切换到延迟最低的节点（支持无人值守模式）
- ✅ 设置/取消系统代理环境变量（HTTP/HTTPS/SOCKS5）
- ✅ 测试代理连通性（访问 Google 并获取出口 IP）
- ✅ 开机自启动（通过 `~/.config/autostart` 桌面文件）

---

## 🔧 依赖

- `curl`、`jq`（用于 API 调用和 JSON 解析）
- `clashctl` 工具（Clash 的配套管理命令，确保已安装并正确配置）

安装依赖：
```bash
sudo apt update
sudo apt install curl jq -y

🚀 快速开始
1. 克隆仓库
bash
git clone https://github.com/Eurin-gu/clash-auto-connect.git
cd clash-auto-connect
2. 配置 Clash API 密钥
脚本需要访问 Clash 的 RESTful API（默认端口 9090），因此需要提供密钥。

方法一：创建外部密钥文件（推荐，避免密钥泄露）

bash
echo 'CLASH_SECRET="你的实际密钥"' > ~/.clash_secret
密钥可从 Clash 配置文件获取，例如 /opt/clash-for-linux/conf/config.yaml 中的 secret 字段。

方法二：直接编辑脚本（不推荐，但快速）
打开 clashctl-manager.sh，找到 CLASH_SECRET= 一行，填入你的密钥。

3. 运行自动连接模式
bash
./clashctl-manager.sh auto
此命令会自动：

启动 Clash 服务

测速并切换到延迟最低的节点

开启系统代理

📖 命令行用法
直接执行脚本进入交互式菜单，或使用以下参数：

命令	说明
./clashctl-manager.sh start	启动 Clash 服务
./clashctl-manager.sh stop	停止 Clash 服务
./clashctl-manager.sh restart	重启 Clash 服务
./clashctl-manager.sh update	更新订阅配置
./clashctl-manager.sh speedtest "节点选择"	测试指定代理组的节点延迟
./clashctl-manager.sh auto	全自动模式：启动 + 测速 + 切换最快节点 + 开启代理
./clashctl-manager.sh proxy on	开启系统代理（设置环境变量）
./clashctl-manager.sh proxy off	关闭系统代理
./clashctl-manager.sh test	测试代理连通性（访问 Google 并显示出口 IP）
🖥️ 开机自启动配置
将示例桌面文件复制到用户 autostart 目录：

bash
cp autostart/clashctl-auto.desktop ~/.config/autostart/
编辑 ~/.config/autostart/clashctl-auto.desktop，确保 Exec 行中的路径正确（例如 /home/你的用户名/clash-auto-connect/clashctl-manager.sh auto）。

如需延迟启动（等待网络就绪），可改为：

ini
Exec=bash -c "sleep 15 && /home/你的用户名/clash-auto-connect/clashctl-manager.sh auto"
配置完成后，重启系统即可自动运行 Clash 并连接最快节点。

⚠️ 注意事项
脚本依赖 clashctl 命令，请确保该工具已正确安装并位于 PATH 中。

Clash API 默认端口为 9090，如需修改请编辑脚本中的 API_PORT 变量。

节点延迟测试使用 http://www.gstatic.com/generate_204 作为测试 URL，可根据网络环境调整。

代理环境变量仅对当前终端及通过该终端启动的程序生效。如需全局生效，可在 ~/.bashrc 中添加：

bash
export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
export all_proxy=socks5://127.0.0.1:7890
端口请根据 Clash 配置调整（默认为 7890）。

🤝 贡献
欢迎提交 Issue 或 Pull Request 来改进脚本。如果你发现了 bug 或有新功能建议，请随时联系。

📄 许可证
本项目采用 MIT 许可证。详情请参见 LICENSE 文件。

text


