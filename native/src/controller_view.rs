//! A small vector controller view shared by monitoring and the mapping editor.
use crate::{BUTTONS, backend::Input};
use chaiky_egui::Theme;
use eframe::egui::{self, Align2, FontId, Rect, RichText, Sense, Stroke, Vec2};

pub fn controller(
    ui: &mut egui::Ui,
    theme: Theme,
    input: &Input,
    selected: Option<usize>,
) -> Option<usize> {
    let width = ui
        .available_width()
        .min(if selected.is_some() { 500.0 } else { 600.0 });
    let scale = width / 500.0;
    let (rect, _) = ui.allocate_exact_size(
        Vec2::new(ui.available_width(), 330.0 * scale),
        Sense::hover(),
    );
    let point = |x: f32, y: f32| {
        rect.min + Vec2::new((rect.width() - width) * 0.5, 0.0) + Vec2::new(x, y) * scale
    };
    let p = ui.painter();
    let outline = [
        (80., 52.),
        (160., 40.),
        (340., 40.),
        (420., 52.),
        (454., 115.),
        (476., 240.),
        (459., 272.),
        (426., 277.),
        (361., 225.),
        (139., 225.),
        (74., 277.),
        (41., 272.),
        (24., 240.),
        (46., 115.),
    ]
    .into_iter()
    .map(|(x, y)| point(x, y))
    .collect();
    p.add(egui::Shape::convex_polygon(
        outline,
        theme.color("soft"),
        Stroke::new(1.5_f32, theme.color("line")),
    ));
    p.text(
        point(250., 161.),
        Align2::CENTER_CENTER,
        "FreeDigi",
        FontId::proportional(16.0 * scale),
        theme.color("muted"),
    );
    let mut clicked = None;
    let controls = [
        (12, "LT", 106., 24., 64., 25.),
        (13, "RT", 394., 24., 64., 25.),
        (10, "LB", 106., 58., 64., 25.),
        (11, "RB", 394., 58., 64., 25.),
        (0, "↑", 151., 160., 30., 28.),
        (1, "→", 180., 188., 30., 28.),
        (2, "↓", 151., 216., 30., 28.),
        (3, "←", 122., 188., 30., 28.),
        (4, "A", 382., 155., 34., 34.),
        (5, "B", 417., 120., 34., 34.),
        (7, "X", 347., 120., 34., 34.),
        (8, "Y", 382., 85., 34., 34.),
        (6, "View", 218., 106., 44., 26.),
        (9, "Menu", 281., 106., 44., 26.),
        (16, "C", 379., 210., 30., 28.),
        (17, "Z", 417., 210., 30., 28.),
        (14, "L3", 103., 118., 52., 52.),
        (15, "R3", 306., 194., 52., 52.),
        (18, "M1", 176., 296., 46., 29.),
        (19, "M2", 229., 296., 46., 29.),
        (20, "M3", 282., 296., 46., 29.),
        (21, "M4", 335., 296., 46., 29.),
    ];
    for (id, label, x, y, w, h) in controls {
        let held = input.buttons.contains(&id);
        let bounds = Rect::from_center_size(point(x, y), Vec2::new(w, h) * scale);
        let fill = if held {
            theme.color("accent")
        } else if selected == Some(id) {
            theme.color("glow")
        } else {
            theme.color("surface")
        };
        let fg = if held {
            theme.color("on-accent")
        } else {
            theme.color("ink")
        };
        let response = ui.put(
            bounds,
            egui::Button::new(
                RichText::new(if id < 4 { "" } else { label })
                    .size(13.0 * scale)
                    .color(fg),
            )
            .wrap_mode(egui::TextWrapMode::Extend)
            .fill(fill)
            .corner_radius(if id == 14 || id == 15 || [4, 5, 7, 8].contains(&id) {
                30
            } else {
                8
            })
            .stroke(Stroke::new(
                if selected == Some(id) {
                    2.0_f32
                } else {
                    1.0_f32
                },
                theme.color(if selected == Some(id) {
                    "accent"
                } else {
                    "line"
                }),
            )),
        );
        if response.clicked() {
            clicked = Some(id);
        }
        response.on_hover_text(BUTTONS[id]);
        if id < 4 {
            let angle = id as f32 * std::f32::consts::FRAC_PI_2;
            let rotate = |dx: f32, dy: f32| {
                point(
                    dx * angle.cos() - dy * angle.sin() + x,
                    dx * angle.sin() + dy * angle.cos() + y,
                )
            };
            ui.painter().add(egui::Shape::convex_polygon(
                vec![rotate(0., -6.), rotate(6., 5.), rotate(-6., 5.)],
                fg,
                Stroke::NONE,
            ));
        }
        if id == 14 || id == 15 {
            let (sx, sy) = if id == 14 {
                (input.left_x, input.left_y)
            } else {
                (input.right_x, input.right_y)
            };
            let dot = point(x + sx.clamp(-1.0, 1.0) * 17., y - sy.clamp(-1.0, 1.0) * 17.);
            ui.painter().circle_stroke(
                dot,
                24.0 * scale,
                Stroke::new(2.0_f32, theme.color("accent").gamma_multiply(0.7)),
            );
        }
        if id == 12 || id == 13 {
            let amount = if id == 12 {
                input.left_trigger
            } else {
                input.right_trigger
            };
            let track = Rect::from_min_size(
                point(x - w / 2., y + h / 2. + 3.),
                Vec2::new(w * amount.clamp(0., 1.), 3.) * scale,
            );
            ui.painter().rect_filled(track, 2, theme.color("accent"));
        }
    }
    ui.painter().text(
        point(115., 296.),
        Align2::RIGHT_CENTER,
        "BACK",
        FontId::proportional(10.0 * scale),
        theme.color("muted"),
    );
    clicked
}

pub fn meter(ui: &mut egui::Ui, label: &str, value: f32, theme: Theme) {
    let (rect, _) = ui.allocate_exact_size(Vec2::new(155.0, 28.0), Sense::hover());
    let p = ui.painter();
    p.text(
        rect.left_center(),
        Align2::LEFT_CENTER,
        label,
        FontId::proportional(13.0),
        theme.color("muted"),
    );
    let track = Rect::from_min_size(rect.min + Vec2::new(25., 10.), Vec2::new(80., 8.));
    p.rect_filled(track, 4, theme.color("soft"));
    if value > 0. {
        p.rect_filled(
            Rect::from_min_size(
                track.min,
                Vec2::new(track.width() * value.clamp(0., 1.), track.height()),
            ),
            4,
            theme.color("accent"),
        );
    }
    p.text(
        rect.right_center(),
        Align2::RIGHT_CENTER,
        format!("{:.0}%", value * 100.),
        FontId::monospace(12.0),
        theme.color("muted"),
    );
}
