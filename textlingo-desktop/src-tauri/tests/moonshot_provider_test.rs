use openkoto_desktop_lib::moonshot::{
    is_moonshot_provider, moonshot_base_url, moonshot_chat_completions_url, moonshot_files_url,
    normalize_moonshot_provider,
};

#[test]
fn normalizes_legacy_moonshot_to_china() {
    assert_eq!(normalize_moonshot_provider("moonshot"), Some("moonshot-cn"));
    assert!(is_moonshot_provider("moonshot"));
}

#[test]
fn resolves_official_regional_base_urls() {
    assert_eq!(
        moonshot_base_url("moonshot-cn"),
        Some("https://api.moonshot.cn/v1")
    );
    assert_eq!(
        moonshot_base_url("moonshot-global"),
        Some("https://api.moonshot.ai/v1")
    );
}

#[test]
fn resolves_chat_completion_and_files_endpoints() {
    assert_eq!(
        moonshot_chat_completions_url("moonshot-global").as_deref(),
        Some("https://api.moonshot.ai/v1/chat/completions")
    );
    assert_eq!(
        moonshot_files_url("moonshot-cn").as_deref(),
        Some("https://api.moonshot.cn/v1/files")
    );
}
