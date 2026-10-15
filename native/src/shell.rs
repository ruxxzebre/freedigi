//! App shell: device header, sidebar, page frame, changes bar and toasts.
//! Global actions live in the header, page actions in the page header, and
//! commit actions in the changes bar, always in the same order.
use crate::{
    App, BUTTONS, NAV, Page,
    backend::{self, Action, State},
    ui::{self, Kind, Radius, Scheme, Space, Tone, Type, bold, semibold},
};
use eframe::egui::{
    self, Align, Align2, CornerRadius, Frame, Layout, Margin, RichText, Stroke, vec2,
};
use std::time::Duration;

impl App {
    fn status(&self, state: &State) -> (String, Tone, bool, bool) {
        if state.path.is_empty() {
            return if state.devices.iter().any(|d| !d.accessible) {
                ("Needs permission".into(), Tone::Warning, false, false)
            } else {
                (
                    "Looking for a controller".into(),
                    Tone::Neutral,
                    true,
                    false,
                )
            };
        }
        if !state.busy.is_empty() {
            let tone = if state.dry_run {
                Tone::Accent
            } else {
                Tone::Live
            };
            return (state.busy.clone(), tone, true, false);
        }
        if state.syncing && state.awaiting_first_read() {
            return ("Syncing".into(), Tone::Accent, true, false);
        }
        if !state.focused {
            return ("Paused in background".into(), Tone::Neutral, false, false);
        }
        // A background revalidation pauses the stream only briefly; don't flash it.
        if state.monitoring || (state.syncing && state.monitor_wanted) {
            return ("Live input".into(), Tone::Success, false, false);
        }
        if state.error_action == "monitor" {
            return ("Input stream retrying".into(), Tone::Warning, true, true);
        }
        ("Connecting".into(), Tone::Neutral, true, false)
    }

    pub(crate) fn header(&mut self, ctx: &egui::Context, state: &State) {
        let p = self.tokens.p;
        let live = !state.dry_run;
        egui::TopBottomPanel::top("header")
            .exact_height(56.0)
            .frame(
                Frame::new()
                    .fill(p.panel)
                    .inner_margin(Margin::symmetric(16, 0)),
            )
            .show_separator_line(false)
            .show(ctx, |ui| {
                ui.horizontal_centered(|ui| {
                    ui.spacing_mut().item_spacing.x = Space::S;
                    ui::mascot(ui, 26.0, chaiky_egui::Mood::Happy);
                    let wide = self.width >= 1100.0;
                    ui.label(RichText::new("FreeDigi").font(bold(17.0)).color(p.text));
                    if wide {
                        ui::tag(ui, "PREVIEW", Tone::Neutral);
                    }
                    ui.add_space(if wide { Space::M } else { Space::XS });
                    self.device_switcher(
                        ui,
                        state,
                        if self.width >= 900.0 { 200.0 } else { 140.0 },
                    );
                    if wide && let Some(summary) = summary(state) {
                        ui.label(RichText::new(summary).size(Type::SMALL).color(p.text_2));
                    }
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        ui.add_enabled_ui(state.busy.is_empty(), |ui| {
                            if let Some(i) = ui::segmented(
                                ui,
                                if live { 1 } else { 0 },
                                &["Dry run", "Live"],
                                Some(1),
                            ) {
                                self.backend.send(Action::DryRun(i == 0));
                            }
                        })
                        .response
                        .on_hover_text(if live {
                            "Live: Save and Apply write to the controller."
                        } else {
                            "Dry run: actions are validated, nothing is written. Reads stay live."
                        });
                        ui.add_enabled_ui(state.busy.is_empty(), |ui| {
                            if ui::icon_button(ui, "🔄", "Find controllers and re-read this page")
                                .clicked()
                            {
                                self.backend.send(Action::Refresh);
                            }
                        });
                        let (mut text, tone, spinning, retry) = self.status(state);
                        if self.width < 900.0 && text == "Looking for a controller" {
                            text = "Searching".into();
                        }
                        let pill = ui::status_pill(ui, &text, tone, spinning, retry);
                        let pill = if retry
                            || !state.error.is_empty() && state.error_action == "monitor"
                        {
                            pill.on_hover_text(format!("{}\nClick to retry now.", state.error))
                        } else {
                            pill
                        };
                        if retry && pill.clicked() {
                            self.backend.send(Action::Refresh);
                        }
                    });
                });
                // Bottom edge: hairline, or a yellow rule while live writes are on.
                let rect = ui.max_rect();
                let edge = egui::Rect::from_min_max(
                    egui::pos2(
                        rect.left() - 16.0,
                        rect.bottom() - if live { 2.0 } else { 1.0 },
                    ),
                    egui::pos2(rect.right() + 16.0, rect.bottom()),
                );
                ui.painter()
                    .rect_filled(edge, 0, if live { p.live_fill } else { p.border });
            });
    }

    fn device_switcher(&mut self, ui: &mut egui::Ui, state: &State, width: f32) {
        let selected = state
            .devices
            .iter()
            .find(|d| d.path == state.path)
            .map(|d| d.name.clone())
            .unwrap_or_else(|| {
                if state.devices.is_empty() {
                    "No controller".into()
                } else {
                    "Choose controller".into()
                }
            });
        ui.add_enabled_ui(state.busy.is_empty() && !state.devices.is_empty(), |ui| {
            egui::ComboBox::from_id_salt("device")
                .width(width)
                .selected_text(RichText::new(format!("🎮  {selected}")).font(semibold(Type::BODY)))
                .show_ui(ui, |ui| {
                    for d in &state.devices {
                        let label = if d.accessible {
                            d.name.clone()
                        } else {
                            format!("{} · needs permission", d.name)
                        };
                        ui.add_enabled_ui(d.accessible, |ui| {
                            if ui.selectable_label(d.path == state.path, label).clicked() {
                                self.backend.send(Action::Select(d.path.clone()));
                            }
                        });
                    }
                });
        });
    }

    pub(crate) fn sidebar(&mut self, ctx: &egui::Context) {
        let p = self.tokens.p;
        let compact = self.width < 1000.0;
        egui::SidePanel::left("navigation")
            .exact_width(if compact { 60.0 } else { 212.0 })
            .resizable(false)
            .show_separator_line(false)
            .frame(
                Frame::new()
                    .fill(p.panel)
                    .inner_margin(Margin::symmetric(10, 14))
                    .stroke(Stroke::new(1.0_f32, p.border)),
            )
            .show(ctx, |ui| {
                ui.spacing_mut().item_spacing.y = 2.0;
                for (section, pages) in NAV {
                    ui.add_space(Space::XS);
                    if compact {
                        ui::divider(ui);
                    } else {
                        ui.horizontal(|ui| {
                            ui.add_space(10.0);
                            ui::section_label(ui, section);
                        });
                    }
                    ui.add_space(Space::XS);
                    for page in pages {
                        if ui::nav_item(ui, page.icon(), page.title(), self.page == *page, compact)
                            .clicked()
                        {
                            self.page = *page;
                        }
                    }
                    ui.add_space(Space::M);
                }
                ui.with_layout(Layout::bottom_up(Align::Min), |ui| {
                    ui.spacing_mut().item_spacing.y = Space::S;
                    if compact {
                        let dark = self.tokens.scheme == Scheme::Dark;
                        ui.vertical_centered(|ui| {
                            if ui::icon_button(
                                ui,
                                if dark { "☀" } else { "🌙" },
                                if dark { "Light theme" } else { "Dark theme" },
                            )
                            .clicked()
                            {
                                let scheme = if dark { Scheme::Light } else { Scheme::Dark };
                                self.set_scheme(ui.ctx(), scheme, self.tokens.reduced_motion);
                            }
                        });
                        if ui::nav_item(
                            ui,
                            Page::About.icon(),
                            Page::About.title(),
                            self.page == Page::About,
                            true,
                        )
                        .clicked()
                        {
                            self.page = Page::About;
                        }
                        ui::divider(ui);
                        return;
                    }
                    ui.horizontal(|ui| {
                        ui.add_space(10.0);
                        ui::hint(ui, "Built on ControlLab ♡");
                    });
                    ui.horizontal(|ui| {
                        ui.add_space(10.0);
                        let reduced = self.tokens.reduced_motion;
                        if ui::switch(ui, reduced, "Reduce motion").clicked() {
                            self.set_scheme(ui.ctx(), self.tokens.scheme, !reduced);
                        }
                        ui.label(
                            RichText::new("Reduce motion")
                                .size(Type::SMALL)
                                .color(p.text_2),
                        );
                    });
                    ui.horizontal(|ui| {
                        ui.add_space(10.0);
                        let current = if self.tokens.scheme == Scheme::Dark {
                            0
                        } else {
                            1
                        };
                        if let Some(i) = ui::segmented(ui, current, &["Dark", "Light"], None) {
                            let scheme = if i == 0 { Scheme::Dark } else { Scheme::Light };
                            self.set_scheme(ui.ctx(), scheme, self.tokens.reduced_motion);
                        }
                    });
                    ui.add_space(Space::XS);
                    if ui::nav_item(
                        ui,
                        Page::About.icon(),
                        Page::About.title(),
                        self.page == Page::About,
                        false,
                    )
                    .clicked()
                    {
                        self.page = Page::About;
                    }
                    ui::divider(ui);
                });
            });
    }

    pub(crate) fn changes_bar(&mut self, ctx: &egui::Context, state: &State) {
        let pending = match self.page {
            Page::Mapping => !self.staged.is_empty(),
            Page::Lighting => self.lighting_dirty,
            _ => false,
        };
        if !pending {
            return;
        }
        let p = self.tokens.p;
        egui::TopBottomPanel::bottom("changes")
            .exact_height(60.0)
            .show_separator_line(false)
            .frame(
                Frame::new()
                    .fill(p.raised)
                    .inner_margin(Margin::symmetric(if self.width < 1000.0 { 12 } else { 20 }, 0))
                    .stroke(Stroke::new(1.0_f32, p.border)),
            )
            .show(ctx, |ui| {
                ui.horizontal_centered(|ui| {
                    let (rect, _) = ui.allocate_exact_size(vec2(10.0, 10.0), egui::Sense::hover());
                    ui.painter().circle_filled(rect.center(), 4.0, p.accent);
                    let (title, detail) = match self.page {
                        Page::Mapping => (
                            format!(
                                "{} unsaved change{}",
                                self.staged.len(),
                                if self.staged.len() == 1 { "" } else { "s" }
                            ),
                            self.staged
                                .iter()
                                .take(4)
                                .map(|(s, t)| {
                                    format!("{} → {}", BUTTONS[s.parse::<usize>().unwrap_or(0)], BUTTONS[*t])
                                })
                                .collect::<Vec<_>>()
                                .join(", ")
                                + if self.staged.len() > 4 { ", …" } else { "" },
                        ),
                        _ => (
                            "Lighting changed".into(),
                            if self.off { "Lights off".into() } else { format!("{} · {}%", self.hex(), self.brightness) },
                        ),
                    };
                    ui.label(RichText::new(title).font(semibold(Type::BODY)).color(p.text));
                    if self.width >= 1150.0 {
                        ui.label(RichText::new(detail).size(Type::SMALL).color(p.text_2));
                    }
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        let ready = match self.page {
                            Page::Mapping => !state.data["snapshot"].is_null(),
                            _ => !state.data["lighting"].is_null(),
                        };
                        ui.add_enabled_ui(state.busy.is_empty() && ready, |ui| match self.page {
                            Page::Mapping => {
                                if ui::button(ui, Kind::Primary, "Save to controller")
                                    .on_hover_text("Writes to flash. A backup is taken and the result is read back. (⌘S)")
                                    .clicked()
                                {
                                    self.save_mapping(true);
                                }
                                if ui::button(ui, Kind::Secondary, "Apply until restart")
                                    .on_hover_text("Changes the active profile in RAM only.")
                                    .clicked()
                                {
                                    self.save_mapping(false);
                                }
                                if ui::button(ui, Kind::Ghost, "Discard").clicked() {
                                    self.staged.clear();
                                }
                            }
                            _ => {
                                if ui::button(ui, Kind::Primary, "Apply lighting").clicked() {
                                    self.apply_lighting();
                                }
                                if ui::button(ui, Kind::Ghost, "Discard").clicked() {
                                    self.reset_lighting();
                                }
                            }
                        });
                        ui.add_space(Space::S);
                        let long = self.width >= 1250.0;
                        if self.width < 860.0 {
                        } else if state.dry_run {
                            ui::tag(ui, if long { "DRY RUN · NOTHING IS WRITTEN" } else { "DRY RUN" }, Tone::Accent);
                        } else {
                            ui::tag(ui, if long { "LIVE · WRITES TO CONTROLLER" } else { "LIVE" }, Tone::Live);
                        }
                    });
                });
            });
    }

    pub(crate) fn content(&mut self, ctx: &egui::Context, state: &State) {
        let p = self.tokens.p;
        egui::CentralPanel::default()
            .frame(
                Frame::new()
                    .fill(p.bg)
                    .inner_margin(if self.width < 1000.0 {
                        Margin::symmetric(16, 14)
                    } else {
                        Margin::symmetric(28, 22)
                    }),
            )
            .show(ctx, |ui| {
                egui::ScrollArea::vertical()
                    .auto_shrink([false, false])
                    .show(ui, |ui| {
                        let width = ui.available_width().min(1160.0);
                        ui.set_max_width(width);
                        self.page_header(ui, state);
                        self.banners(ui, state);
                        match self.page {
                            Page::Live => self.live(ui, state),
                            Page::Mapping => self.mapping(ui, state),
                            Page::Lighting => self.lighting(ui, state),
                            Page::Features => self.features(ui, state),
                            Page::Firmware => self.firmware(ui, state),
                            Page::Diagnostics => self.diagnostics(ui, state),
                            Page::About => self.about(ui),
                        }
                        ui.add_space(Space::XL);
                    });
            });
    }

    fn page_header(&mut self, ui: &mut egui::Ui, state: &State) {
        let subtitle = match self.page {
            Page::Live => {
                "Press anything on your controller and watch it light up here.".to_owned()
            }
            Page::Mapping => match state.data["slot"].as_u64() {
                Some(slot) => format!(
                    "Profile {slot}{} · pick a button, then choose what it sends.",
                    state.data["title"]
                        .as_str()
                        .filter(|t| !t.is_empty() && ui::theme::can_render(ui.ctx(), t))
                        .map(|t| format!(" “{t}”"))
                        .unwrap_or_default()
                ),
                None => "Pick a button, then choose what it sends.".into(),
            },
            Page::Lighting => "A solid color and brightness for your controller's lights.".into(),
            Page::Features => "Hardware switches stored on the controller.".into(),
            Page::Firmware => "Versions reported by the controller and receiver.".into(),
            Page::Diagnostics => {
                "Recent operations, for bug reports. No controller packets are included.".into()
            }
            Page::About => "Independent community software for Flydigi controllers.".into(),
        };
        let title = self.page.title();
        ui::page_header(ui, title, &subtitle, |ui| match self.page {
            Page::Diagnostics => {
                if ui::button(ui, Kind::Secondary, "💾  Export report").clicked() {
                    let message = export_report(ui.ctx(), state);
                    self.toast(
                        if message.starts_with("Saved") {
                            Tone::Success
                        } else {
                            Tone::Danger
                        },
                        message,
                    );
                }
                if ui::button(ui, Kind::Secondary, "📋  Copy report").clicked() {
                    ui.ctx()
                        .copy_text(crate::diagnostic_report(ui.ctx(), state));
                    self.toast(Tone::Success, "Diagnostic report copied");
                }
            }
            Page::Firmware => {
                if ui::button(ui, Kind::Secondary, "📋  Copy versions").clicked() {
                    ui.ctx().copy_text(state.data["versions"].to_string());
                    self.toast(Tone::Success, "Firmware versions copied");
                }
            }
            Page::Mapping
                if !self.staged.is_empty()
                    && ui::button(ui, Kind::Ghost, "↩  Revert all").clicked() =>
            {
                self.staged.clear();
            }
            _ => {}
        });
    }

    /// Persistent, page-scoped messages in a fixed slot above the page body.
    fn banners(&mut self, ui: &mut egui::Ui, state: &State) {
        let mut shown = false;
        if !state.error.is_empty() {
            let owner = Page::of_action(&state.error_action);
            let global = state.error_action.is_empty() || state.error_action == "discovery";
            if global || owner == Some(self.page) {
                let title = match state.error_action.as_str() {
                    "" | "discovery" => "Something went wrong".to_owned(),
                    "monitor" => "Input stream didn't start — retrying automatically".to_owned(),
                    action => format!("{} didn't finish", backend::human(action)),
                };
                let action = if state.error_action == "monitor" {
                    "Retry now"
                } else {
                    "Read again"
                };
                if ui::banner(ui, Tone::Danger, &title, &state.error, Some(action)) {
                    self.backend.send(Action::Refresh);
                }
                shown = true;
            }
        }
        for read in self.page.reads() {
            if let Some(error) = state.setting_errors.get(*read) {
                if ui::banner(
                    ui,
                    Tone::Warning,
                    &format!("Couldn't sync — {}", backend::human(read).to_lowercase()),
                    &format!("{error} Retrying automatically."),
                    Some("Retry now"),
                ) {
                    self.backend.send(Action::Refresh);
                }
                shown = true;
            }
        }
        if shown {
            ui.add_space(Space::M);
        }
    }

    pub(crate) fn toasts(&mut self, ctx: &egui::Context) {
        let p = self.tokens.p;
        self.toasts.retain(|t| {
            t.at.elapsed() < Duration::from_secs(if t.tone == Tone::Danger { 8 } else { 4 })
        });
        if self.toasts.is_empty() {
            return;
        }
        ctx.request_repaint_after(Duration::from_millis(250));
        let bottom = if matches!(self.page, Page::Mapping | Page::Lighting) {
            76.0
        } else {
            16.0
        };
        let mut dismiss = None;
        egui::Area::new(egui::Id::new("toasts"))
            .anchor(Align2::RIGHT_BOTTOM, vec2(-16.0, -bottom))
            .order(egui::Order::Foreground)
            .show(ctx, |ui| {
                ui.spacing_mut().item_spacing.y = Space::S;
                for (i, toast) in self.toasts.iter().enumerate() {
                    let c = ui::tone_color(&self.tokens, toast.tone);
                    let response = Frame::new()
                        .fill(p.raised)
                        .stroke(Stroke::new(1.0_f32, ui::alpha(c, 0.6)))
                        .corner_radius(CornerRadius::same(Radius::CARD))
                        .inner_margin(Margin::symmetric(14, 10))
                        .shadow(ui.visuals().popup_shadow)
                        .show(ui, |ui| {
                            ui.set_max_width(360.0);
                            ui.horizontal(|ui| {
                                let (rect, _) =
                                    ui.allocate_exact_size(vec2(10.0, 10.0), egui::Sense::hover());
                                ui.painter().circle_filled(rect.center(), 4.0, c);
                                ui.add(
                                    egui::Label::new(RichText::new(&toast.text).color(p.text))
                                        .wrap(),
                                );
                            });
                        })
                        .response
                        .interact(egui::Sense::click());
                    if response.clicked() {
                        dismiss = Some(i);
                    }
                }
            });
        if let Some(i) = dismiss {
            self.toasts.remove(i);
        }
    }
}

fn summary(state: &State) -> Option<String> {
    if state.path.is_empty() {
        return None;
    }
    let mut parts = vec![];
    if let Some(slot) = state.data["slot"].as_u64() {
        parts.push(format!("Profile {slot}"));
    }
    if let Some(main) = state.data["versions"]["main"].as_str() {
        parts.push(format!("fw {main}"));
    }
    (!parts.is_empty()).then(|| parts.join(" · "))
}

fn export_report(ctx: &egui::Context, state: &State) -> String {
    let base = std::env::var_os("XDG_STATE_HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| {
            std::env::var_os("HOME")
                .map(std::path::PathBuf::from)
                .unwrap_or_else(std::env::temp_dir)
                .join(".local/state")
        });
    let directory = base.join("freedigi/diagnostics");
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let path = directory.join(format!("report-{stamp}.txt"));
    match std::fs::create_dir_all(&directory)
        .and_then(|_| std::fs::write(&path, crate::diagnostic_report(ctx, state)))
    {
        Ok(()) => format!("Saved {}", path.display()),
        Err(e) => format!("Export failed: {e}"),
    }
}
