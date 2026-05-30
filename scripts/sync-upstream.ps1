# sync-upstream.ps1 — 同步上游 openai/codex 到 kodex
#
# 分支策略:
#   main      — 追踪上游 openai/codex（干净）
#   kodex-dev — 自定义开发分支（你的工作在这里）
#
# 用法:
#   .\scripts\sync-upstream.ps1              # 更新 main 并 rebase kodex-dev
#   .\scripts\sync-upstream.ps1 -DryRun      # 只查看差异，不执行同步
#   .\scripts\sync-upstream.ps1 -MainOnly    # 只更新 main，不 rebase kodex-dev

param(
    [switch]$DryRun,
    [switch]$MainOnly
)

$ErrorActionPreference = "Stop"

# 检查是否有未提交的更改
$status = git status --porcelain
if ($status) {
    Write-Host "❌ 工作区有未提交的更改，请先 commit 或 stash" -ForegroundColor Red
    exit 1
}

# 检查 upstream remote
$remotes = git remote
if ($remotes -notcontains "upstream") {
    Write-Host "❌ 未找到 upstream remote，正在添加..." -ForegroundColor Yellow
    git remote add upstream https://github.com/openai/codex.git
}

Write-Host "📡 获取上游更新..." -ForegroundColor Cyan
git fetch upstream

$upstreamCommit = git rev-parse upstream/main
$mainCommit = git rev-parse main
$behind = (git rev-list --count "$mainCommit..$upstreamCommit")

Write-Host ""
Write-Host "📊 状态:" -ForegroundColor Cyan
Write-Host "  上游落后: $behind 个 commit"
Write-Host ""

if ($behind -eq 0) {
    Write-Host "✅ main 已经是最新，无需同步" -ForegroundColor Green
    exit 0
}

if ($DryRun) {
    Write-Host "📋 上游新增的 commit（前 20 个）:" -ForegroundColor Cyan
    git log --oneline "$mainCommit..$upstreamCommit" | Select-Object -First 20

    # 检查 kodex-dev 是否有对上游文件的修改
    Write-Host ""
    Write-Host "📋 kodex-dev 中修改的上游文件:" -ForegroundColor Yellow
    $kodexChanges = git diff --name-only main kodex-dev 2>$null
    if ($kodexChanges) {
        $kodexChanges | ForEach-Object { Write-Host "  $_" }
    } else {
        Write-Host "  （无）" -ForegroundColor Green
    }
    exit 0
}

# 步骤 1：更新 main
Write-Host "🔄 步骤 1: 更新 main 到上游最新..." -ForegroundColor Cyan
$currentBranch = git branch --show-current
if ($currentBranch -ne "main") {
    git checkout main
}
git merge upstream/main --ff-only
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ main 无法 fast-forward，可能有本地 commit。请手动处理。" -ForegroundColor Red
    exit 1
}
Write-Host "✅ main 已更新" -ForegroundColor Green

if ($MainOnly) {
    Write-Host ""
    Write-Host "💡 提示: 运行 'git checkout kodex-dev && git rebase main' 来同步 kodex-dev" -ForegroundColor Yellow
    exit 0
}

# 步骤 2：Rebase kodex-dev
Write-Host ""
Write-Host "🔄 步骤 2: Rebase kodex-dev 到 main..." -ForegroundColor Cyan
git checkout kodex-dev
git rebase main
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Rebase 冲突，请手动解决后执行:" -ForegroundColor Red
    Write-Host "   git rebase --continue" -ForegroundColor Yellow
    Write-Host "   提示: 参考 KODEX-CHANGES.md 中的修改清单来定位冲突点" -ForegroundColor Yellow
    exit 1
}
Write-Host "✅ kodex-dev 已 rebase 到最新 main" -ForegroundColor Green

Write-Host ""
Write-Host "🔍 同步后检查:" -ForegroundColor Cyan
Write-Host "  1. 运行 'cargo build -p codex-cli' 确认编译通过"
Write-Host "  2. 运行 'cargo test' 确认测试通过"
Write-Host "  3. 更新 KODEX-CHANGES.md 中的修改清单"
