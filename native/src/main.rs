mod backend;
mod controller_view;
use backend::{Action, Backend, State};
use chaiky_egui::{Mood, Scheme, Theme, Tone};
use eframe::egui::{self, Color32, RichText};
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
    selected_button: usize,
    lighting_dirty: bool,
    lighting_snapshot: Value,
}
impl App {
    fn new(cc: &eframe::CreationContext<'_>) -> Self {
        let theme = Theme {
            scheme: Scheme::Dark,
            ..Theme::default()
        };
        theme.install(&cc.egui_ctx);
        let mut fonts = egui::FontDefinitions::default();
        fonts.font_data.insert(
            "Nunito".into(),
            egui::FontData::from_static(include_bytes!("../assets/fonts/Nunito-Regular.ttf"))
                .into(),
        );
        fonts
            .families
            .get_mut(&egui::FontFamily::Proportional)
            .unwrap()
            .insert(0, "Nunito".into());
        cc.egui_ctx.set_fonts(fonts);
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
            selected_button: 18,
            lighting_dirty: false,
            lighting_snapshot: Value::Null,
        }
    }
    fn action(&self, action: &str, params: Value) {
        self.backend.send(Action::Perform(action.into(), params));
    }
    fn reconcile(&mut self, state: &State) {
        if self.last_path != state.path {
            self.staged.clear();
            self.draft_context = Value::Null;
            self.last_path = state.path.clone();
            self.lighting_dirty = false;
            self.lighting_snapshot = Value::Null;
        }
        reconcile_draft(
            &mut self.staged,
            &mut self.draft_context,
            &state.data["snapshot"],
        );
        if state.completed != self.last_completed {
            self.last_completed = state.completed;
            if state.error.is_empty() && !state.last_preview {
                if state.last_action == "profileApply" {
                    self.staged.clear();
                }
                if state.last_action == "lightingApply" {
                    self.lighting_dirty = false;
                    self.lighting_snapshot = Value::Null;
                }
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
    fn sync_hint(&self, ui: &mut egui::Ui, state: &State, read: &str, ready: bool) {
        if let Some(error) = state.setting_errors.get(read) {
            ui.label(
                RichText::new(format!("Couldn’t sync this setting. {error}"))
                    .color(self.theme.color("warning")),
            );
            ui.label(
                RichText::new("Retrying automatically. Refresh is available in the top bar.")
                    .small()
                    .color(self.theme.color("muted")),
            );
        } else if !ready {
            ui.label(
                RichText::new(if state.path.is_empty() {
                    "Connect your controller to get started."
                } else {
                    "Loading from your controller…"
                })
                .color(self.theme.color("muted")),
            );
        }
    }
    fn overview(&mut self, ui: &mut egui::Ui, state: &State) {
        let theme = self.theme;
        theme.card(ui, |ui| {
            ui.horizontal(|ui| {
                theme.mascot(
                    ui,
                    64.0,
                    if state.path.is_empty() {
                        Mood::Resting
                    } else {
                        Mood::Happy
                    },
                );
                ui.vertical(|ui| {
                    ui.label(
                        RichText::new(if state.path.is_empty() {
                            "Ready when you are"
                        } else {
                            "Your controller, connected"
                        })
                        .size(22.0)
                        .strong(),
                    );
                    ui.label(
                        RichText::new(if state.path.is_empty() {
                            "Plug in your controller or USB receiver. We’ll find it automatically."
                        } else {
                            "Inputs and settings stay in sync automatically."
                        })
                        .color(theme.color("muted")),
                    );
                });
            });
            if !state.devices.is_empty() {
                egui::ComboBox::from_id_salt("device")
                    .width(340.0)
                    .selected_text(
                        state
                            .devices
                            .iter()
                            .find(|d| d.path == state.path)
                            .map(|d| d.name.as_str())
                            .unwrap_or("Permission needed"),
                    )
                    .show_ui(ui, |ui| {
                        for d in &state.devices {
                            ui.add_enabled_ui(d.accessible, |ui| {
                                if ui.selectable_label(d.path == state.path, &d.name).clicked() {
                                    self.backend.send(Action::Select(d.path.clone()));
                                }
                            });
                        }
                    });
                if state.path.is_empty() {
                    ui.label(
                        "On Linux, install the included udev rule to allow controller access.",
                    );
                }
            }
        });
        ui.add_space(6.0);
        theme.card(ui, |ui| {
            ui.horizontal(|ui| {
                ui.heading("Live inputs");
                theme.badge(
                    ui,
                    connection_label(state),
                    if state.monitoring {
                        Tone::Success
                    } else {
                        Tone::Neutral
                    },
                );
            });
            if let Some(id) = controller_view::controller(ui, theme, &state.input, None) {
                self.selected_button = id;
                self.page = Page::Mapping;
            }
            ui.horizontal_wrapped(|ui| {
                controller_view::meter(ui, "LT", state.input.left_trigger, theme);
                controller_view::meter(ui, "RT", state.input.right_trigger, theme);
                ui.label(
                    RichText::new(format!(
                        "L {:+.2}, {:+.2}    R {:+.2}, {:+.2}",
                        state.input.left_x,
                        state.input.left_y,
                        state.input.right_x,
                        state.input.right_y
                    ))
                    .monospace()
                    .size(12.0)
                    .color(theme.color("muted")),
                );
            });
            ui.label(
                RichText::new("Buttons light up as you play. Click one to edit its mapping.")
                    .color(theme.color("muted")),
            );
        });
        ui.label(
            RichText::new(
                "Input monitoring does not create a virtual gamepad or change game compatibility.",
            )
            .small()
            .color(theme.color("muted")),
        );
    }
    fn mappings(&mut self, ui: &mut egui::Ui, state: &State) {
        let theme = self.theme;
        let ready = state.data.get("snapshot").is_some();
        theme.card(ui,|ui| {
            ui.horizontal(|ui| {ui.heading(state.data["title"].as_str().unwrap_or("Button mapping"));if ready{theme.badge(ui,&format!("Profile {}",state.data["slot"]),Tone::Neutral);}});
            self.sync_hint(ui,state,"profileRead",ready);
            if let Some(id)=controller_view::controller(ui,theme,&state.input,Some(self.selected_button)){self.selected_button=id;}
            ui.separator();
            let source=self.selected_button;let key=source.to_string();
            let current=state.data["mappings"][&key].as_u64().map(|v|v as usize);
            let target=self.staged.get(&key).copied().or(current);
            ui.horizontal(|ui| {
                theme.badge(ui,BUTTONS[source],Tone::Accent);
                ui.label("sends");ui.label(RichText::new(target.and_then(|i|BUTTONS.get(i)).copied().unwrap_or(if ready{"Custom mapping"}else{"Loading…"})).strong());
            });
            ui.label(RichText::new("Select a physical button above, then choose what it sends below.").color(theme.color("muted")));
            ui.add_enabled_ui(ready && state.busy.is_empty(),|ui| {
                ui.horizontal_wrapped(|ui| {
                    for (id,name) in BUTTONS.iter().enumerate() {
                        if ui.add_sized([54.0,34.0],egui::Button::new(name.replace("D-pad ","")).selected(target==Some(id))).clicked() {
                            if current==Some(id){self.staged.remove(&key);}else{self.staged.insert(key.clone(),id);}
                        }
                    }
                });
                if !self.staged.is_empty(){
                    ui.separator();ui.label(RichText::new(format!("{} changes ready",self.staged.len())).strong());
                    ui.horizontal_wrapped(|ui| {
                        for (source,target) in self.staged.clone(){let id=source.parse::<usize>().unwrap_or(0);if ui.button(format!("{} → {}  ×",BUTTONS[id],BUTTONS[target])).on_hover_text("Remove this change").clicked(){self.staged.remove(&source);}}
                    });
                }
                ui.horizontal_wrapped(|ui| {
                    ui.add_enabled_ui(!self.staged.is_empty(),|ui| {
                        if theme.button(ui,if state.dry_run{"Preview temporary"}else{"Apply until restart"},false).clicked(){self.action("profileApply",json!({"mappings":self.staged,"persist":false}));}
                        if theme.button(ui,if state.dry_run{"Preview save"}else{"Save to controller"},true).clicked(){self.action("profileApply",json!({"mappings":self.staged,"persist":true}));}
                        if ui.button("Discard edits").clicked(){self.staged.clear();}
                    });
                });
            });
            ui.label(RichText::new("Existing custom mappings stay intact until you edit them. Live changes are backed up and verified.").small().color(theme.color("muted")));
        });
    }
    fn lighting(&mut self, ui: &mut egui::Ui, state: &State) {
        let theme = self.theme;
        let ready = state.data.get("lighting").is_some();
        theme.card(ui,|ui| {
            ui.heading("Make it glow");ui.label("Choose a solid color and brightness for your controller.");
            self.sync_hint(ui,state,"lightingRead",ready);
            ui.add_enabled_ui(ready && state.busy.is_empty(),|ui| {
                ui.add_space(12.0);
                ui.horizontal(|ui| {ui.label("Color");self.lighting_dirty |= ui.color_edit_button_srgb(&mut self.color).changed();ui.monospace(format!("#{:02X}{:02X}{:02X}",self.color[0],self.color[1],self.color[2]));});
                self.lighting_dirty |= ui.add(egui::Slider::new(&mut self.brightness,0..=100).text("Brightness %")).changed();
                self.lighting_dirty |= theme.toggle(ui,"Lights off",&mut self.off,false).changed();
                ui.add_space(10.0);
                if theme.button(ui,if state.dry_run{"Preview lighting"}else{"Apply lighting"},true).clicked(){self.action("lightingApply",json!({"color":format!("#{:02X}{:02X}{:02X}",self.color[0],self.color[1],self.color[2]),"brightness":self.brightness,"off":self.off}));}
                if self.lighting_dirty {ui.label(RichText::new("Your changes are staged. Background sync won’t replace them.").small().color(theme.color("muted")));}
            });
        });
    }
    fn settings(&mut self, ui: &mut egui::Ui, state: &State) {
        for (key, title, description) in [
            (
                "turbo",
                "Turbo button",
                "Enable the controller’s physical Turbo button and its hardware mapping features. This does not assign rapid fire.",
            ),
            (
                "calibration",
                "Automatic calibration",
                "Let the controller’s firmware adjust the sticks automatically. This is not a manual calibration wizard.",
            ),
        ] {
            self.theme.card(ui, |ui| {
                ui.heading(title);
                ui.label(description);
                let setting = &state.data[key];
                let ready = !setting.is_null();
                let supported = setting["supported"] == true;
                let enabled = setting["enabled"] == true;
                self.sync_hint(ui, state, &format!("{key}Read"), ready);
                if ready {
                    self.theme.badge(
                        ui,
                        if !supported {
                            "Not supported"
                        } else if enabled {
                            "Enabled on controller"
                        } else {
                            "Disabled on controller"
                        },
                        Tone::Neutral,
                    );
                }
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
            ui.add_space(8.0);
        }
    }
    fn firmware(&self, ui: &mut egui::Ui, state: &State) {
        self.theme.card(ui, |ui| {
            ui.heading("Installed firmware");
            self.sync_hint(
                ui,
                state,
                "firmwareRead",
                state.data.get("versions").is_some(),
            );
            for (key, label) in [
                ("main", "Main controller"),
                ("rf", "Controller radio"),
                ("si", "Bluetooth / SI"),
                ("dongle", "USB receiver"),
            ] {
                ui.horizontal(|ui| {
                    ui.label(label);
                    ui.monospace(
                        state.data["versions"][key]
                            .as_str()
                            .unwrap_or("Not reported"),
                    );
                });
            }
            ui.separator();
            ui.label("Firmware installation is not available in this preview.");
        });
    }
    fn diagnostics(&mut self, ui: &mut egui::Ui, state: &State) {
        self.theme.card(ui, |ui| {
            ui.horizontal(|ui| {
                ui.heading("Operation log");
                if self.theme.button(ui,"Copy report",false).clicked() { ui.ctx().copy_text(diagnostic_report(ui.ctx(), state)); self.export_message="Diagnostic report copied.".into(); }
                if self.theme.button(ui,"Export report",false).clicked() {
                    let base=std::env::var_os("XDG_STATE_HOME").map(std::path::PathBuf::from).unwrap_or_else(|| std::env::var_os("HOME").map(std::path::PathBuf::from).unwrap_or_else(std::env::temp_dir).join(".local/state"));
                    let directory=base.join("freedigi/diagnostics");
                    let stamp=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis();
                    let path=directory.join(format!("report-{stamp}.txt"));
                    self.export_message=match std::fs::create_dir_all(&directory).and_then(|_|std::fs::write(&path,diagnostic_report(ui.ctx(), state))) { Ok(())=>format!("Saved {}",path.display()),Err(e)=>format!("Export failed: {e}") };
                }
            });
            ui.label(format!("Build {} · {}/{} · last 200 events",backend::BUILD,std::env::consts::OS,std::env::consts::ARCH));
            if !self.export_message.is_empty() {ui.label(&self.export_message);}
            ui.label(RichText::new("Reads remain live in dry run. No controller packets are included in this report.").color(self.theme.color("muted")));
            ui.monospace(rendering_summary(ui.ctx()));
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
        let reads: &[&str] = match self.page {
            Page::Mapping => &["profileRead"],
            Page::Lighting => &["lightingRead"],
            Page::Settings => &["turboRead", "calibrationRead"],
            Page::Firmware => &["firmwareRead"],
            _ => &[],
        };
        self.backend.watch(
            reads,
            matches!(self.page, Page::Overview | Page::Mapping),
            ctx.input(|i| i.focused),
        );
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
                    theme.badge(ui, "PREVIEW", Tone::Accent);
                    ui.add_enabled_ui(state.busy.is_empty(), |ui| {
                        if theme
                            .button(ui, "Refresh", false)
                            .on_hover_text("Find controllers and refresh the current page")
                            .clicked()
                        {
                            self.backend.send(Action::Refresh);
                        }
                    });
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
                ui.spacing_mut().item_spacing.y = 4.0;
                ui.add_space(8.0);
                for (page, title) in PAGES {
                    if theme.navigation(ui, title, self.page == page).clicked() {
                        self.page = page;
                    }
                }
                ui.add_space((ui.available_height() - 210.0).max(12.0));
                egui::Frame::new()
                    .fill(theme.color("surface"))
                    .corner_radius(12)
                    .inner_margin(12)
                    .show(ui, |ui| {
                        ui.horizontal(|ui| {
                            theme.mascot(
                                ui,
                                38.0,
                                if state.path.is_empty() {
                                    Mood::Resting
                                } else {
                                    Mood::Happy
                                },
                            );
                            ui.vertical(|ui| {
                                ui.label(
                                    RichText::new(if state.path.is_empty() {
                                        "Searching…"
                                    } else {
                                        "Controller ready"
                                    })
                                    .size(13.0)
                                    .strong(),
                                );
                                ui.label(
                                    RichText::new(connection_label(&state))
                                        .size(12.0)
                                        .color(theme.color("muted")),
                                );
                            });
                        });
                    });
                ui.vertical(|ui| {
                    if ui
                        .button(if theme.scheme == Scheme::Dark {
                            "Light theme"
                        } else {
                            "Dark theme"
                        })
                        .clicked()
                    {
                        self.theme.scheme = if theme.scheme == Scheme::Dark {
                            Scheme::Light
                        } else {
                            Scheme::Dark
                        };
                        self.theme.install(ctx);
                    }
                    let mut reduced = theme.reduced_motion;
                    if ui.checkbox(&mut reduced, "Less motion").changed() {
                        self.theme.reduced_motion = reduced;
                        self.theme.install(ctx);
                    }
                });
                ui.label(
                    RichText::new("Built on ControlLab")
                        .size(11.0)
                        .color(theme.color("muted")),
                );
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
                    theme.status(ui, &state.busy, Tone::Accent, true);
                }
                if !state.error.is_empty()
                    && (state.error_action.is_empty()
                        || ["monitor", "discovery"].contains(&state.error_action.as_str())
                        || reads.iter().any(|r| {
                            r.trim_end_matches("Read")
                                == state.error_action.trim_end_matches("Apply")
                        }))
                {
                    ui.label(RichText::new(&state.error).color(theme.color("danger")));
                }
                if !state.notice.is_empty()
                    && reads.iter().any(|r| {
                        r.trim_end_matches("Read") == state.last_action.trim_end_matches("Apply")
                    })
                {
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

fn connection_label(state: &State) -> &'static str {
    if state.path.is_empty() {
        "Auto discovery on"
    } else if !state.focused {
        "Ready in background"
    } else if !state.busy.is_empty() {
        "Syncing settings"
    } else if state.monitoring {
        "Live inputs ready"
    } else {
        "Connecting input stream…"
    }
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
        "Renderer: Glow/OpenGL · scale {:.1}×\nFont atlas: {} × {}\nTracked textures: {} · {:.2} MiB\nImage loader cache: {:.2} MiB\nThese counters exclude OS/window buffers and graphics-driver allocations.",
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
