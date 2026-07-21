"""Session Memory Agent v2.0.0 — 全自动跨终端会话同步"""

__version__ = "2.0.0"

# v2 已实现功能:
# 1. 知识图谱抽取 - 从对话历史自动提取实体和关系 (Gemma4-E2B)
# 2. 会话摘要 - AI驱动的会话摘要+行动项+决策提取
# 3. 主动召回 - Agent在新对话里主动从历史召回相关上下文 (RRF 混合检索)
# 4. 时间穿梭 - 追踪事实和观点如何随时间演进 (双时态KG)
# 5. 记忆衰减 - Ebbinghaus遗忘曲线+矛盾检测
# 6. 跨会话续接 - 让Agent记住上一次对话，无缝续接
# 7. [NEW] 本地SQLite队列 - 断网不丢，恢复后自动补推
# 8. [NEW] 后台守护进程 - 独立daemon持续drain队列
# 9. [NEW] 自动历史迁移 - 首次运行自动导入bash_history + Hermes DB
# 10. [NEW] 零侵入钩子 - 加一行到bashrc，PROMPT_COMMAND自动捕获
