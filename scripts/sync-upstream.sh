#!/usr/bin/env bash
# sync-upstream.sh — 同步上游 openai/codex 到 kodex
#
# 分支策略:
#   main      — 追踪上游 openai/codex（干净）
#   kodex-dev — 自定义开发分支（你的工作在这里）
#
# 用法:
#   ./scripts/sync-upstream.sh              # 更新 main 并 rebase kodex-dev
#   ./scripts/sync-upstream.sh --dry-run    # 只查看差异，不执行同步
#   ./scripts/sync-upstream.sh --main-only  # 只更新 main，不 rebase kodex-dev

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

DRY_RUN=false
MAIN_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --dry-run)  DRY_RUN=true ;;
        --main-only) MAIN_ONLY=true ;;
        -h|--help)
            echo "用法: $0 [--dry-run] [--main-only]"
            echo "  --dry-run    只查看差异，不执行同步"
            echo "  --main-only  只更新 main，不 rebase kodex-dev"
            exit 0
            ;;
        *)
            echo -e "${RED}❌ 未知参数: $arg${NC}"
            exit 1
            ;;
    esac
done

# 检查是否有未提交的更改
if [ -n "$(git status --porcelain)" ]; then
    echo -e "${RED}❌ 工作区有未提交的更改，请先 commit 或 stash${NC}"
    exit 1
fi

# 检查 upstream remote
if ! git remote | grep -q "^upstream$"; then
    echo -e "${YELLOW}❌ 未找到 upstream remote，正在添加...${NC}"
    git remote add upstream https://github.com/openai/codex.git
fi

echo -e "${CYAN}📡 获取上游更新...${NC}"
git fetch upstream

UPSTREAM_COMMIT=$(git rev-parse upstream/main)
MAIN_COMMIT=$(git rev-parse main)
BEHIND=$(git rev-list --count "$MAIN_COMMIT..$UPSTREAM_COMMIT")

echo ""
echo -e "${CYAN}📊 状态:${NC}"
echo "  上游落后: $BEHIND 个 commit"
echo ""

if [ "$BEHIND" -eq 0 ]; then
    echo -e "${GREEN}✅ main 已经是最新，无需同步${NC}"
    exit 0
fi

if [ "$DRY_RUN" = true ]; then
    echo -e "${CYAN}📋 上游新增的 commit（前 20 个）:${NC}"
    git log --oneline "$MAIN_COMMIT..$UPSTREAM_COMMIT" | head -20

    # 检查 kodex-dev 是否有对上游文件的修改
    echo ""
    echo -e "${YELLOW}📋 kodex-dev 中修改的文件:${NC}"
    KODEX_CHANGES=$(git diff --name-only main kodex-dev 2>/dev/null || true)
    if [ -n "$KODEX_CHANGES" ]; then
        echo "$KODEX_CHANGES" | while read -r f; do
            echo "  $f"
        done
    else
        echo -e "  ${GREEN}（无）${NC}"
    fi
    exit 0
fi

# 步骤 1：更新 main
echo -e "${CYAN}🔄 步骤 1: 更新 main 到上游最新...${NC}"
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "main" ]; then
    git checkout main
fi
git merge upstream/main --ff-only
echo -e "${GREEN}✅ main 已更新${NC}"

if [ "$MAIN_ONLY" = true ]; then
    echo ""
    echo -e "${YELLOW}💡 提示: 运行 'git checkout kodex-dev && git rebase main' 来同步 kodex-dev${NC}"
    exit 0
fi

# 步骤 2：Rebase kodex-dev
echo ""
echo -e "${CYAN}🔄 步骤 2: Rebase kodex-dev 到 main...${NC}"
git checkout kodex-dev
if ! git rebase main; then
    echo -e "${RED}❌ Rebase 冲突，请手动解决后执行:${NC}"
    echo -e "   ${YELLOW}git rebase --continue${NC}"
    echo -e "   ${YELLOW}提示: 参考 KODEX-CHANGES.md 中的修改清单来定位冲突点${NC}"
    exit 1
fi
echo -e "${GREEN}✅ kodex-dev 已 rebase 到最新 main${NC}"

echo ""
echo -e "${CYAN}🔍 同步后检查:${NC}"
echo "  1. 运行 'cargo build -p codex-cli' 确认编译通过"
echo "  2. 运行 'cargo test' 确认测试通过"
echo "  3. 更新 KODEX-CHANGES.md 中的修改清单"
