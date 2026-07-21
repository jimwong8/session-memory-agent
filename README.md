# Session Memory Agent v2.0.0

一键对接 [Session Memory](https://github.com/jimwong8/session-memory) 会话记忆系统的自动化代理。让所有终端的会话自动同步、跨终端共享历史经验。

## 架构

```
终端 A ──┐
终端 B ──┼── Local SQLite Queue ── API ──► Session Memory (10.100.1.13:8000)
终端 C ──┘                              │
                                        ├── 知识图谱 (Gemma4-E2B)
                                        ├── 向量检索 (bge-m3 1024维)
                                        ├── BM25 全文
                                        └── RRF 混合 + Rerank
```

## v2 新特性

- 🗣️ **对话自动入库** — 每轮对话自动写入 Session Memory API
- 🐚 **Shell 历史同步** — bash 命令自动跨终端汇聚
- ⚡ **本地 SQLite 队列** — 断网不丢，恢复后自动补推
- 👻 **后台守护进程** — 独立 daemon 持续 drain 队列
- 🔄 **自动历史迁移** — 首次运行自动导入 .bash_history + Hermes state.db
- 🪝 **零侵入钩子** — 加一行到 .bashrc，PROMPT_COMMAND 自动捕获
- 📡 **自动会话恢复** — 终端重启自动延续同一会话

## 快速开始

### 一键安装
```bash
curl -fsSL https://raw.githubusercontent.com/jimwong8/session-memory-agent/main/install.sh | bash
```

### 自定义 Session Memory 主机
```bash
curl -fsSL https://raw.githubusercontent.com/jimwong8/session-memory-agent/main/install.sh | SESSION_MEMORY_HOST=10.100.1.13 bash
```

### 手动安装
```bash
git clone https://github.com/jimwong8/session-memory-agent.git
cd session-memory-agent
bash install.sh 10.100.1.13
source ~/.bashrc
```

## 文件结构

```
~/.session-memory-agent/
├── memory_hook.py     # Python 核心（队列 + 守护进程 + 迁移）
├── hook.sh            # Shell 钩子（PROMPT_COMMAND）
├── queue.db           # SQLite 本地队列
├── .session_id        # 当前会话 ID
├── .initialized       # 首次运行标记
└── hook.log           # 运行日志
```

## 使用指南

### 自动模式（推荐）
安装后自动工作：
- 每次 shell prompt 自动捕获命令
- 后台 daemon 持续同步到 Session Memory
- 重启终端自动恢复会话

### 手动操作
```bash
# 查看队列状态
python3 ~/.session-memory-agent/memory_hook.py status

# 手动触发历史迁移
python3 ~/.session-memory-agent/memory_hook.py migrate

# 手动运行一次同步
python3 ~/.session-memory-agent/memory_hook.py daemon
```

### 跨平台

| 平台 | 状态 |
|------|------|
| Linux (Debian/Ubuntu) | ✅ 完全支持 |
| macOS | ✅ 完全支持 |
| Windows (Git Bash) | ✅ 支持 |

## 配置

| 环境变量 | 默认值 | 说明 |
|---------|--------|------|
| `SMH_API` | `http://10.100.1.13:8000` | Session Memory API 地址 |
| `SMH_DIR` | `~/.session-memory-agent` | 本地数据目录 |

## 故障排查

```bash
# 1. 检查 API 连通性
curl http://10.100.1.13:8000/health

# 2. 检查队列
python3 ~/.session-memory-agent/memory_hook.py status

# 3. 查看日志
tail -20 ~/.session-memory-agent/hook.log

# 4. 强制重启 daemon
pkill -f "memory_hook.py daemon"
source ~/.bashrc
```

## 技术栈

- **Session Memory API**: FastAPI + PostgreSQL (pgvector) + Redis
- **LLM 抽取**: Gemma-4-E2B-Q4_K_M (本地)
- **嵌入**: BAAI/bge-m3 (1024 维)
- **重排**: bge-reranker-v2-m3
- **检索**: RRF 混合 (向量 + BM25 + 图谱)

## License

MIT
