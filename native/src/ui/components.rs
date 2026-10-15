//! Self-painted controls. Each one derives fill/border from its own interaction
//! state, so hover, press and focus are always visible (egui's `Button::fill`
//! freezes the fill for every state, which hid feedback in the previous UI).
use super::theme::{CONTROL_H, CONTROL_H_SM, Radius, Space, Tokens, Type, bold, semibold};
use eframe::egui::{
    self, Align, Align2, Color32, CornerRadius, CursorIcon, FontId, Frame, Layout, Rect, Response,
    RichText, Sense, Stroke, StrokeKind, Ui, Vec2, WidgetInfo, WidgetType, pos2, vec2,
};

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Primary,
    Secondary,
    Ghost,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Tone {
    Neutral,
    Accent,
    Success,
    Warning,
    Danger,
    Info,
    Live,
}

pub fn tone_color(t: &Tokens, tone: Tone) -> Color32 {
    let p = t.p;
    match tone {
        Tone::Neutral => p.text_2,
        Tone::Accent => p.accent,
        Tone::Success => p.success,
        Tone::Warning => p.warning,
        Tone::Danger => p.danger,
        Tone::Info => p.info,
        Tone::Live => p.live,
    }
}

pub fn mix(a: Color32, b: Color32, t: f32) -> Color32 {
    let l = |x: u8, y: u8| (x as f32 + (y as f32 - x as f32) * t).round() as u8;
    Color32::from_rgba_unmultiplied(
        l(a.r(), b.r()),
        l(a.g(), b.g()),
        l(a.b(), b.b()),
        l(a.a(), b.a()),
    )
}

pub fn alpha(c: Color32, a: f32) -> Color32 {
    Color32::from_rgba_unmultiplied(c.r(), c.g(), c.b(), (a * 255.0) as u8)
}

fn dim(c: Color32, enabled: bool) -> Color32 {
    if enabled { c } else { c.gamma_multiply(0.4) }
}

pub fn focus_ring(ui: &Ui, response: &Response, rect: Rect, radius: u8) {
    if response.has_focus() {
        let t = Tokens::get(ui.ctx());
        ui.painter().rect_stroke(
            rect.expand(2.0),
            CornerRadius::same(radius.saturating_add(2)),
            Stroke::new(2.0_f32, t.p.accent),
            StrokeKind::Outside,
        );
    }
}

struct Look {
    fill: Color32,
    border: Color32,
    text: Color32,
}

fn look(t: &Tokens, kind: Kind, hovered: bool, pressed: bool) -> Look {
    let p = t.p;
    let toward = if t.scheme == super::theme::Scheme::Dark {
        Color32::WHITE
    } else {
        Color32::BLACK
    };
    match kind {
        Kind::Primary => {
            let fill = if pressed {
                mix(p.accent, Color32::BLACK, 0.14)
            } else if hovered {
                mix(p.accent, toward, 0.12)
            } else {
                p.accent
            };
            Look {
                fill,
                border: fill,
                text: p.on_accent,
            }
        }
        Kind::Secondary => Look {
            fill: if pressed {
                p.control_pressed
            } else if hovered {
                p.control_hover
            } else {
                p.control
            },
            border: if pressed {
                p.accent
            } else if hovered {
                p.border_strong
            } else {
                p.border_ctl
            },
            text: p.text,
        },
        Kind::Ghost => Look {
            fill: if pressed {
                p.control_pressed
            } else if hovered {
                p.control_hover
            } else {
                Color32::TRANSPARENT
            },
            border: if hovered || pressed {
                p.border_ctl
            } else {
                Color32::TRANSPARENT
            },
            text: if hovered || pressed { p.text } else { p.text_2 },
        },
    }
}

fn paint_button(ui: &mut Ui, kind: Kind, label: &str, height: f32, font: FontId) -> Response {
    let t = Tokens::get(ui.ctx());
    let galley = ui
        .painter()
        .layout_no_wrap(label.to_owned(), font, Color32::PLACEHOLDER);
    let pad = if height < CONTROL_H {
        Space::S + 2.0
    } else {
        Space::M + 2.0
    };
    let size = vec2((galley.size().x + pad * 2.0).max(height), height);
    let (rect, response) = ui.allocate_exact_size(size, Sense::click());
    let enabled = ui.is_enabled();
    if ui.is_rect_visible(rect) {
        let l = look(
            &t,
            kind,
            enabled && response.hovered(),
            enabled && response.is_pointer_button_down_on(),
        );
        ui.painter().rect(
            rect,
            CornerRadius::same(Radius::CONTROL),
            dim(l.fill, enabled),
            Stroke::new(1.0_f32, dim(l.border, enabled)),
            StrokeKind::Inside,
        );
        ui.painter().galley(
            rect.center() - galley.size() / 2.0,
            galley,
            dim(l.text, enabled),
        );
        focus_ring(ui, &response, rect, Radius::CONTROL);
    }
    response.widget_info(|| WidgetInfo::labeled(WidgetType::Button, enabled, label));
    if enabled {
        response.on_hover_cursor(CursorIcon::PointingHand)
    } else {
        response
    }
}

pub fn button(ui: &mut Ui, kind: Kind, label: &str) -> Response {
    paint_button(ui, kind, label, CONTROL_H, semibold(Type::BODY))
}
pub fn small_button(ui: &mut Ui, kind: Kind, label: &str) -> Response {
    paint_button(ui, kind, label, CONTROL_H_SM, semibold(Type::SMALL))
}
/// Square ghost button for a single glyph.
pub fn icon_button(ui: &mut Ui, icon: &str, tooltip: &str) -> Response {
    paint_button(ui, Kind::Ghost, icon, CONTROL_H, FontId::proportional(15.0))
        .on_hover_text(tooltip)
}

/// Toggle chip for pick lists (mapping targets, presets).
pub fn chip(ui: &mut Ui, label: &str, selected: bool, min_width: f32) -> Response {
    let t = Tokens::get(ui.ctx());
    let p = t.p;
    let galley = ui.painter().layout_no_wrap(
        label.to_owned(),
        semibold(Type::SMALL),
        Color32::PLACEHOLDER,
    );
    let size = vec2((galley.size().x + 20.0).max(min_width), 28.0);
    let (rect, response) = ui.allocate_exact_size(size, Sense::click());
    let enabled = ui.is_enabled();
    let hovered = enabled && response.hovered();
    let (fill, border, text) = if selected {
        (p.accent_dim, p.accent, p.accent)
    } else if hovered {
        (p.control_hover, p.border_strong, p.text)
    } else {
        (p.control, p.border_ctl, p.text)
    };
    ui.painter().rect(
        rect,
        CornerRadius::same(Radius::CONTROL),
        dim(fill, enabled),
        Stroke::new(if selected { 1.5_f32 } else { 1.0 }, dim(border, enabled)),
        StrokeKind::Inside,
    );
    ui.painter().galley(
        rect.center() - galley.size() / 2.0,
        galley,
        dim(text, enabled),
    );
    focus_ring(ui, &response, rect, Radius::CONTROL);
    response.widget_info(|| {
        WidgetInfo::selected(WidgetType::SelectableLabel, enabled, selected, label)
    });
    if enabled {
        response.on_hover_cursor(CursorIcon::PointingHand)
    } else {
        response
    }
}

/// On/off switch with a real track and thumb. Returns the response; caller toggles.
pub fn switch(ui: &mut Ui, on: bool, label: &str) -> Response {
    let t = Tokens::get(ui.ctx());
    let p = t.p;
    let (rect, response) = ui.allocate_exact_size(vec2(40.0, 22.0), Sense::click());
    let enabled = ui.is_enabled();
    let k =
        ui.ctx()
            .animate_bool_with_time(response.id, on, if t.reduced_motion { 0.0 } else { 0.12 });
    let hovered = enabled && response.hovered();
    let track = mix(
        if hovered { p.control_hover } else { p.control },
        p.accent,
        k,
    );
    let border = mix(
        if hovered {
            p.border_strong
        } else {
            p.border_ctl
        },
        p.accent,
        k,
    );
    ui.painter().rect(
        rect,
        CornerRadius::same(Radius::PILL),
        dim(track, enabled),
        Stroke::new(1.0_f32, dim(border, enabled)),
        StrokeKind::Inside,
    );
    let x = egui::lerp((rect.left() + 11.0)..=(rect.right() - 11.0), k);
    ui.painter().circle_filled(
        egui::pos2(x, rect.center().y),
        7.5,
        dim(mix(p.text_2, Color32::WHITE, k), enabled),
    );
    focus_ring(ui, &response, rect, Radius::PILL);
    response.widget_info(|| WidgetInfo::selected(WidgetType::Checkbox, enabled, on, label));
    if enabled {
        response.on_hover_cursor(CursorIcon::PointingHand)
    } else {
        response
    }
}

/// Segmented control. `live` marks an option that is painted in the live-write colour.
pub fn segmented(
    ui: &mut Ui,
    selected: usize,
    options: &[&str],
    live: Option<usize>,
) -> Option<usize> {
    let t = Tokens::get(ui.ctx());
    let p = t.p;
    let enabled = ui.is_enabled();
    let font = semibold(Type::SMALL);
    let galleys: Vec<_> = options
        .iter()
        .map(|o| {
            ui.painter()
                .layout_no_wrap((*o).to_owned(), font.clone(), Color32::PLACEHOLDER)
        })
        .collect();
    let widths: Vec<f32> = galleys.iter().map(|g| g.size().x + 24.0).collect();
    let (outer, _) = ui.allocate_exact_size(
        vec2(widths.iter().sum::<f32>() + 4.0, CONTROL_H_SM + 4.0),
        Sense::hover(),
    );
    ui.painter().rect(
        outer,
        CornerRadius::same(Radius::CONTROL + 1),
        p.control,
        Stroke::new(1.0_f32, dim(p.border_ctl, enabled)),
        StrokeKind::Inside,
    );
    let mut x = outer.left() + 2.0;
    let mut clicked = None;
    for (i, (galley, w)) in galleys.into_iter().zip(widths).enumerate() {
        let rect = Rect::from_min_size(egui::pos2(x, outer.top() + 2.0), vec2(w, CONTROL_H_SM));
        x += w;
        let response = ui.interact(rect, ui.id().with(("segment", options[i])), Sense::click());
        let on = i == selected;
        let hovered = enabled && response.hovered() && !on;
        let (fill, text) = if on && live == Some(i) {
            (p.live_fill, p.on_live)
        } else if on {
            (p.raised, p.text)
        } else if hovered {
            (p.control_hover, p.text)
        } else {
            (Color32::TRANSPARENT, p.text_2)
        };
        ui.painter().rect(
            rect,
            CornerRadius::same(Radius::CONTROL - 1),
            dim(fill, enabled),
            if on && live != Some(i) {
                Stroke::new(1.0_f32, p.border_ctl)
            } else {
                Stroke::NONE
            },
            StrokeKind::Inside,
        );
        ui.painter().galley(
            rect.center() - galley.size() / 2.0,
            galley,
            dim(text, enabled),
        );
        focus_ring(ui, &response, rect, Radius::CONTROL);
        if response.clicked() && !on {
            clicked = Some(i);
        }
        if enabled {
            response.on_hover_cursor(CursorIcon::PointingHand);
        }
    }
    clicked
}

/// Small non-interactive pill.
pub fn tag(ui: &mut Ui, text: &str, tone: Tone) -> Response {
    let t = Tokens::get(ui.ctx());
    let c = tone_color(&t, tone);
    let galley = ui
        .painter()
        .layout_no_wrap(text.to_owned(), semibold(Type::CAPTION), c);
    let (rect, response) =
        ui.allocate_exact_size(vec2(galley.size().x + 16.0, 20.0), Sense::hover());
    let (fill, text_color) = if tone == Tone::Live {
        (t.p.live_fill, t.p.on_live)
    } else {
        (alpha(c, 0.14), c)
    };
    ui.painter()
        .rect_filled(rect, CornerRadius::same(Radius::PILL), fill);
    ui.painter()
        .galley(rect.center() - galley.size() / 2.0, galley, text_color);
    response
}

/// Header status: dot (or spinner) and label. Clickable for retry when `clickable`.
pub fn status_pill(
    ui: &mut Ui,
    text: &str,
    tone: Tone,
    spinning: bool,
    clickable: bool,
) -> Response {
    let t = Tokens::get(ui.ctx());
    let c = tone_color(&t, tone);
    let galley = ui
        .painter()
        .layout_no_wrap(text.to_owned(), semibold(Type::SMALL), t.p.text);
    let size = vec2(galley.size().x + 38.0, 28.0);
    let (rect, response) = ui.allocate_exact_size(
        size,
        if clickable {
            Sense::click()
        } else {
            Sense::hover()
        },
    );
    let hovered = clickable && response.hovered();
    ui.painter().rect(
        rect,
        CornerRadius::same(Radius::PILL),
        if hovered {
            t.p.control_hover
        } else {
            alpha(c, 0.10)
        },
        Stroke::new(1.0_f32, alpha(c, 0.55)),
        StrokeKind::Inside,
    );
    let dot = egui::pos2(rect.left() + 15.0, rect.center().y);
    if spinning && !t.reduced_motion {
        egui::Spinner::new()
            .size(12.0)
            .color(c)
            .paint_at(ui, Rect::from_center_size(dot, Vec2::splat(12.0)));
    } else {
        ui.painter().circle_filled(dot, 4.0, c);
    }
    ui.painter().galley(
        egui::pos2(rect.left() + 27.0, rect.center().y - galley.size().y / 2.0),
        galley,
        t.p.text,
    );
    focus_ring(ui, &response, rect, Radius::PILL);
    if clickable {
        response.on_hover_cursor(CursorIcon::PointingHand)
    } else {
        response
    }
}

pub fn card<R>(ui: &mut Ui, add: impl FnOnce(&mut Ui) -> R) -> R {
    let t = Tokens::get(ui.ctx());
    Frame::new()
        .fill(t.p.panel)
        .stroke(Stroke::new(1.0_f32, t.p.border))
        .corner_radius(CornerRadius::same(Radius::CARD))
        .inner_margin(Space::L)
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            add(ui)
        })
        .inner
}

/// Card title on the left, optional actions right-aligned.
pub fn card_header(ui: &mut Ui, title: &str, actions: impl FnOnce(&mut Ui)) {
    let t = Tokens::get(ui.ctx());
    ui.horizontal(|ui| {
        ui.label(
            RichText::new(title)
                .font(semibold(Type::TITLE))
                .color(t.p.text),
        );
        ui.with_layout(Layout::right_to_left(Align::Center), actions);
    });
    ui.add_space(Space::XS);
}

pub fn section_label(ui: &mut Ui, text: &str) {
    let t = Tokens::get(ui.ctx());
    ui.label(
        RichText::new(text.to_uppercase())
            .font(bold(Type::CAPTION))
            .color(t.p.text_3),
    );
}

pub fn muted(ui: &mut Ui, text: &str) -> Response {
    let t = Tokens::get(ui.ctx());
    ui.add(egui::Label::new(RichText::new(text).color(t.p.text_2)).wrap())
}

pub fn hint(ui: &mut Ui, text: &str) -> Response {
    let t = Tokens::get(ui.ctx());
    ui.add(egui::Label::new(RichText::new(text).size(Type::SMALL).color(t.p.text_3)).wrap())
}

pub fn divider(ui: &mut Ui) {
    let t = Tokens::get(ui.ctx());
    let (rect, _) = ui.allocate_exact_size(vec2(ui.available_width(), 1.0), Sense::hover());
    ui.painter().rect_filled(rect, 0, t.p.border);
}

/// Label + help on the left, control right-aligned. The text is measured first so
/// both sides center on the same row, whatever the number of help lines.
pub fn form_row(ui: &mut Ui, label: &str, help: &str, control: impl FnOnce(&mut Ui)) {
    let t = Tokens::get(ui.ctx());
    let width = ui.available_width();
    let text_width = (width - 200.0).max(200.0);
    let painter = ui.painter();
    let title = painter.layout_no_wrap(label.to_owned(), semibold(Type::BODY), t.p.text);
    let help = (!help.is_empty()).then(|| {
        painter.layout(
            help.to_owned(),
            FontId::proportional(Type::SMALL),
            t.p.text_2,
            text_width,
        )
    });
    let text_height = title.size().y + help.as_ref().map_or(0.0, |g| 2.0 + g.size().y);
    let (rect, _) = ui.allocate_exact_size(
        vec2(width, text_height.max(CONTROL_H) + 2.0 * Space::S),
        Sense::hover(),
    );
    let mut y = rect.center().y - text_height / 2.0;
    let title_height = title.size().y;
    ui.painter().galley(pos2(rect.left(), y), title, t.p.text);
    if let Some(help) = help {
        y += title_height + 2.0;
        ui.painter().galley(pos2(rect.left(), y), help, t.p.text_2);
    }
    let control_rect = Rect::from_min_max(pos2(rect.left() + text_width, rect.top()), rect.max);
    ui.scope_builder(
        egui::UiBuilder::new()
            .max_rect(control_rect)
            .layout(Layout::right_to_left(Align::Center)),
        control,
    );
}

pub fn page_header(ui: &mut Ui, title: &str, subtitle: &str, actions: impl FnOnce(&mut Ui)) {
    let t = Tokens::get(ui.ctx());
    ui.horizontal(|ui| {
        ui.vertical(|ui| {
            ui.spacing_mut().item_spacing.y = 2.0;
            ui.label(RichText::new(title).font(bold(Type::PAGE)).color(t.p.text));
            ui.label(RichText::new(subtitle).color(t.p.text_2));
        });
        ui.with_layout(Layout::right_to_left(Align::Center), actions);
    });
    ui.add_space(Space::M);
}

/// Inline, persistent message with an optional action. Returns true when the action is clicked.
pub fn banner(ui: &mut Ui, tone: Tone, title: &str, detail: &str, action: Option<&str>) -> bool {
    let t = Tokens::get(ui.ctx());
    let c = tone_color(&t, tone);
    let mut clicked = false;
    Frame::new()
        .fill(alpha(c, 0.09))
        .stroke(Stroke::new(1.0_f32, alpha(c, 0.5)))
        .corner_radius(CornerRadius::same(Radius::CONTROL + 2))
        .inner_margin(Space::M)
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.horizontal(|ui| {
                let (rect, _) = ui.allocate_exact_size(Vec2::splat(20.0), Sense::hover());
                ui.painter().circle_filled(rect.center(), 9.0, c);
                ui.painter().text(
                    rect.center(),
                    Align2::CENTER_CENTER,
                    match tone {
                        Tone::Success => "✔",
                        Tone::Info | Tone::Accent | Tone::Neutral => "i",
                        _ => "!",
                    },
                    bold(12.0),
                    t.p.bg,
                );
                let width =
                    (ui.available_width() - if action.is_some() { 120.0 } else { 0.0 }).max(120.0);
                ui.allocate_ui_with_layout(vec2(width, 0.0), Layout::top_down(Align::Min), |ui| {
                    ui.spacing_mut().item_spacing.y = 2.0;
                    ui.label(
                        RichText::new(title)
                            .font(semibold(Type::BODY))
                            .color(t.p.text),
                    );
                    if !detail.is_empty() {
                        ui.add(
                            egui::Label::new(
                                RichText::new(detail).size(Type::SMALL).color(t.p.text_2),
                            )
                            .wrap(),
                        );
                    }
                });
                if let Some(action) = action {
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        clicked = small_button(ui, Kind::Secondary, action).clicked();
                    });
                }
            });
        });
    clicked
}

/// Friendly empty state with the gull.
pub fn empty_state(ui: &mut Ui, mood: chaiky_egui::Mood, title: &str, detail: &str) {
    let t = Tokens::get(ui.ctx());
    ui.vertical_centered(|ui| {
        ui.add_space(Space::XL * 2.0);
        mascot(ui, 84.0, mood);
        ui.add_space(Space::M);
        ui.label(RichText::new(title).font(bold(19.0)).color(t.p.text));
        ui.add_space(Space::XS);
        ui.label(RichText::new(detail).color(t.p.text_2));
        ui.add_space(Space::XL);
    });
}

pub fn mascot(ui: &mut Ui, size: f32, mood: chaiky_egui::Mood) -> Response {
    let t = Tokens::get(ui.ctx());
    chaiky_egui::Theme {
        scheme: match t.scheme {
            super::theme::Scheme::Dark => chaiky_egui::Scheme::Dark,
            super::theme::Scheme::Light => chaiky_egui::Scheme::Light,
        },
        reduced_motion: t.reduced_motion,
    }
    .mascot(ui, size, mood)
}

/// Sidebar row: icon + left-aligned label; selected rows get a soft fill and accent bar.
/// `compact` draws an icon-only rail item; the label moves to the tooltip.
pub fn nav_item(ui: &mut Ui, icon: &str, label: &str, selected: bool, compact: bool) -> Response {
    let t = Tokens::get(ui.ctx());
    let p = t.p;
    let (rect, response) = ui.allocate_exact_size(vec2(ui.available_width(), 34.0), Sense::click());
    let hovered = response.hovered();
    let fill = if selected {
        p.accent_dim
    } else if hovered {
        p.control
    } else {
        Color32::TRANSPARENT
    };
    ui.painter()
        .rect_filled(rect, CornerRadius::same(Radius::CONTROL), fill);
    if selected {
        ui.painter().rect_filled(
            Rect::from_min_size(
                rect.left_top() + vec2(0.0, 8.0),
                vec2(3.0, rect.height() - 16.0),
            ),
            CornerRadius::same(2),
            p.accent,
        );
    }
    let fg = if selected || hovered {
        p.text
    } else {
        p.text_2
    };
    let icon_x = if compact {
        rect.center().x
    } else {
        rect.left() + 20.0
    };
    ui.painter().text(
        egui::pos2(icon_x, rect.center().y),
        Align2::CENTER_CENTER,
        icon,
        FontId::proportional(if compact { 16.0 } else { 14.0 }),
        if selected { p.accent } else { fg },
    );
    if compact {
        focus_ring(ui, &response, rect, Radius::CONTROL);
        return response
            .on_hover_text(label)
            .on_hover_cursor(CursorIcon::PointingHand);
    }
    ui.painter().text(
        egui::pos2(rect.left() + 36.0, rect.center().y),
        Align2::LEFT_CENTER,
        label,
        if selected {
            semibold(Type::BODY)
        } else {
            FontId::proportional(Type::BODY)
        },
        fg,
    );
    focus_ring(ui, &response, rect, Radius::CONTROL);
    response
        .widget_info(|| WidgetInfo::selected(WidgetType::SelectableLabel, true, selected, label));
    response.on_hover_cursor(CursorIcon::PointingHand)
}

/// Horizontal level bar (triggers, brightness preview).
pub fn level_bar(ui: &mut Ui, label: &str, value: f32, width: f32) {
    let t = Tokens::get(ui.ctx());
    let p = t.p;
    ui.horizontal(|ui| {
        ui.add_sized(
            [28.0, 18.0],
            egui::Label::new(
                RichText::new(label)
                    .font(semibold(Type::SMALL))
                    .color(p.text_2),
            ),
        );
        let (rect, _) = ui.allocate_exact_size(vec2(width, 8.0), Sense::hover());
        ui.painter()
            .rect_filled(rect, CornerRadius::same(Radius::PILL), p.control);
        let v = value.clamp(0.0, 1.0);
        if v > 0.0 {
            ui.painter().rect_filled(
                Rect::from_min_size(rect.min, vec2(rect.width() * v, rect.height())),
                CornerRadius::same(Radius::PILL),
                p.accent,
            );
        }
        ui.label(
            RichText::new(format!("{:>3.0}%", v * 100.0))
                .monospace()
                .color(p.text_2),
        );
    });
}

/// XY pad for an analog stick.
pub fn stick_pad(ui: &mut Ui, label: &str, x: f32, y: f32) {
    let t = Tokens::get(ui.ctx());
    let p = t.p;
    ui.vertical(|ui| {
        ui.spacing_mut().item_spacing.y = 4.0;
        let (rect, _) = ui.allocate_exact_size(Vec2::splat(96.0), Sense::hover());
        let painter = ui.painter();
        painter.rect(
            rect,
            CornerRadius::same(Radius::CARD),
            p.control,
            Stroke::new(1.0_f32, p.border),
            StrokeKind::Inside,
        );
        painter.line_segment(
            [rect.center_top(), rect.center_bottom()],
            Stroke::new(1.0_f32, p.border),
        );
        painter.line_segment(
            [rect.left_center(), rect.right_center()],
            Stroke::new(1.0_f32, p.border),
        );
        painter.circle_stroke(rect.center(), 40.0, Stroke::new(1.0_f32, p.border));
        let dot = rect.center() + vec2(x.clamp(-1.0, 1.0), -y.clamp(-1.0, 1.0)) * 38.0;
        painter.circle_filled(dot, 6.0, p.accent);
        ui.label(
            // Round first and add +0.0 so tiny negatives never print as "-0.00".
            RichText::new({
                let show = |v: f32| (v * 100.0).round() / 100.0 + 0.0;
                format!("{label}  {:+.2} {:+.2}", show(x), show(y))
            })
            .monospace()
            .size(Type::SMALL)
            .color(p.text_2),
        );
    });
}
