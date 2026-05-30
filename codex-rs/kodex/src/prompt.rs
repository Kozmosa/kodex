//! kodex 自定义 ContextContributor 实现。
//!
//! 通过实现 ContextContributor trait，
//! 可以向模型的 system prompt 注入自定义内容。

use std::sync::Arc;

use async_trait::async_trait;
use codex_core::Config;
use codex_extension_api::{
    ContextContributor, ExtensionData, PromptFragment, PromptSlot,
};

/// kodex 自定义 prompt 注入器。
///
/// 在此处添加你想要注入到模型 prompt 中的自定义内容。
/// 可以根据 session/thread 状态动态生成 prompt 片段。
pub struct KodexContextContributor;

impl KodexContextContributor {
    pub fn new() -> Self {
        Self
    }
}

#[async_trait]
impl ContextContributor<Config> for KodexContextContributor {
    async fn contribute(
        &self,
        _session_data: &ExtensionData,
        _thread_data: &ExtensionData,
    ) -> Vec<PromptFragment> {
        let mut fragments = Vec::new();

        // TODO: 添加自定义 prompt 片段
        //
        // 示例：注入自定义指令到 developer policy slot
        // fragments.push(PromptFragment::new(
        //     PromptSlot::DeveloperPolicy,
        //     "你的自定义指令内容...",
        // ));
        //
        // 可用的 PromptSlot：
        //   - DeveloperPolicy      → developer role message 的 policy 部分
        //   - DeveloperCapabilities → developer role message 的 capabilities 部分
        //   - ContextualUser       → 作为 user role message 注入
        //   - SeparateDeveloper    → 作为独立的 developer role message 注入

        fragments
    }
}

/// 注册 kodex 扩展到 ExtensionRegistry。
///
/// 在 `codex-rs/app-server/src/extensions.rs` 的 `thread_extensions()` 中
/// 添加调用：
/// ```rust
/// kodex::install_kodex_extension(&mut builder);
/// ```
pub fn install_kodex_extension(
    registry: &mut codex_extension_api::ExtensionRegistryBuilder<Config>,
) {
    let contributor = Arc::new(KodexContextContributor::new());
    registry.prompt_contributor(contributor);
}
