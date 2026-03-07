use std::{fs, path::PathBuf};

use openkoto_desktop_lib::{
    agent_worker::{
        apply_worker_event_in_dir, build_mind_map_worker_request,
        mark_running_tasks_interrupted_in_dir, parse_worker_event_line, WorkerHealth,
        WorkerRuntimeState,
    },
    storage::{load_agent_task_in_dir, load_artifact_in_dir, save_agent_task_in_dir},
    types::{AgentTask, AgentTaskInput, AgentTaskStatus, AgentTaskType, Article},
};

fn temp_data_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "openkoto-agent-worker-{}-{}",
        name,
        uuid::Uuid::new_v4()
    ));
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn save_article_fixture(data_dir: &PathBuf, article: &Article) {
    let articles_dir = data_dir.join("articles");
    fs::create_dir_all(&articles_dir).unwrap();
    fs::write(
        articles_dir.join(&article.id),
        serde_json::to_string(article).unwrap(),
    )
    .unwrap();
}

fn sample_task(status: AgentTaskStatus) -> AgentTask {
    AgentTask {
        id: "task-1".to_string(),
        task_type: AgentTaskType::MindMapGenerate,
        status,
        article_id: "article-1".to_string(),
        input: AgentTaskInput {
            article_id: "article-1".to_string(),
            display_language: "zh-CN".to_string(),
            max_depth: 3,
            evidence_mode: "strict".to_string(),
            prefer_structure: "topic_tree".to_string(),
        },
        progress: 0.0,
        stage: Some("queued".to_string()),
        message: None,
        error: None,
        worker_session_id: None,
        artifact_ids: Vec::new(),
        created_at: "2026-03-07T00:00:00Z".to_string(),
        updated_at: "2026-03-07T00:00:00Z".to_string(),
        started_at: None,
        finished_at: None,
    }
}

fn sample_article() -> Article {
    Article {
        id: "article-1".to_string(),
        title: "Sample Article".to_string(),
        content: "Alpha beta gamma. Delta epsilon zeta.".to_string(),
        source_type: Some("article".to_string()),
        source_url: None,
        media_path: None,
        book_path: None,
        book_type: None,
        created_at: "2026-03-07T00:00:00Z".to_string(),
        translated: false,
        active_mind_map_artifact_id: None,
        segments: Vec::new(),
    }
}

fn sample_mind_map_result() -> serde_json::Value {
    serde_json::json!({
        "status": "applicable",
        "reason": null,
        "map": {
            "version": "1",
            "article_id": "article-1",
            "title": "Sample Article",
            "display_language": "zh-CN",
            "generation_mode": "evidence_first",
            "source_hash": "sha256:test",
            "summary": "summary",
            "root": {
                "id": "root",
                "title": "Root",
                "node_type": "root",
                "summary": "summary",
                "confidence": 1.0,
                "source_segment_ids": [],
                "source_offsets": [],
                "children": []
            }
        },
        "diagnostics": {
            "content_type": "article",
            "coverage": "full",
            "notes": [],
            "window_count": 1,
            "evidence_density": 1.0,
            "low_confidence_node_ids": []
        }
    })
}

#[test]
fn worker_request_contains_task_and_article_payload() {
    let request = build_mind_map_worker_request(&sample_task(AgentTaskStatus::Queued), &sample_article());

    assert_eq!(request["type"], "request");
    assert_eq!(request["method"], "task.start");
    assert_eq!(request["params"]["task_type"], "mind_map.generate");
    assert_eq!(request["params"]["payload"]["article_id"], "article-1");
    assert_eq!(request["params"]["payload"]["article"]["title"], "Sample Article");
}

#[test]
fn worker_health_turns_unhealthy_after_timeout() {
    let now = chrono::Utc::now();
    let stale = WorkerRuntimeState {
        worker_session_id: Some("worker-1".to_string()),
        started_at: Some(now - chrono::Duration::seconds(60)),
        last_heartbeat_at: Some(now - chrono::Duration::seconds(20)),
    };

    assert!(matches!(
        stale.health(now, chrono::Duration::seconds(10)),
        WorkerHealth::Unhealthy
    ));
}

#[test]
fn running_tasks_can_be_marked_interrupted_after_restart() {
    let data_dir = temp_data_dir("interrupt");
    let task = sample_task(AgentTaskStatus::Running);
    save_agent_task_in_dir(&data_dir, &task).unwrap();

    let interrupted = mark_running_tasks_interrupted_in_dir(&data_dir).unwrap();
    let stored = load_agent_task_in_dir(&data_dir, &task.id).unwrap();

    assert_eq!(interrupted, vec![task.id]);
    assert!(matches!(stored.status, AgentTaskStatus::Interrupted));
}

#[test]
fn parses_task_result_events_from_worker_stdout() {
    let event = parse_worker_event_line(
        &serde_json::json!({
            "type": "event",
            "event": "task.result",
            "payload": {
                "task_id": "task-1",
                "content": sample_mind_map_result(),
            }
        })
        .to_string(),
    )
    .unwrap();

    assert_eq!(event.event_name(), "task.result");
}

#[test]
fn result_events_persist_artifact_and_complete_task() {
    let data_dir = temp_data_dir("result");
    let task = sample_task(AgentTaskStatus::Running);
    save_article_fixture(&data_dir, &sample_article());
    save_agent_task_in_dir(&data_dir, &task).unwrap();

    let event = parse_worker_event_line(
        &serde_json::json!({
            "type": "event",
            "event": "task.result",
            "payload": {
                "task_id": task.id,
                "content": sample_mind_map_result(),
            }
        })
        .to_string(),
    )
    .unwrap();

    apply_worker_event_in_dir(&data_dir, &mut WorkerRuntimeState {
        worker_session_id: Some("worker-1".to_string()),
        started_at: Some(chrono::Utc::now()),
        last_heartbeat_at: None,
    }, event)
    .unwrap();

    let stored_task = load_agent_task_in_dir(&data_dir, &task.id).unwrap();
    assert!(matches!(stored_task.status, AgentTaskStatus::Succeeded));
    assert_eq!(stored_task.artifact_ids.len(), 1);

    let artifact = load_artifact_in_dir(&data_dir, &stored_task.article_id, &stored_task.artifact_ids[0]).unwrap();
    assert_eq!(artifact.article_id, "article-1");
    assert_eq!(artifact.content["status"], "applicable");
}
