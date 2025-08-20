# 自动代码审查设置指南

## 概述

本项目现在配置了三种自动代码审查机制，会在您每次提交代码或创建 Pull Request 时自动运行：

1. **AI 代码审查** - 使用 GitHub Copilot/GPT 进行智能代码分析
2. **Sourcery AI 审查** - 专业的代码质量和重构建议
3. **综合代码质量检查** - 多工具集成的代码质量分析

## 🚀 立即可用的功能

### 当前已激活的审查：

- ✅ **综合代码质量检查** - 无需额外配置，立即可用
- ✅ **基础 AI 审查** - 使用 GitHub 的内置 AI 功能
- ⚠️ **Sourcery AI** - 需要配置 token（可选）

## 📋 配置步骤

### 1. 无需配置（立即可用）

**综合代码质量检查**已经可以正常工作，包括：
- GDScript 文件分析
- Python 代码风格检查
- JavaScript/TypeScript 质量检查
- 安全漏洞扫描
- 代码统计和建议

### 2. 启用 Sourcery AI（可选但推荐）

1. 访问 [Sourcery.ai](https://sourcery.ai/) 注册账户
2. 获取您的 API token
3. 在 GitHub 仓库中添加 Secret：
   - 进入仓库 Settings → Secrets and variables → Actions
   - 点击 "New repository secret"
   - Name: `SOURCERY_TOKEN`
   - Value: 您的 Sourcery API token

### 3. GitHub Copilot 增强审查

如果您有 GitHub Copilot 订阅，AI 代码审查会自动使用更强大的模型进行分析。

## 🔄 工作流程

### 自动触发时机：

1. **Push 到主要分支**：
   - `main`
   - `develop`
   - `feature/*` 分支

2. **Pull Request 事件**：
   - 创建新的 PR
   - 更新 PR（新提交）
   - 重新打开 PR

### 审查内容：

#### 🤖 AI 代码审查
- 代码质量和最佳实践分析
- 潜在 bug 和安全问题检测
- 性能优化建议
- 代码可读性评估
- 编码规范检查

#### 🔍 Sourcery AI 审查
- 智能重构建议
- 代码简化方案
- 性能优化提示
- Python/JavaScript 专项分析

#### 📊 综合质量检查
- 多语言语法检查
- 代码风格验证
- 安全漏洞扫描
- 复杂度分析
- 统计报告

## 📝 示例输出

### Pull Request 评论示例：
```markdown
## 🤖 AI 代码审查报告

### 📁 Scripts/noise_manager.gd
- ✅ 代码结构清晰，函数职责明确
- 💡 建议：第234行的循环可以考虑使用更高效的算法
- ⚠️ 注意：第156行缺少错误处理

### 💡 改进建议
1. 添加输入参数验证
2. 考虑添加单元测试
3. 更新相关文档
```

### Commit 评论示例：
```markdown
## 📊 代码质量分析报告

### 🎮 GDScript 文件
#### 📄 Scripts/new_feature.gd
- **行数**: 145
- **函数数量**: 8
- ✅ 代码风格良好
- 📝 包含待办事项

### 💡 通用建议
- 确保所有新功能都有适当的注释
- 考虑添加单元测试覆盖新代码
```

## ⚙️ 自定义配置

### 修改触发条件

编辑 `.github/workflows/*.yml` 文件中的 `on:` 部分：

```yaml
on:
  push:
    branches: [main, develop, 'feature/*']  # 自定义分支
  pull_request:
    types: [opened, synchronize]  # 自定义事件
```

### 调整分析范围

在 workflow 文件中修改文件过滤条件：

```bash
# 只分析特定类型的文件
grep -E '\.(gd|py|js|ts|cs)$' changed_files.txt
```

### 自定义规则

#### GDScript 检查规则：
在 `code-quality-check.yml` 中的 GDScript 部分添加自定义检查：

```bash
# 检查命名规范
if grep -q "var [A-Z]" "$file"; then
  echo "- ⚠️ 变量名应使用snake_case" >> analysis_report.md
fi
```

## 🛠️ 故障排除

### 常见问题：

1. **权限问题**
   - 确保 workflow 有足够的权限
   - 检查 `permissions:` 配置

2. **Token 问题**
   - 验证 `SOURCERY_TOKEN` 是否正确设置
   - 检查 token 是否过期

3. **分析工具失败**
   - 某些工具失败不会阻止整个流程
   - 查看 Actions 日志了解具体错误

### 禁用特定检查：

如果某个检查不适用，可以在对应的 workflow 文件中注释掉相关步骤。

## 📈 效果展示

启用后，您将在以下位置看到自动评论：

1. **Pull Request 页面** - 每个 PR 都会收到详细的代码审查评论
2. **Commit 页面** - 直接推送的提交会收到质量分析评论
3. **Actions 标签页** - 查看详细的执行日志

## 🔄 下一步

1. **提交代码测试**：创建一个测试提交或 PR 来验证设置
2. **调整配置**：根据团队需求自定义审查规则
3. **团队培训**：让团队成员了解如何利用这些反馈

## 💡 最佳实践

1. **定期更新**：保持分析工具的最新版本
2. **团队协作**：将审查结果作为代码改进的参考，而非严格要求
3. **持续优化**：根据项目特点调整检查规则
4. **文档维护**：及时更新项目编码规范和最佳实践

---

**注意**：这些自动审查是辅助工具，不能完全替代人工代码审查。建议将两者结合使用以获得最佳效果。
