---
name: skill-creator
description: >
  创建与管理 MiniClaw 的 Agent 技能。当用户要新建技能、把一段工作流沉淀成可复用技能、或想了解技能的目录格式与 frontmatter 规范时使用。
compatibility: 无外部依赖；
version: 2.1.0
---

# Skill Creator

把一个可复用的工作流沉淀为技能，使其能被自动发现、注入 system prompt 并触发。

## 何时使用

- 用户说「把 XX 做成一个技能」「新建一个技能」「skill 怎么写」
- 某类任务反复出现、值得固化成指令集

## 技能目录格式（MinisSkills 兼容）

每个技能是一个**小写 kebab-case** 目录，内含 `SKILL.md`：

```
<skill-name>/
├── SKILL.md          # 必需：YAML frontmatter + 指令正文
├── scripts/          # 可选：确定性/重复任务，Agent 直接运行
├── references/       # 可选：按需加载的参考文档
├── assets/           # 可选：模板、图标、字体
└── evals/            # 可选：evals/evals.json 测试用例
```

## SKILL.md 结构

```yaml
---
name: skill-name
description: >
  一句话描述做什么，以及何时应当触发（含用户短语、上下文、关键词）。
compatibility: 可选依赖说明
---

# 技能标题
指令正文：用祈使句，解释 why；固定输出用显式模板；正文建议 < 500 行。
```

## 输出格式

新建技能时，给出：

1. 目录名（kebab-case）
2. `SKILL.md` 完整内容（frontmatter + 正文）
3. 如有可执行脚本，放到 `scripts/`

## 注意

- 不要在 SKILL.md 中硬编码密钥/凭证
- `description` 决定触发，要具体、略"主动"，覆盖边角场景
