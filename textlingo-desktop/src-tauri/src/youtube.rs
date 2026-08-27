use crate::logging::LogLevel;
use crate::types::{Article, ArticleSegment};
use chrono::Utc;
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use tauri::{AppHandle, Manager};
use tauri_plugin_shell::ShellExt;
use uuid::Uuid;

const VIDEOS_DIR: &str = "videos";

#[derive(Debug, Serialize, Deserialize)]
struct YtDlpOutput {
    id: String,
    title: String,
    #[serde(default)]
    ext: String,
}

struct YtDlpRun {
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    success: bool,
    /// True when the bundled sidecar was unusable and a system yt-dlp ran instead.
    used_fallback: bool,
}

fn log_yt(level: LogLevel, message: impl Into<String>) {
    crate::logging::log(level, "youtube", message);
}

/// Truncate on a char boundary. yt-dlp output is UTF-8 and frequently contains
/// CJK video titles, so slicing by byte index panics mid-character.
fn truncate_for_log(text: &str, max_chars: usize) -> String {
    let mut out: String = text.chars().take(max_chars).collect();
    if out.len() < text.len() {
        out.push('…');
    }
    out
}

fn binary_name(stem: &str) -> String {
    if cfg!(target_os = "windows") {
        format!("{stem}.exe")
    } else {
        stem.to_string()
    }
}

/// Directory to pass to `yt-dlp --ffmpeg-location`.
///
/// yt-dlp only searches `PATH`, and the bundled ffmpeg is never on it, so any
/// format that needs a merge or remux fails unless we point at it explicitly.
/// Tauri copies each `externalBin` next to the app executable with the target
/// triple stripped — `target/debug/ffmpeg` in dev, `Contents/MacOS/ffmpeg` in a
/// bundle — so the executable's own directory is what matters in a real build.
fn resolve_ffmpeg_location_for_yt_dlp() -> Option<String> {
    let ffmpeg = binary_name("ffmpeg");
    let mut dirs: Vec<PathBuf> = Vec::new();

    // Explicit override — the same env var `ffmpeg.rs` honours. Accepts either
    // the binary itself or the directory holding it.
    if let Some(raw) = std::env::var_os("OPENKOTO_FFMPEG") {
        let path = PathBuf::from(raw);
        if path.is_dir() {
            dirs.push(path);
        } else if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            dirs.push(parent.to_path_buf());
        }
    }

    // The sidecar Tauri copied beside us (dev target dir or .app bundle).
    if let Some(exe_dir) = std::env::current_exe().ok().and_then(|exe| exe.parent().map(Path::to_path_buf)) {
        dirs.push(exe_dir);
    }

    // Dev builds may run before the sidecar has been copied; the sources live
    // in src-tauri/binaries somewhere above the working directory.
    if cfg!(debug_assertions) {
        if let Ok(cwd) = std::env::current_dir() {
            for ancestor in cwd.ancestors().take(8) {
                dirs.push(ancestor.join("src-tauri").join("binaries"));
                dirs.push(ancestor.join("binaries"));
            }
        }
    }

    // Finally anything already on PATH (homebrew, /usr/local, ...).
    if let Some(path_var) = std::env::var_os("PATH") {
        dirs.extend(std::env::split_paths(&path_var));
    }

    dirs.into_iter()
        .find(|dir| dir.join(&ffmpeg).exists())
        .map(|dir| dir.to_string_lossy().into_owned())
}

fn expand_tilde(path_str: &str) -> PathBuf {
    if let Some(stripped) = path_str.strip_prefix("~/") {
        if let Ok(home) = std::env::var("HOME") {
            return PathBuf::from(home).join(stripped);
        }
    }
    PathBuf::from(path_str)
}

/// System `yt-dlp` installs to try, best first, when the sidecar can't run.
fn system_yt_dlp_candidates() -> Vec<String> {
    let binary = binary_name("yt-dlp");
    let mut candidates: Vec<String> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();

    // Explicit override wins and is used as given, path check or not.
    if let Ok(env_path) = std::env::var("OPENKOTO_YT_DLP") {
        let env_path = env_path.trim().to_string();
        if !env_path.is_empty() && seen.insert(env_path.clone()) {
            candidates.push(env_path);
        }
    }

    // `pip install --user` locations, newest interpreter first, then the usual
    // package-manager prefixes.
    let mut known: Vec<String> = (9..=14)
        .rev()
        .map(|minor| format!("~/Library/Python/3.{minor}/bin/{binary}"))
        .collect();
    known.push(format!("~/.local/bin/{binary}"));
    known.push(format!("/opt/homebrew/bin/{binary}"));
    known.push(format!("/usr/local/bin/{binary}"));

    for entry in known {
        let expanded = expand_tilde(&entry);
        if !expanded.exists() {
            continue;
        }
        let value = expanded.to_string_lossy().into_owned();
        if seen.insert(value.clone()) {
            candidates.push(value);
        }
    }

    // Bare name last: let the OS resolve it from PATH.
    if seen.insert(binary.clone()) {
        candidates.push(binary);
    }

    candidates
}

async fn run_system_yt_dlp(args: &[String]) -> Result<YtDlpRun, String> {
    let candidates = system_yt_dlp_candidates();
    log_yt(
        LogLevel::Info,
        format!("system yt-dlp candidates: {candidates:?}"),
    );

    let mut last_error = "no candidate found".to_string();

    for candidate in candidates {
        let output = match tokio::process::Command::new(&candidate)
            .args(args)
            .output()
            .await
        {
            Ok(output) => output,
            Err(e) => {
                last_error = format!("{candidate}: {e}");
                continue;
            }
        };

        let stderr = String::from_utf8_lossy(&output.stderr).into_owned();

        // A system install shouldn't hit this, but a PyInstaller build copied
        // into one of these directories would.
        if is_semaphore_error(&stderr) {
            log_yt(
                LogLevel::Warn,
                format!("{candidate} hit the same bootloader failure, trying next"),
            );
            last_error = format!("{candidate}: {}", truncate_for_log(&stderr, 300));
            continue;
        }

        log_yt(
            LogLevel::Info,
            format!(
                "system yt-dlp {candidate}: success={} stdout={}B stderr={}",
                output.status.success(),
                output.stdout.len(),
                truncate_for_log(&stderr, 500)
            ),
        );

        return Ok(YtDlpRun {
            success: output.status.success(),
            stdout: output.stdout,
            stderr: output.stderr,
            used_fallback: true,
        });
    }

    Err(format!("no usable system yt-dlp ({last_error})"))
}

/// The bundled yt-dlp is a PyInstaller one-file build whose bootloader needs a
/// SysV semaphore. Where SysV IPC is denied (some managed macOS installs) it
/// exits before yt-dlp itself ever starts.
fn is_semaphore_error(stderr: &str) -> bool {
    stderr.contains("Failed to initialize sync semaphore")
        || stderr.contains("semctl: Operation not permitted")
        || (stderr.contains("PYI-") && (stderr.contains("semctl") || stderr.contains("semaphore")))
}

/// The last `--print-json` line yt-dlp wrote, which is our signal that the
/// download actually produced something.
fn extract_metadata_json(stdout: &str) -> Option<&str> {
    stdout
        .lines()
        .map(str::trim)
        .filter(|line| line.starts_with('{'))
        .last()
}

/// Run yt-dlp, preferring the bundled sidecar and falling back to a system
/// install when the sidecar produces nothing usable.
///
/// The fallback triggers on "no metadata on stdout" rather than on a specific
/// error signature, so it also covers launcher failures we have no pattern for.
/// If no system yt-dlp exists we return the sidecar's own output so the caller
/// can still surface yt-dlp's real error message.
async fn run_yt_dlp(app: &AppHandle, args: &[String]) -> Result<YtDlpRun, String> {
    let sidecar = match app.shell().sidecar("yt-dlp") {
        Ok(command) => Some(command),
        Err(e) => {
            log_yt(
                LogLevel::Warn,
                format!("no yt-dlp sidecar available ({e}), using system yt-dlp"),
            );
            None
        }
    };

    let sidecar_run = match sidecar {
        Some(command) => match command.args(args.to_vec()).output().await {
            Ok(output) => Some(YtDlpRun {
                success: output.status.success(),
                stdout: output.stdout,
                stderr: output.stderr,
                used_fallback: false,
            }),
            Err(e) => {
                log_yt(LogLevel::Warn, format!("yt-dlp sidecar failed to run: {e}"));
                None
            }
        },
        None => None,
    };

    let Some(run) = sidecar_run else {
        return run_system_yt_dlp(args).await;
    };

    if extract_metadata_json(&String::from_utf8_lossy(&run.stdout)).is_some() {
        return Ok(run);
    }

    let stderr = String::from_utf8_lossy(&run.stderr).into_owned();
    if is_semaphore_error(&stderr) {
        log_yt(
            LogLevel::Warn,
            "yt-dlp sidecar aborted in its PyInstaller bootloader (SysV semaphore denied); \
             falling back to system yt-dlp",
        );
    } else {
        log_yt(
            LogLevel::Warn,
            format!(
                "yt-dlp sidecar returned no metadata (success={}), trying system yt-dlp: {}",
                run.success,
                truncate_for_log(&stderr, 500)
            ),
        );
    }

    match run_system_yt_dlp(args).await {
        Ok(fallback) => Ok(fallback),
        Err(e) => {
            log_yt(LogLevel::Warn, format!("system yt-dlp unavailable: {e}"));
            Ok(run)
        }
    }
}

/// Import a YouTube video: download, extract subs, create Article
/// 字幕下载是可选的，如果失败会继续导入视频（后续可用 TTS 识别）
pub async fn import_youtube_video(app: AppHandle, url: String) -> Result<Article, String> {
    let app_data_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| format!("Failed to get app data dir: {}", e))?;

    let videos_dir = app_data_dir.join(VIDEOS_DIR);
    if !videos_dir.exists() {
        fs::create_dir_all(&videos_dir)
            .map_err(|e| format!("Failed to create videos dir: {}", e))?;
    }

    // 1. Run yt-dlp to download video and subs
    // Output template: videos_dir/%(id)s.%(ext)s
    let output_template = videos_dir.join("%(id)s.%(ext)s");
    let output_template_str = output_template.to_str().ok_or("Invalid output path")?;

    let ffmpeg_location = resolve_ffmpeg_location_for_yt_dlp();
    log_yt(
        LogLevel::Info,
        format!("ffmpeg location for yt-dlp: {ffmpeg_location:?}"),
    );

    // 构建 yt-dlp 参数 - 健壮的格式选择器，支持 DASH-only 视频
    let mut yt_dlp_args: Vec<String> = vec![
        "--no-warnings".to_string(),
        "--ignore-errors".to_string(),
        "--write-sub".to_string(),
        "--write-auto-sub".to_string(),
        "--sub-lang".to_string(),
        "en,zh-Hans,zh-Hant,zh,zh-CN,zh-TW".to_string(),
        "--convert-subs".to_string(),
        "srt".to_string(),
        "-f".to_string(),
        // 健壮的格式选择器:
        // - 22/18: 预合并 MP4 (无需 ffmpeg)
        // - bestvideo[ext=mp4][vcodec^=avc][height<=1080]+bestaudio[ext=m4a] : DASH 1080p + 音频，需 ffmpeg 合并
        // - bestvideo[ext=mp4]+bestaudio[ext=m4a] / bestvideo[height<=1080]+bestaudio / bv*+ba / best 回退
        "22/18/bestvideo[ext=mp4][vcodec^=avc][height<=1080]+bestaudio[ext=m4a]/bestvideo[ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=1080]+bestaudio/bv*+ba/best".to_string(),
        "--merge-output-format".to_string(),
        "mp4".to_string(),
        "--remux-video".to_string(),
        "mp4".to_string(),
    ];

    // 添加 ffmpeg 位置参数，确保合并能成功
    if let Some(ref loc) = ffmpeg_location {
        yt_dlp_args.push("--ffmpeg-location".to_string());
        yt_dlp_args.push(loc.clone());
    }

    yt_dlp_args.push("-o".to_string());
    yt_dlp_args.push(output_template_str.to_string());
    yt_dlp_args.push("--print-json".to_string());
    yt_dlp_args.push("--no-simulate".to_string());
    yt_dlp_args.push(url.clone());

    // 优先使用 sidecar，无法产出结果时回退到系统 yt-dlp
    let run = run_yt_dlp(&app, &yt_dlp_args).await?;

    let stdout_str = String::from_utf8_lossy(&run.stdout);
    let stderr_str = String::from_utf8_lossy(&run.stderr);

    log_yt(
        LogLevel::Info,
        format!(
            "yt-dlp finished: fallback={} success={} stdout={}B stderr={}",
            run.used_fallback,
            run.success,
            stdout_str.len(),
            truncate_for_log(&stderr_str, 1000)
        ),
    );

    // 如果没有 JSON 输出，说明视频下载完全失败
    let json_line = match extract_metadata_json(&stdout_str) {
        Some(line) => line.to_string(),
        None => {
            // 检查 stderr 中是否有更具体的错误信息
            if stderr_str.contains("Video unavailable") {
                return Err("视频不可用，可能是私有视频或已被删除".to_string());
            } else if stderr_str.contains("Sign in") {
                return Err("此视频需要登录才能观看".to_string());
            } else if stderr_str.contains("ffmpeg") || stderr_str.contains("FFmpeg") {
                // 如果已经找到 ffmpeg 但仍失败，给出更详细的错误
                if ffmpeg_location.is_none() {
                    return Err("需要安装 FFmpeg 才能下载此视频。请安装后重试。".to_string());
                } else {
                    return Err(format!(
                        "视频下载失败，FFmpeg 错误: {}",
                        truncate_for_log(&stderr_str, 2000)
                    ));
                }
            } else if !run.success {
                return Err(format!(
                    "视频下载失败: {}",
                    truncate_for_log(&stderr_str, 2000)
                ));
            } else {
                return Err("无法获取视频信息".to_string());
            }
        }
    };

    let metadata: YtDlpOutput =
        serde_json::from_str(&json_line).map_err(|e| format!("Failed to parse metadata: {}", e))?;

    let video_id = metadata.id;
    let video_title = metadata.title;

    // 查找实际下载的视频文件（可能是 .mp4, .webm 等）
    let video_path = find_video_file(&videos_dir, &video_id)?;

    // 验证视频格式是否能在 Mac/Win 平台播放
    verify_video_format(&video_path)?;

    // 2. 查找字幕文件（可选，失败不报错）
    // yt-dlp pattern: {id}.{lang}.srt
    let segments = match find_srt_file(&videos_dir, &video_id) {
        Ok(srt_path) => {
            // 字幕文件存在，解析它
            match parse_srt(&srt_path) {
                Ok(mut segs) => {
                    for segment in &mut segs {
                        segment.article_id = video_id.clone();
                    }
                    segs
                }
                Err(_) => {
                    // 字幕解析失败，返回空列表
                    Vec::new()
                }
            }
        }
        Err(_) => {
            // 没有找到字幕文件，返回空列表（后续可用 TTS 识别）
            Vec::new()
        }
    };

    // 3. 构建内容文本
    let content = if segments.is_empty() {
        // 没有字幕时，使用占位文本
        format!("[视频已导入，字幕待识别] {}", video_title)
    } else {
        segments
            .iter()
            .map(|s| s.text.clone())
            .collect::<Vec<_>>()
            .join(" ")
    };

    // 4. Create Article
    let article = Article {
        id: video_id.clone(),
        title: video_title,
        content,
        source_type: Some("youtube".to_string()),
        source_url: Some(url),
        media_path: Some(video_path.to_string_lossy().into_owned()),
        book_path: None,
        book_type: None,
        created_at: Utc::now().to_rfc3339(),
        translated: false,
        active_mind_map_artifact_id: None,
        segments,
    };

    Ok(article)
}

/// 验证视频格式是否能在 Mac/Win 平台播放
/// 检查文件是否为有效的 MP4 容器（而非 MPEG-TS 等不兼容格式）
fn verify_video_format(path: &Path) -> Result<(), String> {
    use std::io::Read;

    let mut file = fs::File::open(path).map_err(|e| format!("无法打开视频文件验证: {}", e))?;

    // 读取文件前 12 字节
    let mut header = [0u8; 12];
    file.read_exact(&mut header)
        .map_err(|e| format!("无法读取视频文件头: {}", e))?;

    // MP4 文件格式检查：
    // MP4 文件以 ftyp atom 开头，格式为：
    // [4字节大小][4字节 'ftyp'][4字节品牌标识]
    // 品牌标识常见值：isom, iso2, mp41, mp42, avc1, M4V, qt 等

    let ftyp_marker = &header[4..8];

    if ftyp_marker == b"ftyp" {
        // 有效的 MP4/M4V/MOV 容器
        let brand = String::from_utf8_lossy(&header[8..12]);
        log_yt(LogLevel::Info, format!("有效的 MP4 容器，品牌: {brand}"));
        return Ok(());
    }

    // 检查 WebM 格式 (EBML 头)
    if header[0..4] == [0x1A, 0x45, 0xDF, 0xA3] {
        log_yt(LogLevel::Info, "WebM 格式");
        return Ok(());
    }

    // 检查是否为 MPEG-TS（不兼容格式）
    // MPEG-TS 以 0x47 同步字节开头
    if header[0] == 0x47 {
        // 删除无效文件
        let _ = fs::remove_file(path);
        return Err(
            "视频格式不兼容：下载的是 MPEG-TS 格式，无法在 Mac/Win 播放。\n\
             请尝试重新导入，系统将自动选择兼容格式。"
                .to_string(),
        );
    }

    // 其他未知格式 - 给出警告但不阻止
    log_yt(
        LogLevel::Warn,
        format!("未知视频格式，可能无法播放: {:?}", &header[0..8]),
    );
    Ok(())
}

/// yt-dlp leaves each downloaded stream as `<id>.f<code>.<ext>` beside the
/// merged output, so a format code marks a leftover rather than the real file.
fn format_code_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\.f\d+\.").unwrap())
}

/// 查找实际下载的视频文件（排除字幕/缩略图，音频仅作为回退）
fn find_video_file(dir: &Path, video_id: &str) -> Result<PathBuf, String> {
    let video_extensions = ["mp4", "webm", "mkv", "mov", "avi"];
    let audio_extensions = ["m4a", "mp3", "opus"];
    let ignored_extensions = ["srt", "vtt", "json", "jpg", "jpeg", "png", "webp", "part"];

    let entries = fs::read_dir(dir).map_err(|e| e.to_string())?;

    let mut video_matches: Vec<(PathBuf, i32)> = Vec::new(); // (path, score)
    let mut audio_fallback: Vec<PathBuf> = Vec::new();

    for entry in entries {
        let entry = entry.map_err(|os_err| os_err.to_string())?;
        let path = entry.path();
        let Some(fname) = path.file_name().and_then(|f| f.to_str()) else {
            continue;
        };

        // 文件名必须以 video_id 开头
        if !fname.starts_with(video_id) {
            continue;
        }

        let lower = fname.to_ascii_lowercase();
        let ext = Path::new(&lower)
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("");

        // 字幕、缩略图、未完成的下载
        if ignored_extensions.contains(&ext) {
            continue;
        }

        // 音频只在没有视频时使用
        if audio_extensions.contains(&ext) {
            audio_fallback.push(path.clone());
            continue;
        }

        if !video_extensions.contains(&ext) {
            continue;
        }

        let mut score = 0;
        // 合并后的文件（无格式代码）优先于 abc.f137.mp4 这类分轨文件
        if !format_code_regex().is_match(&lower) {
            score += 100;
        }
        score += match ext {
            "mp4" => 50,
            "webm" => 20,
            "mkv" => 10,
            _ => 0,
        };

        video_matches.push((path.clone(), score));
    }

    // 按分数排序，分数高的优先
    video_matches.sort_by(|a, b| b.1.cmp(&a.1));

    if let Some((best_path, best_score)) = video_matches.into_iter().next() {
        log_yt(
            LogLevel::Info,
            format!("selected video file {best_path:?} (score {best_score})"),
        );
        return Ok(best_path);
    }

    // 只剩音频通常意味着合并没有发生（多半是缺少 ffmpeg）。仍然导入，
    // 但明确记录下来 —— 用户拿到的是一个没有画面的"视频"。
    audio_fallback.sort_by_key(|path| {
        std::cmp::Reverse(fs::metadata(path).map(|meta| meta.len()).unwrap_or(0))
    });
    if let Some(audio_path) = audio_fallback.into_iter().next() {
        log_yt(
            LogLevel::Warn,
            format!(
                "no video file for {video_id}, importing audio-only {audio_path:?} \
                 (the ffmpeg merge most likely failed)"
            ),
        );
        return Ok(audio_path);
    }

    Err(format!("未找到视频文件: {}", video_id))
}

fn find_srt_file(dir: &Path, video_id: &str) -> Result<PathBuf, String> {
    // Check for common patterns: id.en.srt, id.zh-Hans.srt, etc.
    let entries = fs::read_dir(dir).map_err(|e| e.to_string())?;

    let mut srt_files: Vec<PathBuf> = Vec::new();

    for entry in entries {
        let entry = entry.map_err(|os_err| os_err.to_string())?;
        let path = entry.path();
        if let Some(fname) = path.file_name().and_then(|f| f.to_str()) {
            if fname.starts_with(video_id) && fname.ends_with(".srt") {
                srt_files.push(path);
            }
        }
    }

    // 优先选择英语或中文字幕
    if srt_files.is_empty() {
        return Err("No subtitle file found".to_string());
    }

    // 简单优先级：en > zh-Hans > zh-Hant > 其他
    srt_files.sort_by(|a, b| {
        let a_name = a.file_name().unwrap_or_default().to_string_lossy().to_lowercase();
        let b_name = b.file_name().unwrap_or_default().to_string_lossy().to_lowercase();

        let score = |name: &str| {
            if name.contains(".en.") || name.ends_with(".en.srt") {
                0
            } else if name.contains("zh-hans") || name.contains("zh-cn") {
                1
            } else if name.contains("zh-hant") || name.contains("zh-tw") {
                2
            } else if name.contains("zh") {
                3
            } else {
                10
            }
        };

        score(&a_name).cmp(&score(&b_name))
    });

    Ok(srt_files[0].clone())
}

fn parse_srt(path: &Path) -> Result<Vec<ArticleSegment>, String> {
    let content = fs::read_to_string(path).map_err(|e| e.to_string())?;
    let mut segments = Vec::new();

    // Simple SRT parser
    // Block format:
    // 1
    // 00:00:00,000 --> 00:00:02,000
    // Text line 1
    // Text line 2

    let blocks: Vec<&str> = content.split("\n\n").collect();
    let time_regex =
        Regex::new(r"(\d{2}:\d{2}:\d{2},\d{3}) --> (\d{2}:\d{2}:\d{2},\d{3})").unwrap();

    for block in blocks {
        let lines: Vec<&str> = block.lines().collect();
        if lines.len() >= 3 {
            // Line 0: Index
            // Line 1: Timestamp
            // Line 2+: Text
            if let Some(caps) = time_regex.captures(lines[1]) {
                let start_str = &caps[1];
                let end_str = &caps[2];

                let start_time = parse_srt_timestamp(start_str);
                let end_time = parse_srt_timestamp(end_str);

                let text = lines[2..].join(" ");

                // Clean text (remove HTML tags if any)
                let text = text
                    .replace("<i>", "")
                    .replace("</i>", "")
                    .trim()
                    .to_string();

                if !text.is_empty() {
                    segments.push(ArticleSegment {
                        id: Uuid::new_v4().to_string(),
                        article_id: String::new(), // Will be set by caller
                        order: segments.len() as i32,
                        text,
                        reading_text: None,
                        translation: None,
                        explanation: None,
                        start_time,
                        end_time,
                        created_at: Utc::now().to_rfc3339(),
                        is_new_paragraph: true, // SRT blocks usually separate sentences/phrases
                    });
                }
            }
        }
    }

    Ok(segments)
}

fn parse_srt_timestamp(ts: &str) -> Option<f64> {
    // format: 00:00:00,000
    let parts: Vec<&str> = ts.split(',').collect();
    if parts.len() != 2 {
        return None;
    }

    let time_parts: Vec<&str> = parts[0].split(':').collect();
    if time_parts.len() != 3 {
        return None;
    }

    let h: f64 = time_parts[0].parse().ok()?;
    let m: f64 = time_parts[1].parse().ok()?;
    let s: f64 = time_parts[2].parse().ok()?;
    let ms: f64 = parts[1].parse().ok()?;

    Some(h * 3600.0 + m * 60.0 + s + ms / 1000.0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    fn temp_dir(label: &str) -> PathBuf {
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        let unique = COUNTER.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!(
            "openkoto-youtube-{label}-{}-{unique}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn touch(dir: &Path, name: &str, bytes: usize) {
        fs::write(dir.join(name), vec![0u8; bytes]).unwrap();
    }

    #[test]
    fn truncate_for_log_splits_on_char_boundaries() {
        // yt-dlp reports errors containing the video title, so a byte slice
        // would panic here.
        let text = "错误：视频不可用".repeat(200);
        let truncated = truncate_for_log(&text, 1000);
        assert_eq!(truncated.chars().count(), 1001); // 1000 + the ellipsis
        assert!(truncated.ends_with('…'));
    }

    #[test]
    fn truncate_for_log_leaves_short_text_alone() {
        assert_eq!(truncate_for_log("done", 1000), "done");
        assert_eq!(truncate_for_log("", 10), "");
    }

    #[test]
    fn is_semaphore_error_matches_the_pyinstaller_bootloader_failure() {
        let observed = "[PYI-64034:ERROR] Failed to initialize sync semaphore!\n\
                        semctl: Operation not permitted\n";
        assert!(is_semaphore_error(observed));
        assert!(!is_semaphore_error("ERROR: [youtube] Video unavailable"));
    }

    #[test]
    fn extract_metadata_json_takes_the_last_json_line() {
        let stdout = "[download] Destination: abc.mp4\n{\"id\":\"one\"}\n{\"id\":\"two\"}\n";
        assert_eq!(extract_metadata_json(stdout), Some("{\"id\":\"two\"}"));
        assert_eq!(extract_metadata_json("[download] 100%\n"), None);
    }

    #[test]
    fn find_video_file_prefers_the_merged_output() {
        let dir = temp_dir("merged");
        touch(&dir, "abc123.f137.mp4", 10);
        touch(&dir, "abc123.f140.m4a", 10);
        touch(&dir, "abc123.en.srt", 10);
        touch(&dir, "abc123.mp4", 10);

        let found = find_video_file(&dir, "abc123").unwrap();
        assert_eq!(found.file_name().unwrap(), "abc123.mp4");

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn find_video_file_ignores_subtitles_and_partials() {
        let dir = temp_dir("ignored");
        touch(&dir, "abc123.en.srt", 10);
        touch(&dir, "abc123.info.json", 10);
        touch(&dir, "abc123.webp", 10);
        touch(&dir, "abc123.mp4.part", 10);

        assert!(find_video_file(&dir, "abc123").is_err());

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn find_video_file_falls_back_to_the_largest_audio() {
        // What a failed merge leaves behind: audio streams and no video.
        let dir = temp_dir("audio");
        touch(&dir, "abc123.f139.m4a", 10);
        touch(&dir, "abc123.f140.m4a", 500);

        let found = find_video_file(&dir, "abc123").unwrap();
        assert_eq!(found.file_name().unwrap(), "abc123.f140.m4a");

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn system_yt_dlp_candidates_always_end_with_a_path_lookup() {
        let candidates = system_yt_dlp_candidates();
        assert_eq!(candidates.last(), Some(&binary_name("yt-dlp")));

        let mut seen = HashSet::new();
        assert!(
            candidates.iter().all(|c| seen.insert(c)),
            "candidates must be deduplicated: {candidates:?}"
        );
    }
}
