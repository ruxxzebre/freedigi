//! Shared Chaiky native controls. Controller/network state belongs to the caller.
//! Assets are embedded: no runtime downloads or private registry needed.
#[allow(unused_imports)]
use egui::{Color32, CornerRadius, FontId, Margin, Response, RichText, Stroke, Ui, Vec2};
use std::sync::LazyLock;

pub const PALETTE_JSON: &str = include_str!("../palette.json");
static TOKENS: LazyLock<serde_json::Value> = LazyLock::new(|| {
    serde_json::from_str(PALETTE_JSON).expect("Chaiky palette must be valid JSON")
});

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scheme {
    Light,
    Dark,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tone {
    Neutral,
    Accent,
    Success,
    Warning,
    Danger,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mood {
    Resting,
    Happy,
    Working,
    Concerned,
}
#[derive(Clone, Copy, Debug)]
pub struct Theme {
    pub scheme: Scheme,
    pub reduced_motion: bool,
}
impl Default for Theme {
    fn default() -> Self {
        Self {
            scheme: Scheme::Light,
            reduced_motion: false,
        }
    }
}
impl Theme {
    pub fn color(self, name: &str) -> Color32 {
        let scheme = match self.scheme {
            Scheme::Light => "light",
            Scheme::Dark => "dark",
        };
        let hex = TOKENS[scheme][name].as_str().expect("unknown Chaiky token");
        Color32::from_hex(hex).expect("token is not a hex color")
    }
    pub fn tone(self, tone: Tone) -> Color32 {
        self.color(match tone {
            Tone::Neutral => "muted",
            Tone::Accent => "accent",
            Tone::Success => "success",
            Tone::Warning => "warning",
            Tone::Danger => "danger",
        })
    }
    /// Install once, then again when scheme or motion preference changes.
    pub fn install(self, ctx: &egui::Context) {
        let mut style = (*ctx.style()).clone();
        let mut v = match self.scheme {
            Scheme::Light => egui::Visuals::light(),
            Scheme::Dark => egui::Visuals::dark(),
        };
        v.override_text_color = Some(self.color("ink"));
        v.panel_fill = self.color("page");
        v.window_fill = self.color("surface");
        v.extreme_bg_color = self.color("surface");
        v.faint_bg_color = self.color("soft");
        v.selection.bg_fill = self.color("glow");
        v.selection.stroke = Stroke::new(1.0_f32, self.color("accent"));
        v.hyperlink_color = self.color("accent");
        for w in [
            &mut v.widgets.inactive,
            &mut v.widgets.hovered,
            &mut v.widgets.active,
            &mut v.widgets.open,
            &mut v.widgets.noninteractive,
        ] {
            w.corner_radius = CornerRadius::same(10);
            w.bg_fill = self.color("soft");
            w.weak_bg_fill = self.color("soft");
            w.bg_stroke = Stroke::new(1.0_f32, self.color("line"));
            w.fg_stroke = Stroke::new(1.0_f32, self.color("ink"));
        }
        v.widgets.hovered.bg_fill = self.color("glow");
        v.widgets.active.bg_fill = self.color("peach");
        v.window_corner_radius = CornerRadius::same(18);
        style.visuals = v;
        style.spacing.item_spacing = Vec2::new(10.0, 10.0);
        style.spacing.button_padding = Vec2::new(14.0, 9.0);
        style.spacing.interact_size.y = 36.0;
        style.animation_time = if self.reduced_motion { 0.0 } else { 0.12 };
        style
            .text_styles
            .insert(egui::TextStyle::Body, FontId::proportional(15.0));
        style
            .text_styles
            .insert(egui::TextStyle::Button, FontId::proportional(15.0));
        style
            .text_styles
            .insert(egui::TextStyle::Heading, FontId::proportional(25.0));
        ctx.set_style(style);
    }
}

#[cfg(feature = "badge")]
mod badge;
#[cfg(feature = "button")]
mod button;
#[cfg(feature = "card")]
mod card;
#[cfg(feature = "empty")]
mod empty;
#[cfg(feature = "mascot")]
mod mascot;
#[cfg(feature = "navigation")]
mod navigation;
#[cfg(feature = "status")]
mod status;
#[cfg(feature = "toggle")]
mod toggle;
