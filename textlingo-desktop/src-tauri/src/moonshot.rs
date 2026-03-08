pub const LEGACY_MOONSHOT_PROVIDER: &str = "moonshot";
pub const MOONSHOT_CN_PROVIDER: &str = "moonshot-cn";
pub const MOONSHOT_GLOBAL_PROVIDER: &str = "moonshot-global";

pub fn normalize_moonshot_provider(provider: &str) -> Option<&'static str> {
    match provider {
        LEGACY_MOONSHOT_PROVIDER | MOONSHOT_CN_PROVIDER => Some(MOONSHOT_CN_PROVIDER),
        MOONSHOT_GLOBAL_PROVIDER => Some(MOONSHOT_GLOBAL_PROVIDER),
        _ => None,
    }
}

pub fn is_moonshot_provider(provider: &str) -> bool {
    normalize_moonshot_provider(provider).is_some()
}

pub fn moonshot_base_url(provider: &str) -> Option<&'static str> {
    match normalize_moonshot_provider(provider) {
        Some(MOONSHOT_CN_PROVIDER) => Some("https://api.moonshot.cn/v1"),
        Some(MOONSHOT_GLOBAL_PROVIDER) => Some("https://api.moonshot.ai/v1"),
        _ => None,
    }
}

pub fn moonshot_chat_completions_url(provider: &str) -> Option<String> {
    moonshot_base_url(provider).map(|base_url| format!("{}/chat/completions", base_url))
}

pub fn moonshot_files_url(provider: &str) -> Option<String> {
    moonshot_base_url(provider).map(|base_url| format!("{}/files", base_url))
}
