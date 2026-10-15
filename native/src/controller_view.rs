//! Vector controller diagram shared by Live input and Mapping. Paint-only with one
//! hit region per control; geometry is a fixed 500×372 design space scaled to fit.
use crate::{
    BUTTONS,
    backend::Input,
    ui::{Radius, Tokens, alpha, bold, semibold},
};
use eframe::egui::{
    self, Align2, Color32, CornerRadius, CursorIcon, Rect, Sense, Stroke, StrokeKind, Vec2, pos2,
    vec2,
};
use std::collections::BTreeMap;

/// Badge drawn on a control: the target it sends, and whether it is a pending edit.
pub struct Badge {
    pub text: String,
    pub pending: bool,
}

const DESIGN: Vec2 = vec2(500.0, 372.0);
pub const MAX_WIDTH: f32 = 540.0;

// (id, label, center x, center y, width, height, round)
const CONTROLS: [(usize, &str, f32, f32, f32, f32, bool); 22] = [
    (12, "LT", 120.0, 30.0, 74.0, 26.0, false),
    (13, "RT", 380.0, 30.0, 74.0, 26.0, false),
    (10, "LB", 128.0, 66.0, 82.0, 22.0, false),
    (11, "RB", 372.0, 66.0, 82.0, 22.0, false),
    (14, "L3", 122.0, 140.0, 54.0, 54.0, true),
    (0, "↑", 172.0, 176.0, 28.0, 28.0, false),
    (1, "→", 200.0, 204.0, 28.0, 28.0, false),
    (2, "↓", 172.0, 232.0, 28.0, 28.0, false),
    (3, "←", 144.0, 204.0, 28.0, 28.0, false),
    (6, "View", 216.0, 128.0, 46.0, 24.0, false),
    (9, "Menu", 284.0, 128.0, 46.0, 24.0, false),
    (8, "Y", 390.0, 116.0, 32.0, 32.0, true),
    (7, "X", 356.0, 150.0, 32.0, 32.0, true),
    (5, "B", 424.0, 150.0, 32.0, 32.0, true),
    (4, "A", 390.0, 184.0, 32.0, 32.0, true),
    (15, "R3", 314.0, 216.0, 54.0, 54.0, true),
    (16, "C", 378.0, 224.0, 30.0, 24.0, false),
    (17, "Z", 414.0, 224.0, 30.0, 24.0, false),
    (18, "M1", 420.0, 326.0, 44.0, 22.0, false),
    (19, "M2", 80.0, 326.0, 44.0, 22.0, false),
    (20, "M3", 388.0, 354.0, 44.0, 22.0, false),
    (21, "M4", 112.0, 354.0, 44.0, 22.0, false),
];

const OUTLINE: [(f32, f32); 14] = [
    (82.0, 84.0),
    (160.0, 74.0),
    (340.0, 74.0),
    (418.0, 84.0),
    (452.0, 146.0),
    (476.0, 258.0),
    (460.0, 288.0),
    (428.0, 292.0),
    (362.0, 252.0),
    (138.0, 252.0),
    (72.0, 292.0),
    (40.0, 288.0),
    (24.0, 258.0),
    (48.0, 146.0),
];

/// Returns the clicked control id.
pub fn controller(
    ui: &mut egui::Ui,
    input: &Input,
    selected: Option<usize>,
    badges: &BTreeMap<usize, Badge>,
) -> Option<usize> {
    let t = Tokens::get(ui.ctx());
    let p = t.p;
    let width = ui.available_width().min(MAX_WIDTH);
    let scale = width / DESIGN.x;
    let (area, _) =
        ui.allocate_exact_size(vec2(ui.available_width(), DESIGN.y * scale), Sense::hover());
    let origin = area.min + vec2((area.width() - width) * 0.5, 0.0);
    let point = |x: f32, y: f32| origin + vec2(x, y) * scale;
    let painter = ui.painter().clone();

    painter.add(egui::Shape::convex_polygon(
        OUTLINE.iter().map(|(x, y)| point(*x, *y)).collect(),
        p.raised,
        Stroke::new(1.5_f32, p.border_ctl),
    ));
    // Back paddles sit behind the grips: M2 over M4 on the left, M1 over M3 on the right.
    for x in [96.0, 404.0] {
        painter.text(
            point(x, 304.0),
            Align2::CENTER_CENTER,
            "BACK",
            bold(9.0 * scale.max(0.8)),
            p.text_3,
        );
    }

    let mut clicked = None;
    for (id, label, x, y, w, h, round) in CONTROLS {
        let rect = Rect::from_center_size(point(x, y), vec2(w, h) * scale);
        let response = ui
            .interact(
                rect,
                ui.id().with(("controller-button", id)),
                Sense::click(),
            )
            .on_hover_cursor(CursorIcon::PointingHand)
            .on_hover_text(BUTTONS[id]);
        let held = input.buttons.contains(&id);
        let is_selected = selected == Some(id);
        let hovered = response.hovered();
        let (fill, stroke, fg) = if held {
            (p.accent, Stroke::new(1.0_f32, p.accent), p.on_accent)
        } else if is_selected {
            (p.accent_dim, Stroke::new(2.0_f32, p.accent), p.text)
        } else if hovered {
            (
                p.control_hover,
                Stroke::new(1.0_f32, p.border_strong),
                p.text,
            )
        } else {
            (p.control, Stroke::new(1.0_f32, p.border_ctl), p.text)
        };
        let radius = if round {
            CornerRadius::same(Radius::PILL)
        } else {
            CornerRadius::same(Radius::CONTROL)
        };
        painter.rect(rect, radius, fill, stroke, StrokeKind::Inside);
        if held && !t.reduced_motion {
            painter.rect_stroke(
                rect.expand(3.0),
                radius,
                Stroke::new(3.0_f32, alpha(p.accent, 0.3)),
                StrokeKind::Outside,
            );
        }
        if id == 12 || id == 13 {
            let amount = if id == 12 {
                input.left_trigger
            } else {
                input.right_trigger
            }
            .clamp(0.0, 1.0);
            if amount > 0.0 {
                let fillrect =
                    Rect::from_min_size(rect.min, vec2(rect.width() * amount, rect.height()))
                        .shrink(2.0);
                painter.rect_filled(
                    fillrect,
                    CornerRadius::same(Radius::CONTROL - 2),
                    alpha(p.accent, 0.45),
                );
            }
        }
        if id == 14 || id == 15 {
            // Stick position as a cap ring, drawn under the label so text stays readable.
            let (sx, sy) = if id == 14 {
                (input.left_x, input.left_y)
            } else {
                (input.right_x, input.right_y)
            };
            let cap =
                rect.center() + vec2(sx.clamp(-1.0, 1.0), -sy.clamp(-1.0, 1.0)) * 12.0 * scale;
            painter.circle_stroke(
                cap,
                13.0 * scale,
                Stroke::new(2.0_f32, if held { p.on_accent } else { p.accent }),
            );
        }
        if id < 4 {
            let angle = [
                -std::f32::consts::FRAC_PI_2,
                0.0,
                std::f32::consts::FRAC_PI_2,
                std::f32::consts::PI,
            ][id];
            let c = rect.center();
            let r = 6.0 * scale;
            let tri =
                [0.0_f32, 2.3, -2.3].map(|a| c + vec2((angle + a).cos(), (angle + a).sin()) * r);
            painter.add(egui::Shape::convex_polygon(tri.to_vec(), fg, Stroke::NONE));
        } else {
            painter.text(
                rect.center(),
                Align2::CENTER_CENTER,
                label,
                semibold(12.5 * scale.max(0.8)),
                fg,
            );
        }
        if let Some(badge) = badges.get(&id) {
            draw_badge(
                &painter,
                &t,
                rect.right_bottom() + vec2(-2.0, -2.0),
                &badge.text,
                badge.pending,
                scale,
            );
        }
        crate::ui::focus_ring(
            ui,
            &response,
            rect,
            if round { Radius::PILL } else { Radius::CONTROL },
        );
        if response.clicked() {
            clicked = Some(id);
        }
    }
    clicked
}

fn draw_badge(
    painter: &egui::Painter,
    t: &Tokens,
    anchor: egui::Pos2,
    text: &str,
    pending: bool,
    scale: f32,
) {
    let p = t.p;
    let galley = painter.layout_no_wrap(
        text.to_owned(),
        bold(9.5 * scale.max(0.85)),
        Color32::PLACEHOLDER,
    );
    let size = vec2(galley.size().x + 8.0, galley.size().y + 2.0);
    let rect = Rect::from_center_size(anchor, size);
    let (fill, stroke, fg) = if pending {
        (p.accent, Stroke::new(1.0_f32, p.bg), p.on_accent)
    } else {
        (
            p.control_pressed,
            Stroke::new(1.0_f32, p.border_ctl),
            p.text,
        )
    };
    painter.rect(
        rect,
        CornerRadius::same(Radius::PILL),
        fill,
        stroke,
        StrokeKind::Outside,
    );
    painter.galley(
        pos2(
            rect.center().x - galley.size().x / 2.0,
            rect.center().y - galley.size().y / 2.0,
        ),
        galley,
        fg,
    );
}
