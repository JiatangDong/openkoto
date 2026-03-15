use openkoto_desktop_lib::{
    commands::{
        filter_material_summaries, material_summary_from_article, require_active_agent_model_config,
        MaterialSummary,
    },
    pdf_sidecar::{build_pdf_sidecar_command_for_dir, resolve_pdf_sidecar_for_dir},
    types::{AppConfig, Article, ModelConfig},
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

fn sample_article_defaults() -> Article {
    Article {
        id: "article-1".to_string(),
        title: "Sample".to_string(),
        content: "body".to_string(),
        source_type: Some("article".to_string()),
        source_url: None,
        media_path: None,
        book_path: None,
        book_type: None,
        created_at: "2026-03-08T00:00:00Z".to_string(),
        translated: false,
        active_mind_map_artifact_id: None,
        segments: Vec::new(),
    }
}

fn sample_material_summary(id: &str, title: &str, material_type: &str) -> MaterialSummary {
    MaterialSummary {
        id: id.to_string(),
        title: title.to_string(),
        material_type: material_type.to_string(),
        created_at: "2026-03-08T00:00:00Z".to_string(),
        translated: false,
    }
}

#[test]
fn resolve_pdf_sidecar_for_dir_reports_missing_sidecar() {
    let dir = std::env::temp_dir().join(format!(
        "openkoto-missing-pdf-sidecar-{}",
        uuid::Uuid::new_v4()
    ));
    std::fs::create_dir_all(&dir).unwrap();

    let error = resolve_pdf_sidecar_for_dir(&dir, true).unwrap_err();

    assert!(error.contains("PDF sidecar"));

    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn build_pdf_sidecar_command_for_dir_uses_dev_sidecar_entrypoint() {
    let root = std::env::temp_dir().join(format!(
        "openkoto-pdf-sidecar-command-{}",
        uuid::Uuid::new_v4()
    ));
    let base_dir = root.join("textlingo-desktop/src-tauri");
    let sidecar_dir = root.join("textlingo-desktop/pdf-sidecar/openkoto_pdf_translator");

    std::fs::create_dir_all(&base_dir).unwrap();
    std::fs::create_dir_all(&sidecar_dir).unwrap();
    std::fs::write(sidecar_dir.join("pdf2zh.py"), b"print('ok')").unwrap();

    let command = build_pdf_sidecar_command_for_dir(
        &base_dir,
        true,
        "/tmp/sample.pdf",
        "auto",
        "zh",
        "/tmp/output",
    )
    .unwrap();

    assert_eq!(command.program, "python");
    assert_eq!(
        command.args,
        vec![
            "-m",
            "openkoto_pdf_translator.pdf2zh",
            "/tmp/sample.pdf",
            "-li",
            "auto",
            "-lo",
            "zh",
            "-s",
            "openkoto",
            "-o",
            "/tmp/output",
        ]
    );
    assert_eq!(
        command.working_dir,
        root.join("textlingo-desktop/pdf-sidecar").canonicalize().unwrap()
    );

    std::fs::remove_dir_all(&root).unwrap();
}

#[test]
fn resolve_pdf_sidecar_for_dir_uses_bundled_binary_name() {
    let root = std::env::temp_dir().join(format!(
        "openkoto-pdf-sidecar-bundled-{}",
        uuid::Uuid::new_v4()
    ));
    let binaries_dir = root.join("binaries");
    std::fs::create_dir_all(&binaries_dir).unwrap();

    let binary_name = if cfg!(target_os = "macos") {
        if cfg!(target_arch = "aarch64") {
            "openkoto-pdf-translator-aarch64-apple-darwin"
        } else {
            "openkoto-pdf-translator-x86_64-apple-darwin"
        }
    } else if cfg!(target_os = "windows") {
        "openkoto-pdf-translator-x86_64-pc-windows-msvc.exe"
    } else {
        "openkoto-pdf-translator-x86_64-unknown-linux-gnu"
    };

    let binary_path = binaries_dir.join(binary_name);
    std::fs::write(&binary_path, b"binary").unwrap();

    let command = resolve_pdf_sidecar_for_dir(&root, false).unwrap();

    assert_eq!(command.program, binary_path.to_string_lossy().to_string());
    assert_eq!(command.working_dir, binaries_dir.canonicalize().unwrap());

    std::fs::remove_dir_all(&root).unwrap();
}

#[test]
fn resolve_pdf_sidecar_for_dir_finds_macos_app_bundle_sidecar() {
    if !cfg!(target_os = "macos") {
        return;
    }

    let root = std::env::temp_dir().join(format!(
        "openkoto-pdf-sidecar-app-bundle-{}",
        uuid::Uuid::new_v4()
    ));
    let resources_dir = root.join("OpenKoto Desktop.app/Contents/Resources");
    let macos_dir = root.join("OpenKoto Desktop.app/Contents/MacOS");
    std::fs::create_dir_all(&resources_dir).unwrap();
    std::fs::create_dir_all(&macos_dir).unwrap();

    let binary_path = macos_dir.join("openkoto-pdf-translator");
    std::fs::write(&binary_path, b"binary").unwrap();

    let command = resolve_pdf_sidecar_for_dir(&resources_dir, false).unwrap();

    assert_eq!(command.program, binary_path.to_string_lossy().to_string());
    assert_eq!(command.working_dir, macos_dir.canonicalize().unwrap());

    std::fs::remove_dir_all(&root).unwrap();
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

#[test]
fn material_summary_from_article_maps_book_and_media_types() {
    let article = Article {
        id: "article-1".to_string(),
        title: "N1 Reading".to_string(),
        content: "body".to_string(),
        source_type: Some("web".to_string()),
        book_type: Some("pdf".to_string()),
        translated: true,
        ..sample_article_defaults()
    };

    let summary = material_summary_from_article(&article);

    assert_eq!(summary.material_type, "pdf");
    assert!(summary.translated);
    assert_eq!(summary.title, "N1 Reading");
}

#[test]
fn filter_material_summaries_applies_keyword_and_type() {
    let items = vec![
        sample_material_summary("1", "N1 PDF", "pdf"),
        sample_material_summary("2", "Podcast", "audio"),
        sample_material_summary("3", "N1 Audio", "audio"),
    ];

    let result = filter_material_summaries(&items, Some("N1"), Some("pdf"), 20);

    assert_eq!(result.len(), 1);
    assert_eq!(result[0].id, "1");
}
