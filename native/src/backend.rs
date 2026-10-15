//! One worker owns HID subprocesses; UI never waits for a device timeout.
use eframe::egui;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, VecDeque},
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
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
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
    pub logs: Arc<VecDeque<String>>,
    pub setting_errors: BTreeMap<String, String>,
    pub error_action: String,
    pub visible_reads: Vec<String>,
    pub live_view: bool,
    pub focused: bool,
    /// A user-requested operation (write or Refresh). Editors lock only for this.
    pub busy: String,
    /// Scheduled background reads. Never locks editors; queued writes run after it.
    pub syncing: bool,
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
            logs: Arc::new(VecDeque::new()),
            setting_errors: BTreeMap::new(),
            error_action: String::new(),
            visible_reads: vec![],
            live_view: true,
            focused: true,
            busy: String::new(),
            syncing: false,
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
        Arc::make_mut(&mut self.logs).push_back(format!(
            "{seconds} [{}] {action}: {message}",
            if self.dry_run { "dry run" } else { "live" }
        ));
        while self.logs.len() > 200 {
            Arc::make_mut(&mut self.logs).pop_front();
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
    Perform(String, Value),
    Shutdown,
}
impl Action {
    fn label(&self) -> &str {
        match self {
            Self::Refresh => "Discover controllers",
            Self::Select(_) => "Select controller",
            Self::DryRun(_) => "Change write mode",
            Self::Perform(name, _) => human(name),
            Self::Shutdown => "Closing",
        }
    }
}
/// User-facing names for service actions; wire names never reach the UI.
pub fn human(action: &str) -> &str {
    match action {
        "profileApply" => "Saving mapping",
        "lightingApply" => "Applying lighting",
        "turboApply" => "Updating Turbo button",
        "calibrationApply" => "Updating automatic calibration",
        "profileRead" => "Reading profile",
        "lightingRead" => "Reading lighting",
        "turboRead" => "Reading Turbo button",
        "calibrationRead" => "Reading calibration",
        "firmwareRead" => "Reading firmware versions",
        other => other,
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
                schedule: Schedule::new(Instant::now()),
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
    /// Screens declare what they show. Only the worker owns reads and HID access.
    pub fn watch(&self, reads: &[&str], live_view: bool, focused: bool) {
        let mut s = self.state.lock().unwrap();
        s.visible_reads = reads.iter().map(|v| (*v).to_owned()).collect();
        s.live_view = live_view;
        s.focused = focused;
    }
    pub fn send(&self, action: Action) {
        let mut state = self.state.lock().unwrap();
        if !state.busy.is_empty() {
            return;
        }
        state.busy = action.label().into();
        state.error.clear();
        state.error_action.clear();
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
            _ if closing.load(Ordering::Relaxed) || start.elapsed() > Duration::from_secs(150) => break Err("Operation stopped or exceeded its deadline. Settings will refresh automatically; changes may be partial.".into()),
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
            .ok_or("Wait for this setting to sync before applying changes")?
            .clone();
    }
    Ok(request)
}
/// Every setting read. All are prefetched once per controller so pages open
/// with data; afterwards only visible pages are revalidated.
const ALL_READS: [&str; 5] = [
    "profileRead",
    "lightingRead",
    "turboRead",
    "calibrationRead",
    "firmwareRead",
];
fn read_key(action: &str) -> Option<&'static str> {
    match action {
        "profileRead" => Some("snapshot"),
        "lightingRead" => Some("lighting"),
        "turboRead" => Some("turbo"),
        "calibrationRead" => Some("calibration"),
        "firmwareRead" => Some("versions"),
        _ => None,
    }
}
impl State {
    /// True while a visible page has nothing cached to show yet.
    pub fn awaiting_first_read(&self) -> bool {
        self.visible_reads
            .iter()
            .filter_map(|a| read_key(a))
            .any(|key| self.data.get(key).is_none())
    }
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
    let reading = action.ends_with("Read");
    if !reading {
        state.completed += 1;
        state.last_action = action.into();
    }
    let mut preview = false;
    let mut changed = false;
    let outcome = result.and_then(|reply| {
        if !reply.events.is_null() && reply.events != json!([]) {
            state.log(action, &reply.events.to_string());
        }
        if !reply.ok {
            return Err(reply.error);
        }
        preview = reply.result["preview"].as_bool().unwrap_or(false);
        if !reading {
            state.last_preview = preview;
        }
        if !preview && let Some(values) = reply.result.as_object() {
            // Background revalidation leaves the view untouched unless the
            // controller reports something different.
            for (key, value) in values {
                if state.data.get(key) != Some(value) {
                    state.data[key] = value.clone();
                    changed = true;
                }
            }
        }
        Ok(reply.result)
    });
    match outcome {
        Ok(value) => {
            state.setting_errors.remove(action);
            if reading {
                if changed {
                    state.log(action, "Updated from the controller");
                }
                return;
            }
            state.error.clear();
            state.error_action.clear();
            state.notice = if preview {
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
            let key = snapshot_key(action)
                .or_else(|| read_key(action).filter(|_| action != "firmwareRead"));
            if let Some(key) = key {
                state.data.as_object_mut().unwrap().remove(key);
            }
            state.log(action, &error);
            if reading {
                state.setting_errors.insert(action.into(), error);
            } else {
                state.error = error;
                state.error_action = action.into();
            }
        }
    }
}
struct Monitor {
    child: Child,
    /// Set once the helper finished its identity handshake and enabled the stream.
    started: Arc<AtomicBool>,
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
    schedule: Schedule,
}
impl Worker {
    fn stop(&mut self) {
        self.monitor.take();
        let mut s = self.state.lock().unwrap();
        s.monitoring = false;
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
        let started = Arc::new(AtomicBool::new(false));
        let started_flag = started.clone();
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
                    if s.monitoring {
                        started_flag.store(true, Ordering::Relaxed);
                    }
                    if s.monitoring && s.error_action == "monitor" {
                        s.error.clear();
                        s.error_action.clear();
                    }
                } else if value["ok"] == false {
                    s.error = value["error"]
                        .as_str()
                        .unwrap_or("Input stream failed")
                        .into();
                    s.error_action = "monitor".into();
                    let error = s.error.clone();
                    s.log("Monitor", &error);
                    // Handshake attempts, elapsed time and unmatched headers; no profile data.
                    if value["events"].as_array().is_some_and(|e| !e.is_empty()) {
                        s.log("Monitor diagnostics", &value["events"].to_string());
                    }
                }
                let repaint = value["event"] != "input" || (s.live_view && s.focused);
                drop(s);
                if repaint {
                    ctx.request_repaint();
                }
            }
        });
        self.monitor = Some(Monitor {
            child,
            started,
            stdin: Some(stdin),
            reader: Some(reader),
        });
        Ok(())
    }
    fn run(&mut self, receiver: mpsc::Receiver<Action>) {
        self.state.lock().unwrap().log(
            "Session",
            "Automatic discovery and sync enabled. Dry run starts on; reads remain live.",
        );
        loop {
            if self.closing.load(Ordering::Relaxed) {
                break;
            }
            if let Some(started) = self.monitor.as_mut().and_then(|m| {
                matches!(m.child.try_wait(), Ok(Some(_))).then(|| m.started.load(Ordering::Relaxed))
            }) {
                self.monitor_exited(started, Instant::now());
            }
            match receiver.recv_timeout(Duration::from_millis(100)) {
                Ok(Action::Shutdown) | Err(mpsc::RecvTimeoutError::Disconnected) => break,
                Ok(action) => {
                    let label = action.label().to_owned();
                    if let Err(error) = self.execute(action) {
                        let mut s = self.state.lock().unwrap();
                        s.log(&label, &error);
                        s.error = error;
                        s.error_action.clear();
                    }
                    self.state.lock().unwrap().busy.clear();
                    self.ctx.request_repaint();
                }
                Err(mpsc::RecvTimeoutError::Timeout) => self.automatic(),
            }
        }
        self.stop();
    }
    fn monitor_exited(&mut self, started: bool, now: Instant) {
        self.stop();
        self.schedule.monitor_failed(now);
        let mut s = self.state.lock().unwrap();
        s.input = Input::default();
        if started {
            // A running stream ended: the device may be gone, so cached
            // settings are no longer trustworthy.
            self.schedule.reset_reads();
            self.schedule.discovery = now;
            s.data = json!({});
            s.log(
                "Monitor",
                "Stream ended; checking connection and scheduling reconnect.",
            );
        } else {
            // The helper exited before the stream started (identity handshake
            // failed). The controller was not shown to be removed; keep cached
            // settings so a slow handshake does not trigger a read/start loop.
            let wait = self
                .schedule
                .monitor
                .saturating_duration_since(now)
                .as_secs();
            s.log(
                "Monitor",
                &format!("Input stream did not start; retrying in {wait}s."),
            );
        }
        self.ctx.request_repaint();
    }
    fn discover(&mut self) -> Result<(), String> {
        let reply = invoke(&json!({"action":"devices"}), &self.closing)?;
        if !reply.ok {
            return Err(reply.error);
        }
        let devices: Vec<Device> =
            serde_json::from_value(reply.result["devices"].clone()).map_err(|e| e.to_string())?;
        let selected = self.state.lock().unwrap().path.clone();
        let next = choose_device(&devices, &selected);
        if next != selected {
            self.stop();
            self.schedule.reset_reads();
            self.schedule.monitor_failures = 0;
            self.schedule.monitor = Instant::now();
            let mut s = self.state.lock().unwrap();
            s.path = next;
            s.data = json!({});
            s.setting_errors.clear();
            s.error.clear();
            s.error_action.clear();
            s.notice.clear();
            s.input = Input::default();
            s.monitor_wanted = !s.path.is_empty();
        }
        let mut s = self.state.lock().unwrap();
        if s.error_action == "discovery" {
            s.error.clear();
            s.error_action.clear();
        }
        if s.devices != devices {
            s.log(
                "Discovery",
                &format!("{} configuration interface(s)", devices.len()),
            );
        }
        s.devices = devices;
        self.schedule.discovery =
            Instant::now() + Duration::from_secs(if s.path.is_empty() { 1 } else { 5 });
        Ok(())
    }
    fn automatic(&mut self) {
        if !self.state.lock().unwrap().busy.is_empty() {
            return;
        }
        let now = Instant::now();
        if now >= self.schedule.discovery {
            if let Err(e) = self.discover() {
                self.schedule.discovery = now + Duration::from_secs(10);
                let mut s = self.state.lock().unwrap();
                if s.error != e {
                    s.log("Discovery", &e);
                    s.error = e;
                    s.error_action = "discovery".into();
                }
            }
            self.ctx.request_repaint();
        }
        let state = self.state.lock().unwrap().clone();
        if state.path.is_empty() {
            return;
        }
        if !state.focused {
            if self.monitor.is_some() {
                self.stop();
            }
            return;
        }
        if state.monitoring {
            self.schedule.monitor_failures = 0;
        }
        self.schedule.navigated(&state.visible_reads, now);
        let mut reads = self.schedule.due(&state.visible_reads, now);
        for action in self.schedule.prefetch() {
            if !reads.contains(&action) {
                reads.push(action);
            }
        }
        if !reads.is_empty() {
            // Reserve the same operation slot as explicit writes. No two helpers
            // ever own the controller interface at once.
            {
                let mut s = self.state.lock().unwrap();
                if !s.busy.is_empty() {
                    return;
                }
                s.syncing = true;
            }
            self.stop();
            self.ctx.request_repaint();
            for action in reads {
                if self.closing.load(Ordering::Relaxed) {
                    break;
                }
                // Navigation may have changed during a slower device read.
                // Prefetches (never read yet) still run.
                if self.schedule.reads.contains_key(&action)
                    && !self.state.lock().unwrap().visible_reads.contains(&action)
                {
                    continue;
                }
                self.read(&action);
            }
            self.state.lock().unwrap().syncing = false;
            self.ctx.request_repaint();
        }
        if self.monitor.is_none()
            && now >= self.schedule.monitor
            && state.monitor_wanted
            && let Err(e) = self.start()
        {
            self.schedule.monitor_failed(Instant::now());
            let mut s = self.state.lock().unwrap();
            s.log("Monitor reconnect", &e);
            s.error = e;
            s.error_action = "monitor".into();
        }
    }
    fn read(&mut self, action: &str) {
        let request = request(&self.state.lock().unwrap(), action, &json!({}));
        let reply = request.and_then(|r| invoke(&r, &self.closing));
        let success = reply.as_ref().is_ok_and(|r| r.ok);
        accept(&mut self.state.lock().unwrap(), action, reply);
        self.schedule.read_finished(action, success, Instant::now());
        self.ctx.request_repaint();
    }
    fn execute(&mut self, action: Action) -> Result<(), String> {
        match action {
            Action::Refresh => {
                self.discover()?;
                self.schedule.reset_reads();
                self.schedule.monitor = Instant::now();
            }
            Action::Select(path) => {
                if !self
                    .state
                    .lock()
                    .unwrap()
                    .devices
                    .iter()
                    .any(|d| d.path == path && d.accessible)
                {
                    return Err("Controller unavailable or permission is needed.".into());
                }
                self.stop();
                self.schedule.reset_reads();
                self.schedule.monitor = Instant::now();
                let mut s = self.state.lock().unwrap();
                s.path = path;
                s.data = json!({});
                s.setting_errors.clear();
                s.input = Input::default();
                s.monitor_wanted = true;
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
            Action::Perform(action, params) => {
                let request = request(&self.state.lock().unwrap(), &action, &params)?;
                self.stop();
                self.ctx.request_repaint();
                self.state.lock().unwrap().log(&action, "Started");
                let reply = invoke(&request, &self.closing);
                let success = reply.as_ref().is_ok_and(|r| r.ok);
                let preview = reply.as_ref().is_ok_and(|r| r.result["preview"] == true);
                accept(&mut self.state.lock().unwrap(), &action, reply);
                if let Some(read) = read_for_write(&action) {
                    // Successful live operations already return verified state. Preview
                    // keeps the snapshot; failures trigger a read, never another write.
                    if success || preview {
                        self.schedule.read_finished(read, true, Instant::now());
                    } else {
                        self.schedule.reads.remove(read);
                    }
                }
                self.schedule.monitor = Instant::now();
            }
            Action::Shutdown => {}
        }
        Ok(())
    }
}
fn choose_device(devices: &[Device], selected: &str) -> String {
    devices
        .iter()
        .find(|d| d.path == selected && d.accessible)
        .or_else(|| devices.iter().find(|d| d.accessible))
        .map(|d| d.path.clone())
        .unwrap_or_default()
}
fn read_for_write(action: &str) -> Option<&'static str> {
    match action {
        "profileApply" => Some("profileRead"),
        "lightingApply" => Some("lightingRead"),
        "turboApply" => Some("turboRead"),
        "calibrationApply" => Some("calibrationRead"),
        _ => None,
    }
}
/// Read freshness/backoff is centralized and deterministic; views never poll HID.
struct Schedule {
    discovery: Instant,
    monitor: Instant,
    monitor_failures: u32,
    reads: BTreeMap<String, (Instant, u32)>,
    /// Last successful read, so opening a page revalidates at most every few seconds.
    fresh: BTreeMap<String, Instant>,
    visible: Vec<String>,
}
/// Opening a page re-reads its settings unless they were read this recently.
const REVALIDATE_ON_OPEN: Duration = Duration::from_secs(3);
impl Schedule {
    fn new(now: Instant) -> Self {
        Self {
            discovery: now,
            monitor: now,
            monitor_failures: 0,
            reads: BTreeMap::new(),
            fresh: BTreeMap::new(),
            visible: vec![],
        }
    }
    fn reset_reads(&mut self) {
        self.reads.clear();
        self.fresh.clear();
    }
    /// Settings that became visible are due now, unless just read or backing off.
    fn navigated(&mut self, visible: &[String], now: Instant) {
        for action in visible.iter().filter(|a| !self.visible.contains(a)) {
            let failing = self.reads.get(action).is_some_and(|(_, f)| *f > 0);
            let recent = self
                .fresh
                .get(action)
                .is_some_and(|at| now.saturating_duration_since(*at) < REVALIDATE_ON_OPEN);
            if !failing
                && !recent
                && let Some((due, _)) = self.reads.get_mut(action)
            {
                *due = now;
            }
        }
        self.visible = visible.to_vec();
    }
    /// Settings never read for this controller.
    fn prefetch(&self) -> Vec<String> {
        ALL_READS
            .iter()
            .filter(|a| !self.reads.contains_key(**a))
            .map(|a| (*a).to_owned())
            .collect()
    }
    fn due(&self, visible: &[String], now: Instant) -> Vec<String> {
        visible
            .iter()
            .filter(|a| !self.reads.get(*a).is_some_and(|(at, _)| now < *at))
            .cloned()
            .collect()
    }
    fn read_finished(&mut self, action: &str, success: bool, now: Instant) {
        let failures = if success {
            0
        } else {
            self.reads
                .get(action)
                .map(|(_, f)| f.saturating_add(1))
                .unwrap_or(1)
        };
        let seconds = if success {
            if action == "firmwareRead" { 600 } else { 30 }
        } else {
            (5_u64 * 2_u64.pow(failures.min(4) - 1)).min(60)
        };
        self.reads.insert(
            action.into(),
            (now + Duration::from_secs(seconds), failures),
        );
        if success {
            self.fresh.insert(action.into(), now);
        }
    }
    fn monitor_failed(&mut self, now: Instant) {
        self.monitor_failures = (self.monitor_failures + 1).min(5);
        self.monitor = now + Duration::from_secs((1_u64 << (self.monitor_failures - 1)).min(15));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn refreshes_only_visible_settings_and_backs_off_failures() {
        let now = Instant::now();
        let mut schedule = Schedule::new(now);
        let lighting = vec!["lightingRead".into()];
        assert_eq!(schedule.due(&lighting, now), lighting);
        schedule.read_finished("lightingRead", true, now);
        assert!(
            schedule
                .due(&lighting, now + Duration::from_secs(29))
                .is_empty()
        );
        assert_eq!(
            schedule.due(&lighting, now + Duration::from_secs(30)),
            lighting
        );
        assert!(schedule.due(&[], now + Duration::from_secs(60)).is_empty());
        schedule.read_finished("lightingRead", false, now);
        assert!(
            schedule
                .due(&lighting, now + Duration::from_secs(4))
                .is_empty()
        );
        assert_eq!(
            schedule.due(&lighting, now + Duration::from_secs(5)),
            lighting
        );
        schedule.read_finished("lightingRead", false, now);
        assert!(
            schedule
                .due(&lighting, now + Duration::from_secs(9))
                .is_empty()
        );
        schedule.reset_reads();
        assert_eq!(schedule.due(&lighting, now), lighting);
    }
    #[test]
    fn prefetches_all_settings_once_and_revalidates_opened_pages() {
        let now = Instant::now();
        let mut schedule = Schedule::new(now);
        assert_eq!(schedule.prefetch().len(), ALL_READS.len());
        for action in ALL_READS {
            schedule.read_finished(action, true, now);
        }
        assert!(schedule.prefetch().is_empty());
        let lighting = vec!["lightingRead".to_string()];
        // Opening right after a read reuses it; opening later re-reads once.
        schedule.navigated(&lighting, now + Duration::from_secs(1));
        assert!(
            schedule
                .due(&lighting, now + Duration::from_secs(1))
                .is_empty()
        );
        schedule.navigated(&[], now + Duration::from_secs(5));
        schedule.navigated(&lighting, now + Duration::from_secs(5));
        assert_eq!(
            schedule.due(&lighting, now + Duration::from_secs(5)),
            lighting
        );
        // Staying on the page does not repeat it.
        schedule.read_finished("lightingRead", true, now + Duration::from_secs(5));
        schedule.navigated(&lighting, now + Duration::from_secs(10));
        assert!(
            schedule
                .due(&lighting, now + Duration::from_secs(10))
                .is_empty()
        );
    }
    #[test]
    fn unchanged_reads_leave_cached_data_and_log_untouched() {
        let mut state = State::default();
        let reply = || {
            Ok(Reply {
                ok: true,
                result: json!({"turbo": {"enabled": true}}),
                ..Reply::default()
            })
        };
        accept(&mut state, "turboRead", reply());
        let logs = state.logs.len();
        accept(&mut state, "turboRead", reply());
        assert_eq!(state.logs.len(), logs);
        assert_eq!(state.data["turbo"], json!({"enabled": true}));
        state.visible_reads = vec!["turboRead".into(), "calibrationRead".into()];
        assert!(state.awaiting_first_read());
        state.data["calibration"] = json!({});
        assert!(!state.awaiting_first_read());
    }
    #[test]
    fn discovery_preserves_selection_and_skips_inaccessible_devices() {
        let device = |path: &str, accessible| Device {
            path: path.into(),
            name: path.into(),
            accessible,
        };
        let devices = vec![
            device("blocked", false),
            device("first", true),
            device("second", true),
        ];
        assert_eq!(choose_device(&devices, "second"), "second");
        assert_eq!(choose_device(&devices, "gone"), "first");
        assert!(choose_device(&devices[..1], "blocked").is_empty());
    }
    #[test]
    fn background_reads_keep_write_completion_and_errors_scoped() {
        let mut state = State::default();
        accept(&mut state, "profileApply", Err("write failed".into()));
        accept(&mut state, "lightingRead", Err("lighting timeout".into()));
        assert_eq!(state.error, "write failed");
        assert_eq!(state.error_action, "profileApply");
        assert_eq!(state.setting_errors["lightingRead"], "lighting timeout");
        accept(
            &mut state,
            "lightingRead",
            Ok(Reply {
                ok: true,
                result: json!({"lighting":{"v":1}}),
                ..Default::default()
            }),
        );
        assert!(state.setting_errors.is_empty());
        assert_eq!(state.completed, 1);
        assert_eq!(state.last_action, "profileApply");
        assert_eq!(state.error, "write failed");
    }
    #[test]
    fn failed_handshake_keeps_settings_but_ended_stream_resyncs() {
        let now = Instant::now();
        let mut worker = Worker {
            state: Arc::new(Mutex::new(State::default())),
            ctx: egui::Context::default(),
            closing: Arc::new(AtomicBool::new(false)),
            monitor: None,
            schedule: Schedule::new(now),
        };
        let lighting = vec!["lightingRead".to_string()];
        worker.state.lock().unwrap().data = json!({"lighting": {}});
        worker.schedule.read_finished("lightingRead", true, now);

        worker.monitor_exited(false, now);
        assert_eq!(worker.state.lock().unwrap().data, json!({"lighting": {}}));
        assert!(worker.schedule.due(&lighting, now).is_empty());
        assert_eq!(worker.schedule.monitor, now + Duration::from_secs(1));
        worker.monitor_exited(false, now);
        assert_eq!(worker.schedule.monitor, now + Duration::from_secs(2));

        worker.monitor_exited(true, now);
        assert_eq!(worker.state.lock().unwrap().data, json!({}));
        assert_eq!(worker.schedule.due(&lighting, now), lighting);
        assert_eq!(worker.schedule.discovery, now);
    }
    #[test]
    fn snapshots_share_log_storage_until_a_new_event() {
        let mut state = State::default();
        state.log("Session", "start");
        let copy = state.clone();
        assert!(Arc::ptr_eq(&state.logs, &copy.logs));
        state.log("Sync", "complete");
        assert_eq!(copy.logs.len(), 1);
        assert_eq!(state.logs.len(), 2);
    }
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
