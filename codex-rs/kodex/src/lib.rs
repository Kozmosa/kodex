//! # Kodex
//!
//! kodex 的自定义扩展层。
//! 所有 kodex 对上游 openai/codex 的定制逻辑集中在此 crate 中，
//! 以最小化对上游文件的直接修改。

mod prompt;
mod provider;

pub use prompt::install_kodex_extension;
pub use provider::KodexModelProvider;
