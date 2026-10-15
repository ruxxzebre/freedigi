mod backend;
use backend::{Action, Backend, State};
use chaiky_egui::{Mood, Scheme, Theme, Tone};
use eframe::egui::{self, Color32, RichText, Vec2};
use serde_json::{Value, json};
use std::collections::BTreeMap;

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
    Overview,
    Mapping,
    Lighting,
    Settings,
    Firmware,
    Diagnostics,
    About,
}
const PAGES: [(Page, &str); 7] = [
    (Page::Overview, "Overview"),
    (Page::Mapping, "Button mapping"),
    (Page::Lighting, "Lighting"),
    (Page::Settings, "Controller settings"),
    (Page::Firmware, "Firmware"),
    (Page::Diagnostics, "Diagnostics"),
    (Page::About, "About FreeDigi"),
];
struct App {
    backend: Backend,
    theme: Theme,
    page: Page,
    staged: BTreeMap<String, usize>,
    color: [u8; 3],
    brightness: u8,
    off: bool,
    last_completed: u64,
    last_path: String,
    export_message: String,
    draft_context: Value,
}
impl App {
    fn new(cc: &eframe::CreationContext<'_>) -> Self {
        let theme = Theme::default();
        theme.install(&cc.egui_ctx);
        let backend = Backend::new(cc.egui_ctx.clone());
        backend.send(Action::Refresh);
        Self {
            backend,
            theme,
            page: Page::Overview,
            staged: BTreeMap::new(),
            color: [160, 110, 235],
            brightness: 70,
            off: false,
            last_completed: 0,
            last_path: String::new(),
            export_message: String::new(),
            draft_context: Value::Null,
        }
    }
    fn action(&self, action: &str, params: Value) {
        self.backend.send(Action::Perform(action.into(), params));
    }
    fn read(&self, ui: &mut egui::Ui, state: &State, action: &str, label: &str) {
        ui.add_enabled_ui(state.busy.is_empty() && !state.path.is_empty(), |ui| {
            if self.theme.button(ui, label, false).clicked() {
                self.action(action, json!({}));
            }
        });
    }
    fn reconcile(&mut self, state: &State) {
        if self.last_path != state.path {
            self.staged.clear();
            self.draft_context = Value::Null;
            self.last_path = state.path.clone();
        }
        reconcile_draft(
            &mut self.staged,
            &mut self.draft_context,
            &state.data["snapshot"],
        );
        if state.completed == self.last_completed {
            return;
        }
        self.last_completed = state.completed;
        if state.error.is_empty() && !state.last_preview {
            if state.last_action == "profileApply" {
                self.staged.clear();
            }
            if state.last_action.starts_with("lighting") {
                if let Some(hex) = state.data["color"].as_str() {
                    if let Ok(c) = Color32::from_hex(hex) {
                        self.color = [c.r(), c.g(), c.b()];
                    }
                }
                self.brightness = state.data["brightness"].as_u64().unwrap_or(70) as u8;
                self.off = state.data["mode"].as_u64() == Some(6);
            }
        }
    }
    fn overview(&mut self, ui: &mut egui::Ui, state: &State) {
        let theme = self.theme;
        theme.card(ui, |ui| {
            ui.horizontal(|ui| {
                theme.mascot(
                    ui,
                    116.0,
                    if state.path.is_empty() {
                        Mood::Resting
                    } else {
                        Mood::Happy
                    },
                );
                ui.vertical(|ui| {
                    ui.label(
                        RichText::new("A little home for your controller.")
                            .size(24.0)
                            .strong(),
                    );
                    ui.label(
                        RichText::new("Make it yours, then get back to your game.")
                            .color(theme.color("muted")),
                    );
                    ui.add_space(5.0);
                    theme.badge(
                        ui,
                        if state.path.is_empty() {
                            "Waiting for a controller"
                        } else {
                            "Configuration interface available"
                        },
                        if state.path.is_empty() {
                            Tone::Neutral
                        } else {
                            Tone::Success
                        },
                    );
                });
            });
        });
        ui.add_space(8.0);
        theme.card(ui, |ui| {
            ui.horizontal(|ui| { ui.heading("Your controller"); if theme.button(ui,"Refresh",false).clicked() { self.backend.send(Action::Refresh); } });
            if state.devices.is_empty() {
                ui.label("Connect your Vader 5 Pro by USB or its receiver, then refresh.");
                ui.label(RichText::new("Linux needs the bundled udev rule for HID access. Bluetooth configuration is not included.").small().color(theme.color("muted")));
            } else {
                egui::ComboBox::from_id_salt("device").width(400.0).selected_text(state.devices.iter().find(|d| d.path == state.path).map(|d| d.name.as_str()).unwrap_or("Select a controller")).show_ui(ui, |ui| {
                    for device in &state.devices { if ui.selectable_label(device.path == state.path, format!("{}{}",device.name,if device.accessible { "" } else { " · permission needed" })).clicked() { self.backend.send(Action::Select(device.path.clone())); } }
                });
                ui.label(RichText::new(&state.path).small().color(theme.color("muted")));
            }
            ui.add_enabled_ui(!state.path.is_empty() && state.busy.is_empty(), |ui| {
                if theme.button(ui, if state.monitor_wanted { "Stop input monitor" } else { "Start input monitor" }, true).clicked() { self.backend.send(Action::Monitor(!state.monitor_wanted)); }
            });
        });
        ui.add_space(8.0);
        theme.card(ui, |ui| {
            ui.horizontal(|ui| { ui.heading("Live inputs"); theme.badge(ui, if state.monitoring { "Receiving" } else if state.monitor_wanted { "Paused for settings" } else { "Stopped" }, if state.monitoring { Tone::Success } else { Tone::Neutral }); });
            ui.horizontal_wrapped(|ui| { for (id,name) in BUTTONS.iter().enumerate() { theme.badge(ui,name,if state.input.buttons.contains(&id) { Tone::Accent } else { Tone::Neutral }); } });
            ui.add_space(6.0);
            ui.columns(2, |columns| {
                for (i,label,x,y) in [(0,"Left stick",state.input.left_x,state.input.left_y),(1,"Right stick",state.input.right_x,state.input.right_y)] {
                    columns[i].label(format!("{label}   {x:.3}, {y:.3}"));
                    let (rect,_) = columns[i].allocate_exact_size(Vec2::new(110.0,100.0),egui::Sense::hover());
                    let center=rect.center(); let p=columns[i].painter();
                    p.circle_filled(center,43.0,theme.color("soft")); p.circle_stroke(center,43.0,egui::Stroke::new(1.0_f32,theme.color("line")));
                    p.circle_filled(center+Vec2::new(x.clamp(-1.0,1.0)*35.0,-y.clamp(-1.0,1.0)*35.0),7.0,theme.color("accent"));
                }
            });
            ui.label(RichText::new("This reads controller inputs. It does not create a virtual gamepad or establish game compatibility.").small().color(theme.color("muted")));
        });
    }
    fn mappings(&mut self, ui: &mut egui::Ui, state: &State) {
        let theme = self.theme;
        theme.card(ui, |ui| {
            ui.horizontal(|ui| { ui.heading(state.data["title"].as_str().unwrap_or("Your button layout")); self.read(ui,state,"profileRead","Read active profile"); });
            if state.data.get("snapshot").is_none() { theme.empty(ui,"Start with your current layout","Read the active profile to enable editing. Existing custom mappings stay intact."); return; }
            ui.label(format!("Profile {} · {} staged change(s)",state.data["slot"], self.staged.len()));
            ui.add_enabled_ui(state.busy.is_empty(), |ui| {
                egui::Grid::new("mappings").num_columns(3).spacing([22.0,8.0]).striped(true).show(ui, |ui| {
                    for (id,name) in BUTTONS.iter().enumerate() {
                        let key=id.to_string(); let current=state.data["mappings"][&key].as_u64().map(|v|v as usize);
                        let mut value=self.staged.get(&key).copied().or(current);
                        theme.badge(ui,name,if state.input.buttons.contains(&id) { Tone::Accent } else { Tone::Neutral });
                        ui.label(if id>=18 {"Back button"} else if id>=16 {"Extra face button"} else {"Standard control"});
                        egui::ComboBox::from_id_salt(("mapping",id)).width(225.0).selected_text(value.and_then(|i|BUTTONS.get(i)).copied().unwrap_or("Custom mapping (preserved)")).show_ui(ui, |ui| {
                            for (target,title) in BUTTONS.iter().enumerate() { ui.selectable_value(&mut value,Some(target),*title); }
                        });
                        if value != self.staged.get(&key).copied().or(current) { if value == current { self.staged.remove(&key); } else if let Some(value)=value { self.staged.insert(key,value); } }
                        ui.end_row();
                    }
                });
                ui.separator();
                ui.horizontal_wrapped(|ui| {
                    if theme.button(ui,"Discard edits",false).clicked() { self.staged.clear(); }
                    ui.add_enabled_ui(!self.staged.is_empty(), |ui| {
                        if theme.button(ui,if state.dry_run {"Preview temporary apply"} else {"Apply until restart"},false).clicked() { self.action("profileApply",json!({"mappings":self.staged,"persist":false})); }
                        if theme.button(ui,if state.dry_run {"Preview save"} else {"Save to controller"},true).clicked() { self.action("profileApply",json!({"mappings":self.staged,"persist":true})); }
                    });
                });
            });
            ui.label(RichText::new("Live writes back up the original profile, check it before writing, and verify the result. Macro and combo editors are not included yet.").small().color(theme.color("muted")));
        });
    }
    fn lighting(&mut self, ui: &mut egui::Ui, state: &State) {
        let theme = self.theme;
        theme.card(ui, |ui| {
            ui.horizontal(|ui| { ui.heading("Make it glow"); self.read(ui,state,"lightingRead","Read lighting"); });
            if state.data.get("lighting").is_none() { theme.empty(ui,"A little color goes a long way","Read lighting to preserve the controller’s existing LED configuration."); return; }
            ui.add_enabled_ui(state.busy.is_empty(), |ui| {
                ui.horizontal(|ui| { ui.label("Solid color"); ui.color_edit_button_srgb(&mut self.color); ui.monospace(format!("#{:02X}{:02X}{:02X}",self.color[0],self.color[1],self.color[2])); });
                ui.add(egui::Slider::new(&mut self.brightness,0..=100).text("Brightness %"));
                theme.toggle(ui,"Turn LEDs off",&mut self.off,false);
                if theme.button(ui,if state.dry_run {"Preview lighting"} else {"Apply lighting"},true).clicked() { self.action("lightingApply",json!({"color":format!("#{:02X}{:02X}{:02X}",self.color[0],self.color[1],self.color[2]),"brightness":self.brightness,"off":self.off})); }
            });
        });
    }
    fn settings(&mut self, ui: &mut egui::Ui, state: &State) {
        for (key, title, description) in [
            (
                "turbo",
                "Physical Turbo button",
                "Enable the controller’s Turbo-button functions, including its hardware mapping workflow. This does not assign rapid fire to a button.",
            ),
            (
                "calibration",
                "Automatic stick calibration",
                "Enable the firmware’s automatic stick adjustment. The controller handles it internally; this is not a manual calibration wizard.",
            ),
        ] {
            self.theme.card(ui, |ui| {
                ui.heading(title);
                ui.label(description);
                self.read(ui, state, &format!("{key}Read"), "Read setting");
                let setting = &state.data[key];
                let supported = setting["supported"] == true;
                let enabled = setting["enabled"] == true;
                self.theme.badge(
                    ui,
                    if setting.is_null() {
                        "Not read"
                    } else if !supported {
                        "Not supported"
                    } else if enabled {
                        "On controller: enabled"
                    } else {
                        "On controller: disabled"
                    },
                    Tone::Neutral,
                );
                ui.add_enabled_ui(supported && state.busy.is_empty(), |ui| {
                    let label = format!(
                        "{}{}",
                        if state.dry_run { "Preview: " } else { "" },
                        if enabled { "Disable" } else { "Enable" }
                    );
                    if self.theme.button(ui, &label, true).clicked() {
                        self.action(&format!("{key}Apply"), json!({"enabled":!enabled}));
                    }
                });
            });
            ui.add_space(10.0);
        }
    }
    fn firmware(&self, ui: &mut egui::Ui, state: &State) {
        self.theme.card(ui, |ui| {
            ui.horizontal(|ui| {ui.heading("Installed firmware");self.read(ui,state,"firmwareRead","Read versions");});
            for (key,label) in [("main","Main controller"),("rf","Controller radio"),("si","Bluetooth / SI"),("dongle","USB receiver")] {
                ui.horizontal(|ui| { ui.label(label); ui.monospace(state.data["versions"][key].as_str().unwrap_or("Not reported")); });
            }
            ui.separator();
            self.theme.badge(ui,"Firmware installation is not available",Tone::Warning);
            ui.label("Update and recovery paths still need validation. Reading versions does not flash firmware.");
        });
    }
    fn diagnostics(&mut self, ui: &mut egui::Ui, state: &State) {
        self.theme.card(ui, |ui| {
            ui.horizontal(|ui| {
                ui.heading("Operation log");
                if self.theme.button(ui,"Copy report",false).clicked() { ui.ctx().copy_text(state.report()); self.export_message="Diagnostic report copied.".into(); }
                if self.theme.button(ui,"Export report",false).clicked() {
                    let base=std::env::var_os("XDG_STATE_HOME").map(std::path::PathBuf::from).unwrap_or_else(|| std::env::var_os("HOME").map(std::path::PathBuf::from).unwrap_or_else(std::env::temp_dir).join(".local/state"));
                    let directory=base.join("freedigi/diagnostics");
                    let stamp=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis();
                    let path=directory.join(format!("report-{stamp}.txt"));
                    self.export_message=match std::fs::create_dir_all(&directory).and_then(|_|std::fs::write(&path,state.report())) { Ok(())=>format!("Saved {}",path.display()),Err(e)=>format!("Export failed: {e}") };
                }
            });
            ui.label(format!("Build {} · {}/{} · last 200 events",backend::BUILD,std::env::consts::OS,std::env::consts::ARCH));
            if !self.export_message.is_empty() {ui.label(&self.export_message);}
            ui.label(RichText::new("Reads remain live in dry run. No controller packets are included in this report.").color(self.theme.color("muted")));
            ui.separator();
            for line in state.logs.iter().rev() {ui.add(egui::Label::new(RichText::new(line).monospace().size(12.0)).wrap()); ui.separator();}
        });
    }
    fn about(&self, ui: &mut egui::Ui) {
        self.theme.card(ui,|ui| {
            ui.vertical_centered(|ui| {self.theme.mascot(ui,130.0,Mood::Happy); ui.heading("FreeDigi");ui.label("A cozy, native home for your Flydigi controller.");});
            ui.add_space(12.0);
            ui.label("Built with Rust + egui, powered by the existing Swift controller service. Chaiky’s gull and selected native components are vendored in this repository; no webview is used by this interface.");
            ui.separator(); ui.heading("Built on ControlLab");
            ui.label("Based on the original ControlLab Swift controller app by dracinn. Its protocol code powers profile editing, lighting, Turbo and calibration. Original copyright and MIT license are retained.");
            ui.hyperlink_to("Original ControlLab project","https://github.com/dracinn/ControlLab");
            ui.hyperlink_to("FreeDigi on GitHub","https://github.com/ruxxzebre/freedigi");
            ui.label("Linux and macOS are the targets. Windows has platform groundwork only. Bluetooth configuration, firmware flashing and virtual gamepad output are not included. Independent community software, not affiliated with Flydigi.");
        });
    }
}
impl eframe::App for App {
    fn update(&mut self, ctx: &egui::Context, _: &mut eframe::Frame) {
        let state = self.backend.state();
        self.reconcile(&state);
        let theme = self.theme;
        egui::TopBottomPanel::top("toolbar")
            .frame(
                egui::Frame::new()
                    .fill(theme.color("surface"))
                    .inner_margin(egui::Margin::symmetric(20, 12)),
            )
            .show(ctx, |ui| {
                ui.horizontal(|ui| {
                    ui.label(RichText::new("FreeDigi").size(21.0).strong());
                    theme.badge(ui, "NATIVE PREVIEW", Tone::Accent);
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        let mut dry = state.dry_run;
                        if theme
                            .toggle(ui, "Dry run", &mut dry, !state.busy.is_empty())
                            .changed()
                        {
                            self.backend.send(Action::DryRun(dry));
                        }
                        ui.label(
                            RichText::new(if state.dry_run {
                                "Preview writes safely"
                            } else {
                                "Live controller writes"
                            })
                            .small()
                            .color(theme.color(if state.dry_run { "muted" } else { "warning" })),
                        );
                    });
                });
            });
        egui::SidePanel::left("navigation")
            .exact_width(205.0)
            .resizable(false)
            .frame(
                egui::Frame::new()
                    .fill(theme.color("page"))
                    .inner_margin(egui::Margin::same(14)),
            )
            .show(ctx, |ui| {
                ui.add_space(8.0);
                for (page, title) in PAGES {
                    if theme.navigation(ui, title, self.page == page).clicked() {
                        self.page = page;
                    }
                }
                ui.add_space(22.0);
                theme.badge(
                    ui,
                    if state.path.is_empty() {
                        "No controller"
                    } else {
                        "Device selected"
                    },
                    if state.path.is_empty() {
                        Tone::Neutral
                    } else {
                        Tone::Success
                    },
                );
                ui.label(
                    RichText::new(if !state.busy.is_empty() && state.monitor_wanted {
                        "Monitor paused for settings"
                    } else if state.monitoring {
                        "Input monitor running"
                    } else {
                        "Input monitor stopped"
                    })
                    .small()
                    .color(theme.color("muted")),
                );
                ui.with_layout(egui::Layout::bottom_up(egui::Align::LEFT), |ui| {
                    ui.label(
                        RichText::new("Built on ControlLab")
                            .small()
                            .color(theme.color("muted")),
                    );
                    let mut reduced = theme.reduced_motion;
                    if ui.checkbox(&mut reduced, "Reduced motion").changed() {
                        self.theme.reduced_motion = reduced;
                        self.theme.install(ctx);
                    }
                    if theme
                        .button(
                            ui,
                            if theme.scheme == Scheme::Light {
                                "Switch to night colors"
                            } else {
                                "Switch to day colors"
                            },
                            false,
                        )
                        .clicked()
                    {
                        self.theme.scheme = if theme.scheme == Scheme::Light {
                            Scheme::Dark
                        } else {
                            Scheme::Light
                        };
                        self.theme.install(ctx);
                    }
                    theme.mascot(
                        ui,
                        64.0,
                        if state.error.is_empty() {
                            Mood::Resting
                        } else {
                            Mood::Concerned
                        },
                    );
                });
            });
        egui::CentralPanel::default()
            .frame(
                egui::Frame::new()
                    .fill(theme.color("page"))
                    .inner_margin(egui::Margin::same(24)),
            )
            .show(ctx, |ui| {
                ui.heading(PAGES.iter().find(|(p, _)| *p == self.page).unwrap().1);
                ui.add_space(8.0);
                if !state.busy.is_empty() {
                    theme.status(ui, &format!("{} · working", state.busy), Tone::Accent, true);
                }
                if !state.error.is_empty() {
                    ui.label(RichText::new(&state.error).color(theme.color("danger")));
                }
                if !state.notice.is_empty() {
                    ui.label(RichText::new(&state.notice).color(theme.color("success")));
                }
                egui::ScrollArea::vertical()
                    .auto_shrink([false, false])
                    .show(ui, |ui| match self.page {
                        Page::Overview => self.overview(ui, &state),
                        Page::Mapping => self.mappings(ui, &state),
                        Page::Lighting => self.lighting(ui, &state),
                        Page::Settings => self.settings(ui, &state),
                        Page::Firmware => self.firmware(ui, &state),
                        Page::Diagnostics => self.diagnostics(ui, &state),
                        Page::About => self.about(ui),
                    });
            });
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
            .with_inner_size([1100.0, 820.0])
            .with_min_inner_size([850.0, 620.0]),
        renderer: eframe::Renderer::Glow,
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
}
