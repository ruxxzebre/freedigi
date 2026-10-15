//! Page bodies. The shell supplies header, banners and the changes bar.
use crate::{
    App, BUTTONS, Page,
    backend::{self, State},
    controller_view::{self, Badge},
    ui::{self, Kind, Space, Tone, Type, bold, semibold},
};
use chaiky_egui::Mood;
use eframe::egui::{self, Color32, CornerRadius, RichText, Stroke, StrokeKind, vec2};
use serde_json::json;
use std::collections::BTreeMap;

const PICK_GROUPS: [(&str, &[usize]); 6] = [
    ("Face", &[4, 5, 7, 8]),
    ("Shoulders", &[10, 11, 12, 13]),
    ("D-pad", &[0, 1, 2, 3]),
    ("Sticks", &[14, 15]),
    ("System", &[6, 9]),
    ("Extra", &[16, 17, 18, 19, 20, 21]),
];
const SHORT: [&str; 22] = [
    "Up", "Right", "Down", "Left", "A", "B", "View", "X", "Y", "Menu", "LB", "RB", "LT", "RT",
    "L3", "R3", "C", "Z", "M1", "M2", "M3", "M4",
];
const PRESETS: [(u32, &str); 10] = [
    (0xB792E6, "Lavender"),
    (0xFF6EC7, "Pink"),
    (0xFF5A5A, "Red"),
    (0xFF9F1C, "Orange"),
    (0xFCF434, "Sunshine"),
    (0x3DDC97, "Mint"),
    (0x2EE6D6, "Aqua"),
    (0x4D7CFF, "Blue"),
    (0x9C59D1, "Violet"),
    (0xFFFFFF, "White"),
];

/// Two panes side by side when wide enough, stacked otherwise.
fn two_pane(ui: &mut egui::Ui, right_width: f32, mut pane: impl FnMut(&mut egui::Ui, bool)) {
    let total = ui.available_width();
    if total >= 760.0 {
        ui.horizontal_top(|ui| {
            ui.allocate_ui_with_layout(
                vec2(total - right_width - Space::L, 0.0),
                egui::Layout::top_down(egui::Align::Min),
                |ui| pane(ui, false),
            );
            ui.add_space(Space::L - ui.spacing().item_spacing.x);
            ui.allocate_ui_with_layout(
                vec2(right_width, 0.0),
                egui::Layout::top_down(egui::Align::Min),
                |ui| pane(ui, true),
            );
        });
    } else {
        pane(ui, false);
        ui.add_space(Space::M);
        pane(ui, true);
    }
}

fn loading(ui: &mut egui::Ui, text: &str) {
    ui.horizontal(|ui| {
        ui.spinner();
        ui::muted(ui, text);
    });
}

impl App {
    fn disconnected(&self, ui: &mut egui::Ui, state: &State) -> bool {
        if !state.path.is_empty() {
            return false;
        }
        ui::card(ui, |ui| {
            if state.devices.iter().any(|d| !d.accessible) {
                ui::empty_state(
                    ui,
                    Mood::Concerned,
                    "Controller found, but it needs permission",
                    "On Linux, install the included udev rule, then unplug and replug the receiver.",
                );
                if cfg!(target_os = "linux") {
                    let command = "sudo cp native/assets/70-freedigi.rules /etc/udev/rules.d/ && sudo udevadm control --reload && sudo udevadm trigger";
                    ui.horizontal(|ui| {
                        ui.label(RichText::new(command).monospace().size(Type::SMALL));
                        if ui::small_button(ui, Kind::Secondary, "Copy").clicked() {
                            ui.ctx().copy_text(command.into());
                        }
                    });
                }
            } else {
                ui::empty_state(
                    ui,
                    Mood::Resting,
                    "No controller yet",
                    "Connect a Vader 5 Pro, or a Vader 4 Pro in DInput mode (PC switch, hold FN+A; blue LED). Vader 4 support is experimental and hardware untested.",
                );
            }
        });
        true
    }

    fn mapping_badges(&self, state: &State, include_saved: bool) -> BTreeMap<usize, Badge> {
        let mut badges = BTreeMap::new();
        for id in 0..BUTTONS.len() {
            let key = id.to_string();
            let current = state.data["mappings"][&key].as_u64().map(|v| v as usize);
            if let Some(target) = self.staged.get(&key) {
                badges.insert(
                    id,
                    Badge {
                        text: SHORT[*target].into(),
                        pending: true,
                    },
                );
            } else if include_saved && let Some(target) = current.filter(|t| *t != id) {
                badges.insert(
                    id,
                    Badge {
                        text: SHORT[target].into(),
                        pending: false,
                    },
                );
            }
        }
        badges
    }

    pub(crate) fn live(&mut self, ui: &mut egui::Ui, state: &State) {
        if self.disconnected(ui, state) {
            return;
        }
        let p = self.tokens.p;
        let badges = if self.show_mappings {
            self.mapping_badges(state, true)
        } else {
            BTreeMap::new()
        };
        two_pane(ui, 280.0, |ui, right| {
            if !right {
                ui::card(ui, |ui| {
                    ui::card_header(ui, "Controller", |ui| {
                        ui.label(
                            RichText::new("Show mappings")
                                .size(Type::SMALL)
                                .color(p.text_2),
                        );
                        if ui::switch(ui, self.show_mappings, "Show mappings")
                            .on_hover_text(
                                "Shows remapped buttons. Open Mapping once to load the profile.",
                            )
                            .clicked()
                        {
                            self.show_mappings = !self.show_mappings;
                        }
                    });
                    if let Some(id) =
                        controller_view::controller(ui, &state.input, self.inspected, &badges)
                    {
                        self.inspected = if self.inspected == Some(id) {
                            None
                        } else {
                            Some(id)
                        };
                    }
                    ui.add_space(Space::S);
                    ui::divider(ui);
                    ui.add_space(Space::S);
                    match self.inspected {
                        Some(id) => {
                            ui.horizontal(|ui| {
                                ui.label(
                                    RichText::new(BUTTONS[id])
                                        .font(semibold(Type::BODY))
                                        .color(p.text),
                                );
                                if let Some(target) =
                                    state.data["mappings"][id.to_string()].as_u64()
                                {
                                    ui::muted(ui, "sends");
                                    ui.label(
                                        RichText::new(BUTTONS[target as usize])
                                            .font(semibold(Type::BODY))
                                            .color(p.accent),
                                    );
                                }
                                ui.with_layout(
                                    egui::Layout::right_to_left(egui::Align::Center),
                                    |ui| {
                                        if ui::small_button(ui, Kind::Secondary, "Edit mapping  →")
                                            .clicked()
                                        {
                                            self.selected_button = Some(id);
                                            self.page = Page::Mapping;
                                        }
                                    },
                                );
                            });
                        }
                        None => {
                            ui::hint(
                                ui,
                                "Tip: click a button on the diagram to see what it sends.",
                            );
                        }
                    }
                });
            } else {
                ui::card(ui, |ui| {
                    ui::section_label(ui, "Sticks");
                    ui.horizontal(|ui| {
                        ui::stick_pad(ui, "L", state.input.left_x, state.input.left_y);
                        ui.add_space(Space::S);
                        ui::stick_pad(ui, "R", state.input.right_x, state.input.right_y);
                    });
                    ui.add_space(Space::M);
                    ui::section_label(ui, "Triggers");
                    ui::level_bar(ui, "LT", state.input.left_trigger, 150.0);
                    ui::level_bar(ui, "RT", state.input.right_trigger, 150.0);
                    ui.add_space(Space::M);
                    ui::section_label(ui, "Pressed");
                    ui.horizontal_wrapped(|ui| {
                        if state.input.buttons.is_empty() {
                            ui::hint(
                                ui,
                                if state.monitoring {
                                    "Nothing pressed"
                                } else {
                                    "Waiting for the input stream…"
                                },
                            );
                        }
                        for id in &state.input.buttons {
                            if let Some(name) = BUTTONS.get(*id) {
                                ui::tag(ui, name, Tone::Accent);
                            }
                        }
                    });
                });
            }
        });
        ui.add_space(Space::M);
        ui::hint(
            ui,
            "Monitoring only reads inputs. It does not create a virtual gamepad or change game compatibility.",
        );
    }

    pub(crate) fn mapping(&mut self, ui: &mut egui::Ui, state: &State) {
        if self.disconnected(ui, state) {
            return;
        }
        let p = self.tokens.p;
        let ready = !state.data["snapshot"].is_null();
        let editable = ready && state.busy.is_empty();
        let badges = self.mapping_badges(state, true);
        two_pane(ui, 320.0, |ui, right| {
            if !right {
                ui::card(ui, |ui| {
                    ui::card_header(ui, "Controller", |_| {});
                    if let Some(id) =
                        controller_view::controller(ui, &state.input, self.selected_button, &badges)
                    {
                        self.selected_button = Some(id);
                    }
                    ui.horizontal(|ui| {
                        ui::tag(ui, "A", Tone::Accent);
                        ui::hint(ui, "pending edit");
                        ui.add_space(Space::S);
                        ui::tag(ui, "A", Tone::Neutral);
                        ui::hint(ui, "already remapped on the controller");
                    });
                });
            } else {
                ui::card(ui, |ui| {
                    let Some(source) = self.selected_button else {
                        ui::section_label(ui, "Selected button");
                        ui::muted(ui, "Pick a button on the diagram to choose what it sends.");
                        return;
                    };
                    let key = source.to_string();
                    let current = state.data["mappings"][&key].as_u64().map(|v| v as usize);
                    let target = self.staged.get(&key).copied().or(current);
                    ui::section_label(ui, "Selected button");
                    ui.label(
                        RichText::new(BUTTONS[source])
                            .font(bold(20.0))
                            .color(p.text),
                    );
                    ui.add_space(Space::XS);
                    if !ready {
                        loading(ui, "Reading the profile from your controller…");
                    }
                    ui.add_enabled_ui(editable, |ui| {
                        ui.horizontal(|ui| {
                            ui.label(RichText::new("Sends").color(p.text_2));
                            egui::ComboBox::from_id_salt("mapping-target")
                                .width(180.0)
                                .selected_text(
                                    target.and_then(|t| BUTTONS.get(t)).copied().unwrap_or(
                                        if ready { "Custom (preserved)" } else { "…" },
                                    ),
                                )
                                .show_ui(ui, |ui| {
                                    for (id, name) in BUTTONS.iter().enumerate() {
                                        if ui.selectable_label(target == Some(id), *name).clicked()
                                        {
                                            self.stage(&key, id, current);
                                        }
                                    }
                                });
                        });
                        ui.horizontal(|ui| {
                            ui::hint(
                                ui,
                                &format!(
                                    "On controller: {}",
                                    current
                                        .and_then(|c| BUTTONS.get(c))
                                        .copied()
                                        .unwrap_or(if ready { "custom" } else { "—" })
                                ),
                            );
                            if self.staged.contains_key(&key)
                                && ui::small_button(ui, Kind::Ghost, "↩  Revert").clicked()
                            {
                                self.staged.remove(&key);
                            }
                        });
                        ui.add_space(Space::S);
                        ui::divider(ui);
                        ui.add_space(Space::S);
                        ui::section_label(ui, "Quick pick");
                        egui::Grid::new("quick-pick")
                            .num_columns(2)
                            .spacing([Space::S, Space::S])
                            .striped(false)
                            .show(ui, |ui| {
                                for (group, ids) in PICK_GROUPS {
                                    ui.label(
                                        RichText::new(group).size(Type::SMALL).color(p.text_3),
                                    );
                                    ui.horizontal_wrapped(|ui| {
                                        ui.spacing_mut().item_spacing.x = 6.0;
                                        for id in ids {
                                            if ui::chip(ui, SHORT[*id], target == Some(*id), 38.0)
                                                .on_hover_text(BUTTONS[*id])
                                                .clicked()
                                            {
                                                self.stage(&key, *id, current);
                                            }
                                        }
                                    });
                                    ui.end_row();
                                }
                            });
                    });
                });
            }
        });
        ui.add_space(Space::M);
        ui::card(ui, |ui| {
            ui::card_header(ui, "All mappings", |_| {});
            if !ready {
                loading(ui, "Waiting for the profile…");
                return;
            }
            let per = if ui.available_width() > 640.0 { 11 } else { 22 };
            let ranges: Vec<_> = (0..22).step_by(per).map(|s| s..s + per).collect();
            ui.columns(ranges.len(), |columns| {
                for (column, range) in columns.iter_mut().zip(ranges) {
                    egui::Grid::new(("mapping-table", range.start))
                        .num_columns(4)
                        .striped(false)
                        .spacing([Space::M, 6.0])
                        .min_col_width(28.0)
                        .show(column, |ui| {
                            for title in ["Button", "On controller", "Pending", ""] {
                                ui.label(RichText::new(title).size(Type::SMALL).color(p.text_3));
                            }
                            ui.end_row();
                            for id in range {
                                let key = id.to_string();
                                let current =
                                    state.data["mappings"][&key].as_u64().map(|v| v as usize);
                                let selected = Some(id) == self.selected_button;
                                let name = RichText::new(BUTTONS[id]).font(semibold(Type::SMALL));
                                if ui
                                    .add(
                                        egui::Label::new(if selected {
                                            name.color(p.accent)
                                        } else {
                                            name.color(p.text)
                                        })
                                        .sense(egui::Sense::click()),
                                    )
                                    .on_hover_cursor(egui::CursorIcon::PointingHand)
                                    .clicked()
                                {
                                    self.selected_button = Some(id);
                                }
                                ui.label(
                                    RichText::new(
                                        current
                                            .and_then(|c| BUTTONS.get(c))
                                            .copied()
                                            .unwrap_or("custom"),
                                    )
                                    .size(Type::SMALL)
                                    .color(
                                        if current == Some(id) {
                                            p.text_3
                                        } else {
                                            p.text
                                        },
                                    ),
                                );
                                match self.staged.get(&key) {
                                    Some(t) => {
                                        ui.label(
                                            RichText::new(format!("→ {}", BUTTONS[*t]))
                                                .font(semibold(Type::SMALL))
                                                .color(p.accent),
                                        );
                                        if ui::small_button(ui, Kind::Ghost, "↩")
                                            .on_hover_text("Revert")
                                            .clicked()
                                        {
                                            self.staged.remove(&key);
                                        }
                                    }
                                    None => {
                                        ui.label(
                                            RichText::new("—").size(Type::SMALL).color(p.text_3),
                                        );
                                        ui.label("");
                                    }
                                }
                                ui.end_row();
                            }
                        });
                }
            });
            ui.add_space(Space::S);
            ui::hint(
                ui,
                "Custom mappings you haven't touched stay intact. Live saves take a backup and are verified by reading the controller back.",
            );
        });
    }

    fn stage(&mut self, key: &str, target: usize, current: Option<usize>) {
        if current == Some(target) {
            self.staged.remove(key);
        } else {
            self.staged.insert(key.to_owned(), target);
        }
    }

    pub(crate) fn lighting(&mut self, ui: &mut egui::Ui, state: &State) {
        if self.disconnected(ui, state) {
            return;
        }
        let p = self.tokens.p;
        let ready = !state.data["lighting"].is_null();
        let editable = ready && state.busy.is_empty();
        two_pane(ui, 300.0, |ui, right| {
            if !right {
                ui::card(ui, |ui| {
                    ui::card_header(ui, "Settings", |_| {});
                    if !ready {
                        loading(ui, "Reading lighting from your controller…");
                    }
                    ui.add_enabled_ui(editable, |ui| {
                        ui::form_row(ui, "Mode", "Off keeps your color for next time.", |ui| {
                            if let Some(i) = ui::segmented(
                                ui,
                                if self.off { 1 } else { 0 },
                                &["Solid", "Off"],
                                None,
                            ) {
                                self.off = i == 1;
                                self.lighting_dirty = true;
                            }
                        });
                        ui::divider(ui);
                        ui.add_enabled_ui(!self.off, |ui| {
                            ui::form_row(
                                ui,
                                "Color",
                                "Pick a preset or any color you like.",
                                |ui| {
                                    ui.label(RichText::new(self.hex()).monospace().color(p.text_2));
                                    if ui.color_edit_button_srgb(&mut self.color).changed() {
                                        self.lighting_dirty = true;
                                    }
                                },
                            );
                            ui.horizontal_wrapped(|ui| {
                                ui.spacing_mut().item_spacing.x = 6.0;
                                for (value, name) in PRESETS {
                                    let c = [(value >> 16) as u8, (value >> 8) as u8, value as u8];
                                    if swatch(ui, c, self.color == c).on_hover_text(name).clicked()
                                    {
                                        self.color = c;
                                        self.lighting_dirty = true;
                                    }
                                }
                            });
                            ui.add_space(Space::S);
                            ui::divider(ui);
                            ui::form_row(ui, "Brightness", "", |ui| {
                                if ui
                                    .add(
                                        egui::Slider::new(&mut self.brightness, 0..=100)
                                            .suffix(" %"),
                                    )
                                    .changed()
                                {
                                    self.lighting_dirty = true;
                                }
                            });
                        });
                    });
                    if ready {
                        ui::divider(ui);
                        ui.add_space(Space::S);
                        ui::hint(
                            ui,
                            &format!(
                                "On controller: {} · {}%",
                                if state.data["mode"].as_u64() == Some(6) {
                                    "off".to_owned()
                                } else {
                                    state.data["color"].as_str().unwrap_or("—").to_owned()
                                },
                                state.data["brightness"].as_u64().unwrap_or(0)
                            ),
                        );
                    }
                });
            } else {
                ui::card(ui, |ui| {
                    ui::card_header(ui, "Preview", |_| {});
                    let (rect, _) = ui.allocate_exact_size(
                        vec2(ui.available_width(), 200.0),
                        egui::Sense::hover(),
                    );
                    let painter = ui.painter();
                    painter.rect(
                        rect,
                        CornerRadius::same(ui::Radius::CARD),
                        p.bg,
                        Stroke::new(1.0_f32, p.border),
                        StrokeKind::Inside,
                    );
                    let [r, g, b] = self.color;
                    let level = if self.off {
                        0.0
                    } else {
                        self.brightness as f32 / 100.0
                    };
                    let glow = Color32::from_rgb(r, g, b);
                    for (radius, a) in [(78.0, 0.10), (62.0, 0.18), (46.0, 0.30)] {
                        painter.circle_filled(rect.center(), radius, ui::alpha(glow, a * level));
                    }
                    painter.circle(
                        rect.center(),
                        30.0,
                        ui::mix(p.control, glow, 0.25 + 0.75 * level),
                        Stroke::new(1.0_f32, p.border_ctl),
                    );
                    painter.text(
                        rect.center_bottom() - vec2(0.0, 16.0),
                        egui::Align2::CENTER_CENTER,
                        if self.off {
                            "Lights off".to_owned()
                        } else {
                            format!("{} · {}%", self.hex(), self.brightness)
                        },
                        semibold(Type::SMALL),
                        p.text_2,
                    );
                });
            }
        });
    }

    pub(crate) fn features(&mut self, ui: &mut egui::Ui, state: &State) {
        if self.disconnected(ui, state) {
            return;
        }
        ui::card(ui, |ui| {
            for (i, (key, title, help)) in [
                ("turbo", "Turbo button", "Enables the controller's physical Turbo key and its hardware mapping features. Doesn't assign rapid fire."),
                ("calibration", "Automatic stick calibration", "Lets the firmware re-center the sticks by itself. This isn't a manual calibration wizard."),
            ]
            .into_iter()
            .enumerate()
            {
                if i > 0 {
                    ui::divider(ui);
                }
                let setting = &state.data[key];
                let action = format!("{key}Apply");
                ui::form_row(ui, title, help, |ui| {
                    if setting.is_null() {
                        ui.spinner();
                        return;
                    }
                    if setting["supported"] != true {
                        ui::tag(ui, "NOT SUPPORTED", Tone::Neutral);
                        return;
                    }
                    let on = setting["enabled"] == true;
                    let writing = state.busy == backend::human(&action);
                    ui.add_enabled_ui(state.busy.is_empty(), |ui| {
                        ui.label(RichText::new(if on { "On" } else { "Off" }).font(semibold(Type::SMALL)).color(if on { self.tokens.p.accent } else { self.tokens.p.text_2 }));
                        if ui::switch(ui, on, title)
                            .on_hover_text(if state.dry_run { "Dry run: validates the change without writing." } else { "Writes to the controller and reads it back." })
                            .clicked()
                        {
                            self.action(&action, json!({"enabled": !on}));
                        }
                    });
                    if writing {
                        ui.spinner();
                    }
                });
            }
        });
        ui.add_space(Space::M);
        ui::hint(
            ui,
            "Switches apply right away (validated only, in Dry run). Each change is read back from the controller.",
        );
    }

    pub(crate) fn firmware(&self, ui: &mut egui::Ui, state: &State) {
        if self.disconnected(ui, state) {
            return;
        }
        let p = self.tokens.p;
        ui::card(ui, |ui| {
            ui::card_header(ui, "Installed versions", |_| {});
            if state.data.get("versions").is_none() {
                loading(ui, "Asking the controller…");
                return;
            }
            // Unstriped: egui stripes stop at the grid's own width, not the card's.
            egui::Grid::new("firmware")
                .num_columns(2)
                .striped(false)
                .spacing([Space::XL * 2.0, Space::S])
                .show(ui, |ui| {
                    for (key, label) in [
                        ("main", "Main controller"),
                        ("rf", "Controller radio"),
                        ("si", "Bluetooth / SI"),
                        ("dongle", "USB receiver"),
                    ] {
                        ui.label(RichText::new(label).color(p.text));
                        match state.data["versions"][key].as_str() {
                            Some(v) => ui.label(RichText::new(v).monospace().color(p.text)),
                            None => ui.label(RichText::new("not reported").color(p.text_3)),
                        };
                        ui.end_row();
                    }
                });
        });
        ui.add_space(Space::M);
        ui::hint(ui, "Firmware installation isn't available in this preview.");
    }

    pub(crate) fn diagnostics(&mut self, ui: &mut egui::Ui, state: &State) {
        let p = self.tokens.p;
        ui::card(ui, |ui| {
            ui.horizontal(|ui| {
                ui::tag(ui, &format!("BUILD {}", backend::BUILD), Tone::Neutral);
                ui::tag(
                    ui,
                    &format!("{}/{}", std::env::consts::OS, std::env::consts::ARCH).to_uppercase(),
                    Tone::Neutral,
                );
                ui::tag(
                    ui,
                    if state.dry_run { "DRY RUN" } else { "LIVE" },
                    if state.dry_run {
                        Tone::Accent
                    } else {
                        Tone::Live
                    },
                );
            });
            ui.add_space(Space::S);
            egui::CollapsingHeader::new(
                RichText::new("Rendering & memory").font(semibold(Type::BODY)),
            )
            .default_open(false)
            .show(ui, |ui| {
                ui.label(
                    RichText::new(crate::rendering_summary(ui.ctx()))
                        .monospace()
                        .color(p.text_2),
                );
            });
        });
        ui.add_space(Space::M);
        ui::card(ui, |ui| {
            ui::card_header(ui, "Operation log", |ui| {
                ui::hint(ui, &format!("{} events · newest first", state.logs.len()));
            });
            if state.logs.is_empty() {
                ui::hint(ui, "Nothing yet.");
            }
            for (i, line) in state.logs.iter().rev().enumerate() {
                let (time, rest) = split_log(line);
                egui::Frame::new()
                    .fill(if i % 2 == 0 {
                        ui.visuals().faint_bg_color
                    } else {
                        Color32::TRANSPARENT
                    })
                    .corner_radius(CornerRadius::same(6))
                    .inner_margin(egui::Margin::symmetric(8, 4))
                    .show(ui, |ui| {
                        ui.set_width(ui.available_width());
                        ui.horizontal_top(|ui| {
                            ui.label(
                                RichText::new(time)
                                    .monospace()
                                    .size(Type::SMALL)
                                    .color(p.text_3),
                            );
                            ui.add(
                                egui::Label::new(
                                    RichText::new(rest)
                                        .monospace()
                                        .size(Type::SMALL)
                                        .color(p.text),
                                )
                                .wrap(),
                            );
                        });
                    });
            }
        });
    }

    pub(crate) fn about(&self, ui: &mut egui::Ui) {
        let p = self.tokens.p;
        ui::card(ui, |ui| {
            ui.vertical_centered(|ui| {
                ui.add_space(Space::M);
                ui::mascot(ui, 110.0, Mood::Happy);
                ui.label(RichText::new("FreeDigi").font(bold(26.0)).color(p.text));
                ui::muted(ui, "A small, friendly home for your Flydigi controller.");
                ui.add_space(Space::M);
            });
            ui::divider(ui);
            ui.add_space(Space::M);
            ui::section_label(ui, "Built on ControlLab");
            ui::muted(
                ui,
                "Based on the original ControlLab Swift controller app by dracinn. Its protocol code powers profile editing, lighting, Turbo and calibration. The original copyright and MIT license are retained.",
            );
            ui.horizontal(|ui| {
                ui.hyperlink_to(
                    "Original ControlLab project",
                    "https://github.com/dracinn/ControlLab",
                );
                ui.label("·");
                ui.hyperlink_to(
                    "FreeDigi on GitHub",
                    "https://github.com/ruxxzebre/freedigi",
                );
            });
            ui.add_space(Space::M);
            ui::section_label(ui, "Under the hood");
            ui::muted(
                ui,
                "Rust + egui, powered by the bundled Swift controller service. No webview. Chaiky's gull is vendored in this repository, and Nunito is embedded under the SIL Open Font License.",
            );
            ui.add_space(Space::M);
            ui::section_label(ui, "Scope");
            ui::muted(
                ui,
                "Linux and macOS are the targets; Windows has groundwork only. Bluetooth configuration, firmware flashing and virtual gamepad output aren't included. Independent community software, not affiliated with Flydigi.",
            );
        });
    }
}

fn swatch(ui: &mut egui::Ui, c: [u8; 3], selected: bool) -> egui::Response {
    let t = ui::Tokens::get(ui.ctx());
    let (rect, response) = ui.allocate_exact_size(vec2(26.0, 26.0), egui::Sense::click());
    let color = Color32::from_rgb(c[0], c[1], c[2]);
    ui.painter().circle(
        rect.center(),
        10.0,
        color,
        Stroke::new(1.0_f32, t.p.border_ctl),
    );
    if selected || response.hovered() {
        ui.painter().circle_stroke(
            rect.center(),
            12.5,
            Stroke::new(
                if selected { 2.0_f32 } else { 1.0 },
                if selected {
                    t.p.accent
                } else {
                    t.p.border_strong
                },
            ),
        );
    }
    ui::focus_ring(ui, &response, rect, ui::Radius::PILL);
    response.on_hover_cursor(egui::CursorIcon::PointingHand)
}

/// Log lines are "<unix seconds> [mode] action: message"; show UTC clock time.
fn split_log(line: &str) -> (String, &str) {
    match line.split_once(' ') {
        Some((secs, rest)) if let Ok(secs) = secs.parse::<u64>() => {
            let s = secs % 86_400;
            (
                format!("{:02}:{:02}:{:02}", s / 3600, s / 60 % 60, s % 60),
                rest,
            )
        }
        _ => (String::new(), line),
    }
}
