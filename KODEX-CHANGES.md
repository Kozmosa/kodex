# Kodex — Upstream Modification Log

本文件记录 kodex 对上游 (openai/codex) 代码的**所有直接修改**。
每次同步上游时，用此文件快速定位需要处理的冲突。

## 分支策略

```
main       ← 追踪上游 openai/codex（干净，无自定义代码）
kodex-dev  ← 自定义开发分支（所有 kodex 改动在这里）
```

## 同步工作流

```powershell
# 推荐：使用同步脚本（自动更新 main + rebase kodex-dev）
.\scripts\sync-upstream.ps1

# 只查看差异，不执行同步
.\scripts\sync-upstream.ps1 -DryRun

# 只更新 main，不自动 rebase kodex-dev
.\scripts\sync-upstream.ps1 -MainOnly
```

手动同步步骤：

```bash
# 1. 获取上游更新
git fetch upstream

# 2. 更新 main（fast-forward）
git checkout main
git merge upstream/main --ff-only

# 3. Rebase kodex-dev 到 main
git checkout kodex-dev
git rebase main

# 4. 解决冲突后，检查本文件列出的所有修改点是否仍然正确
```

## 修改清单

### Cargo 工作区

| 文件 | 修改内容 | 原因 |
|------|---------|------|
| `codex-rs/Cargo.toml` | workspace members 中添加 `kodex` | 注册 kodex 自定义 crate |

### 模型/Provider 层

| 文件 | 修改内容 | 原因 |
|------|---------|------|
| `codex-rs/model-provider/src/provider.rs` | `create_model_provider()` 中添加自定义 provider 分支 | 接入 kodex 自定义 provider |

### Prompt/上下文工程

| 文件 | 修改内容 | 原因 |
|------|---------|------|
| *(待添加)* | | |

### UI/交互层

| 文件 | 修改内容 | 原因 |
|------|---------|------|
| *(待添加)* | | |

### 扩展注册

| 文件 | 修改内容 | 原因 |
|------|---------|------|
| `codex-rs/app-server/src/extensions.rs` | 添加 kodex 扩展的 `install` 调用 | 注册自定义扩展 |

### 配置/其他

| 文件 | 修改内容 | 原因 |
|------|---------|------|
| *(待添加)* | | |

---

## 同步检查清单

每次同步上游后，按顺序检查：

- [ ] `codex-rs/Cargo.toml` — workspace members 列表是否仍然正确
- [ ] `codex-rs/model-provider/src/provider.rs` — `create_model_provider` 函数签名和逻辑是否变化
- [ ] `codex-rs/app-server/src/extensions.rs` — `thread_extensions` 函数签名是否变化
- [ ] `codex-rs/core/src/session/mod.rs` — `build_initial_context` 函数是否变化（如果修改了 prompt 管线）
- [ ] `codex-rs/tui/src/app.rs` — `App` 结构体是否变化（如果修改了 UI）
- [ ] 编译通过：`cargo build` 在 `codex-rs/` 下
- [ ] 测试通过：`cargo test` 在 `codex-rs/` 下
