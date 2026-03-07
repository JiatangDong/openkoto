use crate::commands::save_mind_map_artifact_in_dir;
use crate::storage::{
    list_agent_tasks_in_dir, load_agent_task_in_dir, save_agent_task_in_dir,
    update_article_active_mind_map_artifact_in_dir,
};
use crate::types::{AgentTask, AgentTaskStatus, Article, Artifact};
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use tauri::{AppHandle, Emitter, Manager};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkerHealth {
    Starting,
    Healthy,
    Unhealthy,
    Stopped,
}

#[derive(Debug, Clone)]
pub struct WorkerRuntimeState {
    pub worker_session_id: Option<String>,
    pub started_at: Option<DateTime<Utc>>,
    pub last_heartbeat_at: Option<DateTime<Utc>>,
}

impl Default for WorkerRuntimeState {
    fn default() -> Self {
        Self {
            worker_session_id: None,
            started_at: None,
            last_heartbeat_at: None,
        }
    }
}

impl WorkerRuntimeState {
    pub fn health(&self, now: DateTime<Utc>, timeout: Duration) -> WorkerHealth {
        if self.worker_session_id.is_none() {
            return WorkerHealth::Stopped;
        }
        match self.last_heartbeat_at {
            Some(last_heartbeat) if now - last_heartbeat <= timeout => WorkerHealth::Healthy,
            Some(_) => WorkerHealth::Unhealthy,
            None if self.started_at.is_some() => WorkerHealth::Starting,
            None => WorkerHealth::Stopped,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum WorkerEvent {
    #[serde(rename = "task.progress")]
    TaskProgress { payload: WorkerTaskProgressPayload },
    #[serde(rename = "worker.heartbeat")]
    WorkerHeartbeat { payload: WorkerHeartbeatPayload },
    #[serde(rename = "task.result")]
    TaskResult { payload: WorkerTaskResultPayload },
    #[serde(rename = "task.error")]
    TaskError { payload: WorkerTaskErrorPayload },
}

impl WorkerEvent {
    pub fn event_name(&self) -> &'static str {
        match self {
            Self::TaskProgress { .. } => "task.progress",
            Self::WorkerHeartbeat { .. } => "worker.heartbeat",
            Self::TaskResult { .. } => "task.result",
            Self::TaskError { .. } => "task.error",
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct WorkerTaskProgressPayload {
    pub task_id: String,
    pub stage: String,
    pub progress: f64,
    #[serde(default)]
    pub message: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct WorkerHeartbeatPayload {
    pub worker_session_id: String,
    pub timestamp: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct WorkerTaskResultPayload {
    pub task_id: String,
    pub content: Value,
}

#[derive(Debug, Clone, Deserialize)]
pub struct WorkerTaskErrorPayload {
    pub task_id: String,
    pub message: String,
}

#[derive(Debug, Deserialize)]
struct WorkerEventEnvelope {
    #[serde(rename = "type")]
    message_type: String,
    #[serde(flatten)]
    event: WorkerEvent,
}

#[derive(Debug, Clone, Serialize)]
pub struct AgentWorkerStatusSnapshot {
    pub health: WorkerHealth,
    pub worker_session_id: Option<String>,
    pub started_at: Option<String>,
    pub last_heartbeat_at: Option<String>,
}

#[derive(Debug, Clone)]
pub struct WorkerLaunchConfig {
    pub program: String,
    pub args: Vec<String>,
    pub cwd: PathBuf,
    pub envs: Vec<(String, String)>,
}

pub struct AgentWorkerManager {
    runtime_state: Arc<Mutex<WorkerRuntimeState>>,
    child: Arc<Mutex<Option<Child>>>,
    stdin: Arc<Mutex<Option<ChildStdin>>>,
}

impl Default for AgentWorkerManager {
    fn default() -> Self {
        Self {
            runtime_state: Arc::new(Mutex::new(WorkerRuntimeState::default())),
            child: Arc::new(Mutex::new(None)),
            stdin: Arc::new(Mutex::new(None)),
        }
    }
}

impl AgentWorkerManager {
    pub fn status_snapshot(&self) -> AgentWorkerStatusSnapshot {
        let state = self.runtime_state.lock().unwrap().clone();
        AgentWorkerStatusSnapshot {
            health: state.health(Utc::now(), Duration::seconds(45)),
            worker_session_id: state.worker_session_id,
            started_at: state.started_at.map(|value| value.to_rfc3339()),
            last_heartbeat_at: state.last_heartbeat_at.map(|value| value.to_rfc3339()),
        }
    }

    pub fn stop(&self) -> Result<(), String> {
        if let Some(mut child) = self.child.lock().unwrap().take() {
            child
                .kill()
                .map_err(|e| format!("Failed to stop agent worker: {}", e))?;
            let _ = child.wait();
        }
        self.stdin.lock().unwrap().take();
        *self.runtime_state.lock().unwrap() = WorkerRuntimeState::default();
        Ok(())
    }

    pub fn ensure_started(&self, app_handle: &AppHandle) -> Result<(), String> {
        if self.is_process_alive()? {
            return Ok(());
        }

        let config = resolve_worker_launch_config(app_handle)?;
        let mut command = Command::new(&config.program);
        command
            .args(&config.args)
            .current_dir(&config.cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        for (key, value) in &config.envs {
            command.env(key, value);
        }

        let mut child = command
            .spawn()
            .map_err(|e| format!("Failed to launch agent worker: {}", e))?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| "Agent worker stdin unavailable".to_string())?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| "Agent worker stdout unavailable".to_string())?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| "Agent worker stderr unavailable".to_string())?;

        *self.child.lock().unwrap() = Some(child);
        *self.stdin.lock().unwrap() = Some(stdin);
        *self.runtime_state.lock().unwrap() = WorkerRuntimeState {
            worker_session_id: None,
            started_at: Some(Utc::now()),
            last_heartbeat_at: None,
        };

        let data_dir = app_handle
            .path()
            .app_data_dir()
            .map_err(|e| format!("Failed to get app data dir: {}", e))?;
        spawn_stdout_listener(
            stdout,
            app_handle.clone(),
            data_dir,
            Arc::clone(&self.runtime_state),
        );
        spawn_stderr_listener(stderr);

        Ok(())
    }

    pub fn submit_mind_map_task(
        &self,
        app_handle: &AppHandle,
        task: &AgentTask,
        article: &Article,
    ) -> Result<(), String> {
        self.ensure_started(app_handle)?;
        let mut persisted_task = task.clone();
        persisted_task.status = AgentTaskStatus::Running;
        persisted_task.stage = Some("queued".to_string());
        persisted_task.updated_at = Utc::now().to_rfc3339();
        if persisted_task.started_at.is_none() {
            persisted_task.started_at = Some(persisted_task.updated_at.clone());
        }
        let session_id = self
            .runtime_state
            .lock()
            .unwrap()
            .worker_session_id
            .clone();
        if persisted_task.worker_session_id.is_none() {
            persisted_task.worker_session_id = session_id;
        }
        save_agent_task_in_dir(
            &app_handle
                .path()
                .app_data_dir()
                .map_err(|e| format!("Failed to get app data dir: {}", e))?,
            &persisted_task,
        )?;

        let request = build_mind_map_worker_request(&persisted_task, article);
        let mut guard = self.stdin.lock().unwrap();
        let stdin = guard
            .as_mut()
            .ok_or_else(|| "Agent worker stdin is not available".to_string())?;
        writeln!(stdin, "{}", request)
            .and_then(|_| stdin.flush())
            .map_err(|e| format!("Failed to send task to agent worker: {}", e))?;
        Ok(())
    }

    fn is_process_alive(&self) -> Result<bool, String> {
        let mut guard = self.child.lock().unwrap();
        let Some(child) = guard.as_mut() else {
            return Ok(false);
        };
        match child
            .try_wait()
            .map_err(|e| format!("Failed to inspect agent worker: {}", e))?
        {
            Some(_) => {
                guard.take();
                self.stdin.lock().unwrap().take();
                *self.runtime_state.lock().unwrap() = WorkerRuntimeState::default();
                Ok(false)
            }
            None => Ok(true),
        }
    }
}

pub fn build_mind_map_worker_request(task: &AgentTask, article: &Article) -> serde_json::Value {
    serde_json::json!({
        "id": task.id,
        "type": "request",
        "method": "task.start",
        "params": {
            "task_id": task.id,
            "task_type": "mind_map.generate",
            "payload": {
                "article_id": article.id,
                "display_language": task.input.display_language,
                "max_depth": task.input.max_depth,
                "evidence_mode": task.input.evidence_mode,
                "prefer_structure": task.input.prefer_structure,
                "article": article,
            }
        }
    })
}

pub fn parse_worker_event_line(line: &str) -> Result<WorkerEvent, String> {
    let envelope: WorkerEventEnvelope =
        serde_json::from_str(line).map_err(|e| format!("Failed to parse worker event: {}", e))?;
    if envelope.message_type != "event" {
        return Err(format!(
            "Unsupported worker message type: {}",
            envelope.message_type
        ));
    }
    Ok(envelope.event)
}

pub fn apply_worker_event_in_dir(
    data_dir: &std::path::Path,
    runtime_state: &mut WorkerRuntimeState,
    event: WorkerEvent,
) -> Result<Option<Artifact>, String> {
    match event {
        WorkerEvent::WorkerHeartbeat { payload } => {
            runtime_state.worker_session_id = Some(payload.worker_session_id);
            runtime_state.last_heartbeat_at = Some(
                DateTime::parse_from_rfc3339(&payload.timestamp)
                    .map_err(|e| format!("Failed to parse heartbeat timestamp: {}", e))?
                    .with_timezone(&Utc),
            );
            if runtime_state.started_at.is_none() {
                runtime_state.started_at = runtime_state.last_heartbeat_at;
            }
            Ok(None)
        }
        WorkerEvent::TaskProgress { payload } => {
            let mut task = load_agent_task_in_dir(data_dir, &payload.task_id)?;
            task.status = AgentTaskStatus::Running;
            task.progress = payload.progress.clamp(0.0, 1.0);
            task.stage = Some(payload.stage);
            task.message = payload.message;
            task.updated_at = Utc::now().to_rfc3339();
            if task.started_at.is_none() {
                task.started_at = Some(task.updated_at.clone());
            }
            if task.worker_session_id.is_none() {
                task.worker_session_id = runtime_state.worker_session_id.clone();
            }
            save_agent_task_in_dir(data_dir, &task)?;
            Ok(None)
        }
        WorkerEvent::TaskResult { payload } => {
            let mut task = load_agent_task_in_dir(data_dir, &payload.task_id)?;
            let artifact =
                save_mind_map_artifact_in_dir(data_dir, &task.id, &task.article_id, payload.content)?;
            update_article_active_mind_map_artifact_in_dir(
                data_dir,
                &task.article_id,
                Some(artifact.id.clone()),
            )?;
            task.status = AgentTaskStatus::Succeeded;
            task.progress = 1.0;
            task.stage = Some("done".to_string());
            task.message = Some("Mind map generated".to_string());
            task.error = None;
            task.updated_at = Utc::now().to_rfc3339();
            task.finished_at = Some(task.updated_at.clone());
            task.worker_session_id = runtime_state.worker_session_id.clone();
            if !task.artifact_ids.iter().any(|id| id == &artifact.id) {
                task.artifact_ids.push(artifact.id.clone());
            }
            if task.started_at.is_none() {
                task.started_at = Some(task.updated_at.clone());
            }
            save_agent_task_in_dir(data_dir, &task)?;
            Ok(Some(artifact))
        }
        WorkerEvent::TaskError { payload } => {
            let mut task = load_agent_task_in_dir(data_dir, &payload.task_id)?;
            task.status = AgentTaskStatus::Failed;
            task.error = Some(payload.message);
            task.updated_at = Utc::now().to_rfc3339();
            task.finished_at = Some(task.updated_at.clone());
            task.worker_session_id = runtime_state.worker_session_id.clone();
            if task.started_at.is_none() {
                task.started_at = Some(task.updated_at.clone());
            }
            save_agent_task_in_dir(data_dir, &task)?;
            Ok(None)
        }
    }
}

pub fn mark_running_tasks_interrupted_in_dir(
    data_dir: &std::path::Path,
) -> Result<Vec<String>, String> {
    let task_ids = list_agent_tasks_in_dir(data_dir)?;
    let mut interrupted = Vec::new();

    for task_id in task_ids {
        let mut task = load_agent_task_in_dir(data_dir, &task_id)?;
        if matches!(task.status, AgentTaskStatus::Running | AgentTaskStatus::Queued) {
            task.status = AgentTaskStatus::Interrupted;
            task.updated_at = Utc::now().to_rfc3339();
            if task.finished_at.is_none() {
                task.finished_at = Some(task.updated_at.clone());
            }
            save_agent_task_in_dir(data_dir, &task)?;
            interrupted.push(task.id.clone());
        }
    }

    Ok(interrupted)
}

pub fn resolve_worker_launch_config(app_handle: &AppHandle) -> Result<WorkerLaunchConfig, String> {
    if let Ok(program) = std::env::var("TEXTLINGO_AGENT_WORKER_PROGRAM") {
        let args = std::env::var("TEXTLINGO_AGENT_WORKER_ARGS")
            .unwrap_or_default()
            .split_whitespace()
            .filter(|value| !value.is_empty())
            .map(str::to_string)
            .collect();
        let cwd = std::env::var("TEXTLINGO_AGENT_WORKER_CWD")
            .map(PathBuf::from)
            .unwrap_or_else(|_| worker_project_dir());
        return Ok(WorkerLaunchConfig {
            program,
            args,
            cwd,
            envs: default_worker_envs(app_handle)?,
        });
    }

    let cwd = worker_project_dir();
    ensure_worker_bundle(&cwd)?;
    Ok(WorkerLaunchConfig {
        program: "node".to_string(),
        args: vec!["dist/index.js".to_string()],
        cwd,
        envs: default_worker_envs(app_handle)?,
    })
}

fn default_worker_envs(app_handle: &AppHandle) -> Result<Vec<(String, String)>, String> {
    let mut envs = Vec::new();
    if let Ok(value) = std::env::var("TEXTLINGO_AGENT_WORKER_USE_MOCK") {
        envs.push(("TEXTLINGO_AGENT_WORKER_USE_MOCK".to_string(), value));
    }
    if let Ok(value) = std::env::var("TEXTLINGO_AGENT_MODEL") {
        envs.push(("TEXTLINGO_AGENT_MODEL".to_string(), value));
    }
    if let Ok(value) = std::env::var("TEXTLINGO_CLAUDE_CODE_PATH") {
        envs.push(("TEXTLINGO_CLAUDE_CODE_PATH".to_string(), value));
    }
    envs.push((
        "TEXTLINGO_APP_DATA_DIR".to_string(),
        app_handle
            .path()
            .app_data_dir()
            .map_err(|e| format!("Failed to get app data dir: {}", e))?
            .to_string_lossy()
            .into_owned(),
    ));
    Ok(envs)
}

fn worker_project_dir() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or(manifest_dir)
        .join("agent-worker")
}

fn ensure_worker_bundle(cwd: &Path) -> Result<(), String> {
    let entry = cwd.join("dist").join("index.js");
    if entry.exists() {
        return Ok(());
    }

    let status = Command::new("npm")
        .args(["run", "build"])
        .current_dir(cwd)
        .status()
        .map_err(|e| format!("Failed to build agent worker bundle: {}", e))?;
    if !status.success() {
        return Err("Failed to build agent worker bundle".to_string());
    }
    Ok(())
}

fn spawn_stdout_listener(
    stdout: impl std::io::Read + Send + 'static,
    app_handle: AppHandle,
    data_dir: PathBuf,
    runtime_state: Arc<Mutex<WorkerRuntimeState>>,
) {
    thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            let Ok(line) = line else {
                break;
            };
            let event = match parse_worker_event_line(&line) {
                Ok(event) => event,
                Err(error) => {
                    eprintln!("[AgentWorker] Failed to parse stdout line: {}", error);
                    continue;
                }
            };

            let artifact = {
                let mut state = runtime_state.lock().unwrap();
                match apply_worker_event_in_dir(&data_dir, &mut state, event.clone()) {
                    Ok(artifact) => artifact,
                    Err(error) => {
                        eprintln!("[AgentWorker] Failed to apply worker event: {}", error);
                        continue;
                    }
                }
            };

            emit_worker_event(&app_handle, &data_dir, &event, artifact.as_ref());
        }
    });
}

fn spawn_stderr_listener(stderr: impl std::io::Read + Send + 'static) {
    thread::spawn(move || {
        for line in BufReader::new(stderr).lines() {
            match line {
                Ok(value) => eprintln!("[AgentWorker] {}", value),
                Err(_) => break,
            }
        }
    });
}

fn emit_worker_event(
    app_handle: &AppHandle,
    data_dir: &Path,
    event: &WorkerEvent,
    artifact: Option<&Artifact>,
) {
    match event {
        WorkerEvent::TaskProgress { payload } => {
            if let Ok(task) = load_agent_task_in_dir(data_dir, &payload.task_id) {
                let _ = app_handle.emit(&format!("mind-map-progress://{}", payload.task_id), &task);
                let _ = app_handle.emit("agent-task-updated", &task);
            }
        }
        WorkerEvent::TaskResult { payload } => {
            if let Ok(task) = load_agent_task_in_dir(data_dir, &payload.task_id) {
                let _ = app_handle.emit(&format!("mind-map-finished://{}", payload.task_id), &task);
                let _ = app_handle.emit("agent-task-updated", &task);
            }
            if let Some(saved_artifact) = artifact {
                let _ = app_handle.emit("mind-map-artifact-saved", saved_artifact);
            }
        }
        WorkerEvent::TaskError { payload } => {
            if let Ok(task) = load_agent_task_in_dir(data_dir, &payload.task_id) {
                let _ = app_handle.emit(&format!("mind-map-error://{}", payload.task_id), &task);
                let _ = app_handle.emit("agent-task-updated", &task);
            }
        }
        WorkerEvent::WorkerHeartbeat { .. } => {
            let _ = app_handle.emit("agent-worker-status", "heartbeat");
        }
    }
}
