//! One worker owns HID subprocesses; UI never waits for a device timeout.
use eframe::egui;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    io::{BufRead, BufReader, Read, Write},
    path::PathBuf,
    process::{Child, ChildStdin, Command, Stdio},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

pub const BUILD: &str = match option_env!("FREEDIGI_REVISION") {
    Some(v) => v,
    None => "development",
};
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Device {
    pub path: String,
    pub name: String,
    pub accessible: bool,
}
#[derive(Clone, Default, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Input {
    pub buttons: Vec<usize>,
    pub left_x: f32,
    pub left_y: f32,
    pub right_x: f32,
    pub right_y: f32,
    pub left_trigger: f32,
    pub right_trigger: f32,
}
#[derive(Clone, Serialize)]
pub struct State {
    pub devices: Vec<Device>,
    pub path: String,
    pub dry_run: bool,
    pub monitoring: bool,
    pub monitor_wanted: bool,
    pub input: Input,
    pub data: Value,
    pub logs: VecDeque<String>,
    pub busy: String,
    pub error: String,
    pub notice: String,
    pub completed: u64,
    pub last_action: String,
    pub last_preview: bool,
}
impl Default for State {
    fn default() -> Self {
        Self {
            devices: vec![],
            path: String::new(),
            dry_run: true,
            monitoring: false,
            monitor_wanted: false,
            input: Input::default(),
            data: json!({}),
            logs: VecDeque::new(),
            busy: String::new(),
            error: String::new(),
            notice: String::new(),
            completed: 0,
            last_action: String::new(),
            last_preview: false,
        }
    }
}
impl State {
    fn log(&mut self, action: &str, message: &str) {
        let seconds = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        let message: String = message.chars().take(8000).collect();
        self.logs.push_back(format!(
            "{seconds} [{}] {action}: {message}",
            if self.dry_run { "dry run" } else { "live" }
        ));
        while self.logs.len() > 200 {
            self.logs.pop_front();
        }
    }
    pub fn report(&self) -> String {
        let mut copy = self.clone();
        for key in ["snapshot", "lighting", "turbo", "calibration"] {
            copy.data.as_object_mut().unwrap().remove(key);
        }
        format!(
            "FreeDigi {} · {}/{}\nGame compatibility is not established by this report.\nTimestamps are Unix UTC seconds.\n{}",
            BUILD,
            std::env::consts::OS,
            std::env::consts::ARCH,
            serde_json::to_string_pretty(&copy).unwrap()
        )
    }
}
#[derive(Debug)]
pub enum Action {
    Refresh,
    Select(String),
    DryRun(bool),
    Monitor(bool),
    Perform(String, Value),
    Shutdown,
}
impl Action {
    fn label(&self) -> &str {
        match self {
            Self::Refresh => "Discover controllers",
            Self::Select(_) => "Select controller",
            Self::DryRun(_) => "Change write mode",
            Self::Monitor(_) => "Input monitoring",
            Self::Perform(name, _) => name,
            Self::Shutdown => "Closing",
        }
    }
}
#[derive(Deserialize, Default)]
struct Reply {
    #[serde(default)]
    ok: bool,
    #[serde(default)]
    result: Value,
    #[serde(default)]
    error: String,
    #[serde(default)]
    events: Value,
}
type Shared = Arc<Mutex<State>>;
pub struct Backend {
    state: Shared,
    commands: mpsc::Sender<Action>,
    closing: Arc<AtomicBool>,
}
impl Backend {
    pub fn new(ctx: egui::Context) -> Self {
        let state = Arc::new(Mutex::new(State::default()));
        let closing = Arc::new(AtomicBool::new(false));
        let (commands, receiver) = mpsc::channel();
        let worker_state = state.clone();
        let worker_closing = closing.clone();
        thread::spawn(move || {
            Worker {
                state: worker_state,
                ctx,
                closing: worker_closing,
                monitor: None,
            }
            .run(receiver)
        });
        Self {
            state,
            commands,
            closing,
        }
    }
    pub fn state(&self) -> State {
        self.state.lock().unwrap().clone()
    }
    pub fn send(&self, action: Action) {
        let mut state = self.state.lock().unwrap();
        if !state.busy.is_empty() {
            return;
        }
        state.busy = action.label().into();
        state.error.clear();
        state.notice.clear();
        if self.commands.send(action).is_err() {
            state.busy.clear();
            state.error = "Controller worker stopped".into();
        }
    }
}
impl Drop for Backend {
    fn drop(&mut self) {
        self.closing.store(true, Ordering::Relaxed);
        let _ = self.commands.send(Action::Shutdown);
    }
}
fn supported() -> Result<(), String> {
    if cfg!(any(target_os = "linux", target_os = "macos")) {
        Ok(())
    } else {
        Err("Windows transport is groundwork only; use Linux or macOS.".into())
    }
}
pub fn helper_path() -> PathBuf {
    if let Some(path) = std::env::var_os("FREEDIGI_SERVICE")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
    {
        return path;
    }
    std::env::current_exe()
        .unwrap_or_default()
        .with_file_name(if cfg!(windows) {
            "freedigi-service.exe"
        } else {
            "freedigi-service"
        })
}
fn spawn(request: &Value) -> Result<(Child, ChildStdin), String> {
    supported()?;
    let helper = helper_path();
    let mut child = Command::new(&helper).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().map_err(|e| format!("Cannot start {}: {e}. Install the bundled controller service, or set FREEDIGI_SERVICE to its absolute path.", helper.display()))?;
    let mut stdin = child.stdin.take().unwrap();
    if let Err(e) = writeln!(stdin, "{request}") {
        let _ = child.kill();
        let _ = child.wait();
        return Err(e.to_string());
    }
    Ok((child, stdin))
}
fn invoke(request: &Value, closing: &AtomicBool) -> Result<Reply, String> {
    let (mut child, stdin) = spawn(request)?;
    drop(stdin);
    let stdout = child.stdout.take().unwrap();
    let reader = thread::spawn(move || {
        let mut bytes = Vec::new();
        stdout
            .take(2 * 1024 * 1024)
            .read_to_end(&mut bytes)
            .map(|_| bytes)
    });
    let start = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Ok(status),
            Err(e) => break Err(e.to_string()),
            _ if closing.load(Ordering::Relaxed) || start.elapsed() > Duration::from_secs(150) => break Err("Operation stopped or exceeded its deadline. Read the setting again; changes may be partial.".into()),
            _ => thread::sleep(Duration::from_millis(15)),
        }
    };
    if status.is_err() {
        let _ = child.kill();
        let _ = child.wait();
    }
    let bytes = reader
        .join()
        .map_err(|_| "Service reader stopped")?
        .map_err(|e| e.to_string())?;
    let status = status?;
    let reply: Reply = serde_json::from_slice(&bytes)
        .map_err(|e| format!("Invalid controller service response ({status}): {e}"))?;
    if !status.success() && reply.ok {
        return Err(format!("Controller service exited {status}"));
    }
    Ok(reply)
}
/// Only explicit parameters are forwarded; snapshots and mode are worker-owned.
fn request(state: &State, action: &str, params: &Value) -> Result<Value, String> {
    if state.path.is_empty() {
        return Err("Select a controller first".into());
    }
    let allowed: &[&str] = match action {
        "profileRead" | "turboRead" | "calibrationRead" | "lightingRead" | "firmwareRead" => &[],
        "profileApply" => &["mappings", "persist"],
        "turboApply" | "calibrationApply" => &["enabled"],
        "lightingApply" => &["color", "brightness", "off"],
        _ => return Err("Unknown controller operation".into()),
    };
    let mut request = json!({"action": action, "path": state.path, "dryRun": state.dry_run});
    for key in allowed {
        if let Some(value) = params.get(key) {
            request[*key] = value.clone();
        }
    }
    if let Some(key) = snapshot_key(action) {
        request[key] = state
            .data
            .get(key)
            .filter(|v| !v.is_null())
            .ok_or("Read this setting before applying changes")?
            .clone();
    }
    Ok(request)
}
fn snapshot_key(action: &str) -> Option<&'static str> {
    match action {
        "profileApply" => Some("snapshot"),
        "turboApply" => Some("turbo"),
        "calibrationApply" => Some("calibration"),
        "lightingApply" => Some("lighting"),
        _ => None,
    }
}
fn accept(state: &mut State, action: &str, result: Result<Reply, String>) {
    state.completed += 1;
    state.last_action = action.into();
    state.last_preview = false;
    let outcome = result.and_then(|reply| {
        if !reply.events.is_null() && reply.events != json!([]) {
            state.log(action, &reply.events.to_string());
        }
        if !reply.ok {
            return Err(reply.error);
        }
        state.last_preview = reply.result["preview"].as_bool().unwrap_or(false);
        if !state.last_preview {
            if let Some(values) = reply.result.as_object() {
                for (key, value) in values {
                    state.data[key] = value.clone();
                }
            }
        }
        Ok(reply.result)
    });
    match outcome {
        Ok(value) => {
            state.notice = if state.last_preview {
                value["message"]
                    .as_str()
                    .unwrap_or("Preview validated. No writes sent.")
                    .into()
            } else if action.ends_with("Read") {
                "Read completed.".into()
            } else {
                "Applied and verified by reading the controller back.".into()
            };
            let message = state.notice.clone();
            state.log(action, &message);
        }
        Err(error) => {
            // Never reuse a possibly stale snapshot after an uncertain operation/read.
            let key = snapshot_key(action).or(match action {
                "profileRead" => Some("snapshot"),
                "lightingRead" => Some("lighting"),
                "turboRead" => Some("turbo"),
                "calibrationRead" => Some("calibration"),
                _ => None,
            });
            if let Some(key) = key {
                state.data.as_object_mut().unwrap().remove(key);
            }
            state.log(action, &error);
            state.error = error;
        }
    }
}
struct Monitor {
    child: Child,
    stdin: Option<ChildStdin>,
    reader: Option<thread::JoinHandle<()>>,
}
impl Monitor {
    fn stop(&mut self) {
        self.stdin.take(); // EOF makes the service send stream-stop before closing HID.
        let start = Instant::now();
        loop {
            match self.child.try_wait() {
                Ok(Some(_)) => break,
                _ if start.elapsed() > Duration::from_secs(3) => {
                    let _ = self.child.kill();
                    let _ = self.child.wait();
                    break;
                }
                _ => thread::sleep(Duration::from_millis(15)),
            }
        }
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
    }
}
impl Drop for Monitor {
    fn drop(&mut self) {
        self.stop();
    }
}
struct Worker {
    state: Shared,
    ctx: egui::Context,
    closing: Arc<AtomicBool>,
    monitor: Option<Monitor>,
}
impl Worker {
    fn stop(&mut self) {
        self.monitor.take();
        let mut s = self.state.lock().unwrap();
        s.monitoring = false;
        s.input = Input::default();
    }
    fn start(&mut self) -> Result<(), String> {
        let path = self.state.lock().unwrap().path.clone();
        if path.is_empty() {
            return Err("Select a controller first".into());
        }
        let (mut child, stdin) = spawn(&json!({"action":"monitor", "path":path}))?;
        let stdout = child.stdout.take().unwrap();
        let state = self.state.clone();
        let ctx = self.ctx.clone();
        let reader = thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                let Ok(value) = serde_json::from_str::<Value>(&line) else {
                    continue;
                };
                let mut s = state.lock().unwrap();
                if value["event"] == "input" {
                    if let Ok(input) = serde_json::from_value(value["state"].clone()) {
                        s.input = input;
                    }
                } else if value["event"] == "monitor" {
                    s.monitoring = value["running"] == true;
                } else if value["ok"] == false {
                    s.error = value["error"]
                        .as_str()
                        .unwrap_or("Input stream failed")
                        .into();
                    let error = s.error.clone();
                    s.log("Monitor", &error);
                }
                drop(s);
                ctx.request_repaint();
            }
        });
        self.monitor = Some(Monitor {
            child,
            stdin: Some(stdin),
            reader: Some(reader),
        });
        Ok(())
    }
    fn run(&mut self, receiver: mpsc::Receiver<Action>) {
        self.state.lock().unwrap().log(
            "Session",
            "Started with dry run enabled. Hardware reads remain live.",
        );
        loop {
            if self.closing.load(Ordering::Relaxed) {
                break;
            }
            if let Some(monitor) = &mut self.monitor {
                if matches!(monitor.child.try_wait(), Ok(Some(_))) {
                    self.stop();
                    let mut s = self.state.lock().unwrap();
                    s.monitor_wanted = false;
                    if s.error.is_empty() {
                        s.error =
                            "Input stream ended. Check the controller and start monitoring again."
                                .into();
                    }
                    self.ctx.request_repaint();
                }
            }
            let action = match receiver.recv_timeout(Duration::from_millis(200)) {
                Ok(a) => a,
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(_) => break,
            };
            if matches!(action, Action::Shutdown) {
                break;
            }
            let result = self.execute(action);
            let mut s = self.state.lock().unwrap();
            if let Err(error) = result {
                let action = s.busy.clone();
                s.log(&action, &error);
                s.error = error;
            }
            s.busy.clear();
            drop(s);
            self.ctx.request_repaint();
        }
        self.stop();
    }
    fn execute(&mut self, action: Action) -> Result<(), String> {
        match action {
            Action::Refresh => {
                let reply = invoke(&json!({"action":"devices"}), &self.closing)?;
                if !reply.ok {
                    return Err(reply.error);
                }
                let devices: Vec<Device> = serde_json::from_value(reply.result["devices"].clone())
                    .map_err(|e| e.to_string())?;
                let path = self.state.lock().unwrap().path.clone();
                if !devices.iter().any(|d| d.path == path) {
                    self.stop();
                    let mut s = self.state.lock().unwrap();
                    s.path = devices.first().map(|d| d.path.clone()).unwrap_or_default();
                    s.data = json!({});
                    s.monitor_wanted = false;
                }
                let mut s = self.state.lock().unwrap();
                s.log(
                    "Discovery",
                    &format!("{} configuration interface(s)", devices.len()),
                );
                s.devices = devices;
            }
            Action::Select(path) => {
                if !self
                    .state
                    .lock()
                    .unwrap()
                    .devices
                    .iter()
                    .any(|d| d.path == path)
                {
                    return Err("Device is no longer available; refresh the list.".into());
                }
                self.stop();
                let mut s = self.state.lock().unwrap();
                s.path = path;
                s.data = json!({});
                s.monitor_wanted = false;
            }
            Action::DryRun(enabled) => {
                let mut s = self.state.lock().unwrap();
                s.dry_run = enabled;
                s.log(
                    "Write mode",
                    if enabled {
                        "Dry run enabled"
                    } else {
                        "Live writes enabled"
                    },
                );
            }
            Action::Monitor(enabled) => {
                self.stop();
                self.state.lock().unwrap().monitor_wanted = enabled;
                if enabled {
                    if let Err(e) = self.start() {
                        self.state.lock().unwrap().monitor_wanted = false;
                        return Err(e);
                    }
                }
                self.state.lock().unwrap().log(
                    "Monitor",
                    if enabled {
                        "Starting input stream"
                    } else {
                        "Stopped input stream"
                    },
                );
            }
            Action::Perform(action, params) => {
                let request = request(&self.state.lock().unwrap(), &action, &params)?;
                let resume = self.state.lock().unwrap().monitor_wanted;
                self.stop();
                self.ctx.request_repaint();
                self.state.lock().unwrap().log(&action, "Started");
                let reply = invoke(&request, &self.closing);
                accept(&mut self.state.lock().unwrap(), &action, reply);
                if resume && !self.closing.load(Ordering::Relaxed) {
                    if let Err(e) = self.start() {
                        let mut s = self.state.lock().unwrap();
                        s.monitor_wanted = false;
                        s.log("Monitor resume", &e);
                        s.error = e;
                    }
                }
            }
            Action::Shutdown => {}
        }
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ui_cannot_override_path_snapshot_or_dry_run() {
        let state = State {
            path: "/dev/test".into(),
            data: json!({"snapshot":{"identity":"trusted"}}),
            ..Default::default()
        };
        let req = request(&state, "profileApply", &json!({"path":"evil","dryRun":false,"snapshot":"evil","mappings":{"18":4},"persist":true})).unwrap();
        assert_eq!(req["path"], "/dev/test");
        assert_eq!(req["dryRun"], true);
        assert_eq!(req["snapshot"]["identity"], "trusted");
        assert_eq!(req["mappings"]["18"], 4);
        assert!(request(&state, "flash", &json!({})).is_err());
    }
    #[test]
    fn failed_writes_require_fresh_read_and_previews_preserve_snapshot() {
        let mut state = State {
            path: "test".into(),
            data: json!({"snapshot":{"v":1}}),
            ..Default::default()
        };
        accept(
            &mut state,
            "profileApply",
            Ok(Reply {
                ok: true,
                result: json!({"preview":true,"snapshot":{"v":2}}),
                ..Default::default()
            }),
        );
        assert_eq!(state.data["snapshot"]["v"], 1);
        assert!(state.last_preview);
        accept(&mut state, "profileApply", Err("timed out".into()));
        assert!(request(&state, "profileApply", &json!({})).is_err());
        assert!(state.data.get("snapshot").is_none());
    }
    #[test]
    fn logs_are_bounded_and_report_omits_raw_profile() {
        let mut state = State {
            data: json!({"snapshot":"private-profile-bytes","lighting":"raw"}),
            ..Default::default()
        };
        for _ in 0..250 {
            state.log("Read", "OK");
        }
        assert_eq!(state.logs.len(), 200);
        assert!(!state.report().contains("private-profile-bytes"));
    }
}
