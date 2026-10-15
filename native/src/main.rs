mod backend;
mod controller_view;
mod pages;
mod shell;
mod ui;
use backend::{Action, Backend, State};
use eframe::egui::{self, Color32};
use serde_json::{Value, json};
use std::{collections::BTreeMap, time::Instant};
use ui::{Scheme, Tokens, Tone};

/// eframe otherwise installs its own "e" icon at runtime. On macOS an empty icon
/// keeps the bundle's freedigi.icns; elsewhere the window gets a small copy.
fn app_icon() -> egui::IconData {
    if cfg!(target_os = "macos") {
        return egui::IconData::default();
    }
    eframe::icon_data::from_png_bytes(include_bytes!("../assets/freedigi-256.png"))
        .unwrap_or_default()
}

#[cfg(target_os = "macos")]
const RENDERER: eframe::Renderer = eframe::Renderer::Wgpu;
#[cfg(not(target_os = "macos"))]
const RENDERER: eframe::Renderer = eframe::Renderer::Glow;

const BUTTONS: [&str; 22] = [
    "D-pad up",
    "D-pad right",
    "D-pad down",
    "D-pad left",
    "A",
    "B",
    "View",
    "X",
    "Y",
    "Menu",
    "LB",
    "RB",
    "LT",
    "RT",
    "L3",
    "R3",
    "C",
    "Z",
    "M1",
    "M2",
    "M3",
    "M4",
];
#[derive(Clone, Copy, PartialEq)]
enum Page {
    Live,
    Mapping,
    Lighting,
    Features,
    Firmware,
    Diagnostics,
    About,
}
impl Page {
    fn title(self) -> &'static str {
        match self {
            Page::Live => "Live input",
            Page::Mapping => "Mapping",
            Page::Lighting => "Lighting",
            Page::Features => "Features",
            Page::Firmware => "Firmware",
            Page::Diagnostics => "Diagnostics",
            Page::About => "About",
        }
    }
    fn icon(self) -> &'static str {
        match self {
            Page::Live => "🎮",
            Page::Mapping => "🔀",
            Page::Lighting => "💡",
            Page::Features => "⚙",
            Page::Firmware => "📦",
            Page::Diagnostics => "📋",
            Page::About => "ℹ",
        }
    }
    /// Settings this page displays; the worker keeps exactly these fresh.
    fn reads(self) -> &'static [&'static str] {
        match self {
            Page::Mapping => &["profileRead"],
            Page::Lighting => &["lightingRead"],
            Page::Features => &["turboRead", "calibrationRead"],
            Page::Firmware => &["firmwareRead"],
            _ => &[],
        }
    }
    /// Which page owns an operation's errors and notices.
    fn of_action(action: &str) -> Option<Page> {
        match action {
            "profileRead" | "profileApply" => Some(Page::Mapping),
            "lightingRead" | "lightingApply" => Some(Page::Lighting),
            "turboRead" | "turboApply" | "calibrationRead" | "calibrationApply" => {
                Some(Page::Features)
            }
            "firmwareRead" => Some(Page::Firmware),
            "monitor" => Some(Page::Live),
            _ => None,
        }
    }
}
const NAV: [(&str, &[Page]); 2] = [
    (
        "Controller",
        &[Page::Live, Page::Mapping, Page::Lighting, Page::Features],
    ),
    ("System", &[Page::Firmware, Page::Diagnostics]),
];

struct Toast {
    tone: Tone,
    text: String,
    at: Instant,
}

struct App {
    backend: Backend,
    /// Window width in points, for responsive layout decisions.
    width: f32,
    tokens: Tokens,
    page: Page,
    staged: BTreeMap<String, usize>,
    color: [u8; 3],
    brightness: u8,
    off: bool,
    last_completed: u64,
    last_path: String,
    draft_context: Value,
    selected_button: Option<usize>,
    inspected: Option<usize>,
    show_mappings: bool,
    lighting_dirty: bool,
    lighting_snapshot: Value,
    toasts: Vec<Toast>,
}
impl App {
    fn new(cc: &eframe::CreationContext<'_>) -> Self {
        ui::theme::install_fonts(&cc.egui_ctx);
        let tokens = Tokens::new(Scheme::Dark, false);
        tokens.install(&cc.egui_ctx);
        let backend = Backend::new(cc.egui_ctx.clone());
        backend.send(Action::Refresh);
        Self {
            backend,
            width: 1180.0,
            tokens,
            page: Page::Live,
            staged: BTreeMap::new(),
            color: [183, 146, 230],
            brightness: 70,
            off: false,
            last_completed: 0,
            last_path: String::new(),
            draft_context: Value::Null,
            selected_button: None,
            inspected: None,
            show_mappings: false,
            lighting_dirty: false,
            lighting_snapshot: Value::Null,
            toasts: vec![],
        }
    }
    fn action(&self, action: &str, params: Value) {
        self.backend.send(Action::Perform(action.into(), params));
    }
    fn toast(&mut self, tone: Tone, text: impl Into<String>) {
        self.toasts.push(Toast {
            tone,
            text: text.into(),
            at: Instant::now(),
        });
        if self.toasts.len() > 4 {
            self.toasts.remove(0);
        }
    }
    fn set_scheme(&mut self, ctx: &egui::Context, scheme: Scheme, reduced_motion: bool) {
        self.tokens = Tokens::new(scheme, reduced_motion);
        self.tokens.install(ctx);
    }
    fn reset_lighting(&mut self) {
        self.lighting_dirty = false;
        self.lighting_snapshot = Value::Null;
    }
    fn reconcile(&mut self, state: &State) {
        if self.last_path != state.path {
            self.staged.clear();
            self.draft_context = Value::Null;
            self.last_path = state.path.clone();
            self.inspected = None;
            self.reset_lighting();
        }
        reconcile_draft(
            &mut self.staged,
            &mut self.draft_context,
            &state.data["snapshot"],
        );
        if state.completed != self.last_completed {
            self.last_completed = state.completed;
            if state.error.is_empty() {
                if !state.last_preview {
                    if state.last_action == "profileApply" {
                        self.staged.clear();
                    }
                    if state.last_action == "lightingApply" {
                        self.reset_lighting();
                    }
                }
                if !state.notice.is_empty() {
                    let tone = if state.last_preview {
                        Tone::Info
                    } else {
                        Tone::Success
                    };
                    self.toast(tone, state.notice.clone());
                }
            } else {
                self.toast(
                    Tone::Danger,
                    format!("{} failed", backend::human(&state.last_action)),
                );
            }
        }
        if !self.lighting_snapshot.is_null()
            && !state.data["lighting"].is_null()
            && self.lighting_snapshot["identity"] != state.data["lighting"]["identity"]
        {
            self.lighting_dirty = false;
        }
        if !self.lighting_dirty
            && !state.data["lighting"].is_null()
            && self.lighting_snapshot != state.data["lighting"]
        {
            self.lighting_snapshot = state.data["lighting"].clone();
            if let Some(hex) = state.data["color"].as_str()
                && let Ok(c) = Color32::from_hex(hex)
            {
                self.color = [c.r(), c.g(), c.b()];
            }
            self.brightness = state.data["brightness"].as_u64().unwrap_or(70) as u8;
            self.off = state.data["mode"].as_u64() == Some(6);
        }
    }
    fn save_mapping(&self, persist: bool) {
        self.action(
            "profileApply",
            json!({"mappings": self.staged, "persist": persist}),
        );
    }
    fn apply_lighting(&self) {
        self.action(
            "lightingApply",
            json!({"color": self.hex(), "brightness": self.brightness, "off": self.off}),
        );
    }
    fn hex(&self) -> String {
        format!(
            "#{:02X}{:02X}{:02X}",
            self.color[0], self.color[1], self.color[2]
        )
    }
    fn shortcuts(&mut self, ctx: &egui::Context, state: &State) {
        let pages = [
            Page::Live,
            Page::Mapping,
            Page::Lighting,
            Page::Features,
            Page::Firmware,
            Page::Diagnostics,
        ];
        let keys = [
            egui::Key::Num1,
            egui::Key::Num2,
            egui::Key::Num3,
            egui::Key::Num4,
            egui::Key::Num5,
            egui::Key::Num6,
        ];
        for (key, page) in keys.into_iter().zip(pages) {
            if ctx.input_mut(|i| i.consume_key(egui::Modifiers::COMMAND, key)) {
                self.page = page;
            }
        }
        let save = ctx.input_mut(|i| i.consume_key(egui::Modifiers::COMMAND, egui::Key::S));
        if save && state.busy.is_empty() {
            if self.page == Page::Mapping && !self.staged.is_empty() {
                self.save_mapping(true);
            } else if self.page == Page::Lighting && self.lighting_dirty {
                self.apply_lighting();
            }
        }
    }
}
impl eframe::App for App {
    fn update(&mut self, ctx: &egui::Context, _: &mut eframe::Frame) {
        self.backend.watch(
            self.page.reads(),
            matches!(self.page, Page::Live | Page::Mapping),
            ctx.input(|i| i.focused),
        );
        let state = self.backend.state();
        self.reconcile(&state);
        self.shortcuts(ctx, &state);
        self.width = ctx.content_rect().width();
        self.header(ctx, &state);
        self.sidebar(ctx);
        self.changes_bar(ctx, &state);
        self.content(ctx, &state);
        self.toasts(ctx);
    }
}
fn main() -> eframe::Result {
    if std::env::args().any(|arg| arg == "--self-test") {
        let output = std::process::Command::new(backend::helper_path())
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .and_then(|mut child| {
                use std::io::Write;
                writeln!(child.stdin.take().unwrap(), "{{\"action\":\"devices\"}}")?;
                child.wait_with_output()
            });
        match output {
            Ok(output)
                if output.status.success()
                    && serde_json::from_slice::<Value>(&output.stdout)
                        .is_ok_and(|v| v["ok"] == true) =>
            {
                println!("FreeDigi controller service self-test passed");
                return Ok(());
            }
            other => {
                eprintln!("Self-test failed: {other:?}");
                std::process::exit(1);
            }
        }
    }
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([1180.0, 820.0])
            .with_min_inner_size([720.0, 540.0])
            .with_icon(app_icon()),
        renderer: RENDERER,
        // One frame in flight lets Metal keep two window drawables instead of three.
        #[cfg(target_os = "macos")]
        wgpu_options: eframe::egui_wgpu::WgpuConfiguration {
            desired_maximum_frame_latency: Some(1),
            ..Default::default()
        },
        ..Default::default()
    };
    eframe::run_native(
        "FreeDigi",
        options,
        Box::new(|cc| Ok(Box::new(App::new(cc)))),
    )
}

// Keep edits through a failed write/reread, but never transfer them to another
// identity or slot (including switching profiles using the controller itself).
fn reconcile_draft(staged: &mut BTreeMap<String, usize>, context: &mut Value, snapshot: &Value) {
    if snapshot.is_null() {
        return;
    }
    let next = json!({"identity":snapshot["identity"], "slot":snapshot["slot"]});
    if !context.is_null() && *context != next {
        staged.clear();
    }
    *context = next;
}
fn rendering_summary(ctx: &egui::Context) -> String {
    let atlas = ctx.fonts(|f| f.font_image_size());
    let manager = ctx.tex_manager();
    let textures = manager.read();
    let bytes: usize = textures
        .allocated()
        .map(|(_, meta)| meta.bytes_used())
        .sum();
    let count = textures.allocated().len();
    let loaders = ctx.loaders();
    let image_bytes: usize = loaders
        .image
        .lock()
        .iter()
        .map(|loader| loader.byte_size())
        .sum();
    format!(
        "Renderer: {} · scale {:.1}×\nFont atlas: {} × {}\nTracked textures: {} · {:.2} MiB\nImage loader cache: {:.2} MiB\nThese counters exclude OS/window buffers and graphics-driver allocations.",
        if cfg!(target_os = "macos") {
            "wgpu/Metal"
        } else {
            "Glow/OpenGL"
        },
        ctx.pixels_per_point(),
        atlas[0],
        atlas[1],
        count,
        bytes as f64 / 1048576.0,
        image_bytes as f64 / 1048576.0
    )
}
fn diagnostic_report(ctx: &egui::Context, state: &State) -> String {
    format!("{}\n\n{}", rendering_summary(ctx), state.report())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn mapping_drafts_follow_identity_and_slot_but_survive_read_retry() {
        let first = json!({"identity":{"address":[1,2,3,4]},"slot":0});
        let mut context = Value::Null;
        let mut staged = BTreeMap::new();
        reconcile_draft(&mut staged, &mut context, &first);
        staged.insert("18".into(), 4);
        reconcile_draft(&mut staged, &mut context, &Value::Null);
        reconcile_draft(&mut staged, &mut context, &first);
        assert_eq!(staged.get("18"), Some(&4));
        let mut other = first.clone();
        other["slot"] = json!(1);
        reconcile_draft(&mut staged, &mut context, &other);
        assert!(staged.is_empty());
        staged.insert("19".into(), 7);
        other["identity"] = json!({"address":[5,6,7,8]});
        reconcile_draft(&mut staged, &mut context, &other);
        assert!(staged.is_empty());
    }
    #[test]
    fn every_operation_has_an_owner_page_and_human_label() {
        for action in [
            "profileRead",
            "profileApply",
            "lightingRead",
            "lightingApply",
            "turboRead",
            "turboApply",
            "calibrationRead",
            "calibrationApply",
            "firmwareRead",
        ] {
            assert!(Page::of_action(action).is_some(), "{action}");
            assert_ne!(backend::human(action), action);
        }
    }
}
