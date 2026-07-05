# DST 服务器管理工具箱 v2.3

> Don't Starve Together Dedicated Server Toolbox — 阿里云优化版

一站式管理饥荒联机版专用服务器：启动/停止/重启、集群切换、模组管理、存档备份、防火墙配置、一键初始化，全部通过交互式菜单操作。

---

## 功能概览

| 分类 | 功能 |
|------|------|
| **服务器** | 启动 / 停止 / 重启 / 运行状态 / 实时日志 |
| **集群** | 信息查看 / 配置编辑 / 切换 / 创建 / 导入 |
| **模组** | 仓库管理 / 批量导入 / 查看启用模组 / 启用/禁用/移除 |
| **备份** | 备份存档 / 恢复备份 / 备份列表 |
| **系统** | 防火墙配置 / 网络优化 / 更新服务端 / 一键初始化 |

## 核心特性

- **三层状态检测**：Screen 会话 → 游戏进程 → 日志标记（Sim paused），精准判定服务器状态
- **临时日志分流**：启动检测与历史日志分离，杜绝旧日志误判
- **重启全自动**：内部复用启动界面，停止→启动无缝衔接，无手动回车
- **精确进程管理**：基于 Screen 会话名和 PID 操作，不使用 `pkill -f`
- **SSH 独立运行**：`setsid` 启动进程，断开 SSH 不影响服务器
- **方向键菜单**：支持 ↑↓ 选择 + ESC 返回，交互体验友好

## 快速开始

### 环境要求

- Ubuntu/Debian 系统（推荐 root 用户）
- Bash 4.0+
- 已安装 DST Dedicated Server（未安装可使用一键初始化）

### 一键初始化（全新服务器）

```bash
# 上传脚本到服务器后
chmod +x dst-toolbox-v2.sh
bash dst-toolbox-v2.sh
# 选择菜单 22 → 一键初始化
```

初始化将自动完成：系统更新 → 依赖安装 → SteamCMD 部署 → DST 下载 → 防火墙配置 → 网络优化

### 日常使用

```bash
# 交互式菜单
bash dst-toolbox-v2.sh

# 命令行直接操作
bash dst-toolbox-v2.sh start              # 启动服务器
bash dst-toolbox-v2.sh stop               # 停止服务器
bash dst-toolbox-v2.sh restart            # 重启服务器
bash dst-toolbox-v2.sh status             # 查看状态
bash dst-toolbox-v2.sh backup             # 备份存档
bash dst-toolbox-v2.sh -c MyCluster start # 指定集群启动
```

## 菜单结构

```
【服务器】1-5
  1. 启动服务器        2. 停止服务器        3. 重启服务器
  4. 服务器运行状态    5. 查看实时日志

【集群】6-11
  6. 当前集群信息      7. 查看集群配置      8. 切换集群
  9. 创建集群         10. 修改集群配置     11. 导入集群

【模组】12-15
  12. 管理模组仓库     13. 导入模组         14. 查看当前集群模组
  15. 管理当前集群模组

【备份】16-18
  16. 备份集群         17. 恢复备份         18. 查看备份列表

【系统】19-22
  19. 配置防火墙       20. 网络优化         21. 更新服务器
  22. 一键初始化

【退出】0
```

## 目录结构

```
~/.klei/DoNotStarveTogether/          # Klei 配置根目录
├── Cluster_1/                        # 集群目录
│   ├── cluster.ini                   # 集群配置
│   ├── Master/
│   │   ├── server.ini                # 地面服务器配置
│   │   ├── server_log.txt            # 地面日志
│   │   ├── master_start_tmp.log      # 启动检测临时日志
│   │   └── modoverrides.lua          # 地面模组配置
│   └── Caves/
│       ├── server.ini                # 洞穴服务器配置
│       ├── server_log.txt            # 洞穴日志
│       ├── caves_start_tmp.log       # 启动检测临时日志
│       └── modoverrides.lua          # 洞穴模组配置
└── backups/                          # 备份目录
```

## 状态检测原理

```
Screen 会话 ──→ 进程存在性 ──→ 日志 Sim paused
   ↓                ↓                ↓
 Detached=正常   无进程=停止    有标记=已启动
 不存在=异常
```

- **运行中**：进程存在 + 日志有 Sim paused
- **启动中**：进程存在 + 日志无 Sim paused
- **已停止**：进程不存在
- **已崩溃**：Screen 存在但进程已退出

## 模组管理

模组仓库目录 `~/dst-mods-import/`，文件夹命名格式：`WorkshopID_模组名`

```
~/dst-mods-import/
├── 294123456_几何布局/
├── 345678901_四季不停/
└── ...
```

导入时自动：复制到服务器 mods 目录 → 写入 `dedicated_server_mods_setup.lua` → 修改双分片 `modoverrides.lua`

## 注意事项

- 首次使用建议先执行一键初始化（菜单 22）
- 修改集群配置前请先停止服务器
- 模组导入后需重启服务器生效
- 备份文件存储在 `~/.klei/DoNotStarveTogether/backups/`

## License

MIT
