//! kodex 自定义 ModelProvider 实现。
//!
//! 在此处实现你的自定义 provider，
//! 然后在 `codex-rs/model-provider/src/provider.rs` 的
//! `create_model_provider` 函数中添加分支来使用它。

// TODO: 实现自定义 ModelProvider
// 参考 codex-rs/model-provider/src/amazon_bedrock/ 的实现模式
//
// use std::fmt;
// use std::path::PathBuf;
// use std::sync::Arc;
//
// use async_trait::async_trait;
// use codex_login::{AuthManager, CodexAuth};
// use codex_model_provider::ModelProvider;
// use codex_model_provider_info::ModelProviderInfo;
// use codex_models_manager::SharedModelsManager;
// use codex_protocol::config_types::ProviderCapabilities;
// use codex_protocol::error::Result;
// use codex_protocol::models::ModelsResponse;
// use codex_protocol::provider::{Provider, ProviderAccountResult, SharedAuthProvider};

/// kodex 自定义 ModelProvider 占位。
///
/// 接入方式：
/// 1. 在此文件中实现 `ModelProvider` trait
/// 2. 在 `codex-rs/model-provider/src/provider.rs` 的
///    `create_model_provider()` 中添加：
///    ```rust
///    if provider_info.name() == "kodex-custom" {
///        return Arc::new(KodexModelProvider::new(provider_info));
///    }
///    ```
pub struct KodexModelProvider {
    // info: ModelProviderInfo,
}

impl KodexModelProvider {
    pub fn new(/* info: ModelProviderInfo */) -> Self {
        Self {}
    }
}

// TODO: 实现 ModelProvider trait
// #[async_trait]
// impl ModelProvider for KodexModelProvider {
//     fn info(&self) -> &ModelProviderInfo { &self.info }
//     fn auth_manager(&self) -> Option<Arc<AuthManager>> { None }
//     async fn auth(&self) -> Option<CodexAuth> { None }
//     fn account_state(&self) -> ProviderAccountResult { ... }
//     fn models_manager(&self, ...) -> SharedModelsManager { ... }
// }
