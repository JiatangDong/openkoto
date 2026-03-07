use openkoto_desktop_lib::{
    commands::require_active_agent_model_config,
    types::{AppConfig, ModelConfig},
};

fn sample_model_config() -> ModelConfig {
    ModelConfig {
        id: "model-1".to_string(),
        name: "Primary".to_string(),
        api_key: "secret".to_string(),
        api_provider: "google".to_string(),
        model: "gemini-2.0-flash".to_string(),
        is_default: true,
        created_at: Some("2026-03-07T00:00:00Z".to_string()),
        base_url: None,
    }
}

#[test]
fn require_active_agent_model_config_requires_any_saved_config() {
    let error = require_active_agent_model_config(None).unwrap_err();

    assert_eq!(error, "未配置 API，请先在设置中配置 AI 模型");
}

#[test]
fn require_active_agent_model_config_requires_active_entry() {
    let error = require_active_agent_model_config(Some(AppConfig::default())).unwrap_err();

    assert_eq!(error, "未设置活动模型配置，请先在设置中配置 AI 模型");
}

#[test]
fn require_active_agent_model_config_returns_selected_model() {
    let expected = sample_model_config();
    let config = AppConfig {
        active_model_id: Some(expected.id.clone()),
        model_configs: vec![expected.clone()],
        ..AppConfig::default()
    };

    let resolved = require_active_agent_model_config(Some(config)).unwrap();

    assert_eq!(resolved.id, expected.id);
    assert_eq!(resolved.api_provider, "google");
}
