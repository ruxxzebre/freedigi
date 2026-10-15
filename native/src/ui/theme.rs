//! App-local design tokens ("Console", soft edition) mapped onto egui's Style.
//! Vendored Chaiky code stays untouched; only its gull is used, on About and empty states.
use eframe::egui::{
    self, Color32, CornerRadius, FontFamily, FontId, Id, Margin, Shadow, Stroke, TextStyle,
    style::{Selection, WidgetVisuals, Widgets},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scheme {
    Dark,
    Light,
}

#[derive(Clone, Copy, Debug)]
pub struct Palette {
    pub bg: Color32,
    pub panel: Color32,
    pub raised: Color32,
    pub control: Color32,
    pub control_hover: Color32,
    pub control_pressed: Color32,
    pub border: Color32,
    pub border_ctl: Color32,
    pub border_strong: Color32,
    pub text: Color32,
    pub text_2: Color32,
    pub text_3: Color32,
    pub accent: Color32,
    pub on_accent: Color32,
    pub accent_dim: Color32,
    /// Live controller writes. Text/strokes use `live`; filled chips use `live_fill`.
    pub live: Color32,
    pub live_fill: Color32,
    pub on_live: Color32,
    pub success: Color32,
    pub warning: Color32,
    pub danger: Color32,
    pub info: Color32,
}

pub struct Space;
impl Space {
    pub const XS: f32 = 4.0;
    pub const S: f32 = 8.0;
    pub const M: f32 = 12.0;
    pub const L: f32 = 16.0;
    pub const XL: f32 = 24.0;
}
pub struct Radius;
impl Radius {
    pub const CONTROL: u8 = 8;
    pub const CARD: u8 = 12;
    pub const PILL: u8 = 255;
}
pub struct Type;
impl Type {
    pub const CAPTION: f32 = 11.0;
    pub const SMALL: f32 = 12.0;
    pub const BODY: f32 = 14.0;
    pub const TITLE: f32 = 16.0;
    pub const PAGE: f32 = 22.0;
}
pub const CONTROL_H: f32 = 32.0;
pub const CONTROL_H_SM: f32 = 26.0;

#[derive(Clone, Copy, Debug)]
pub struct Tokens {
    pub scheme: Scheme,
    pub p: Palette,
    pub reduced_motion: bool,
}

const fn hex(v: u32) -> Color32 {
    Color32::from_rgb((v >> 16) as u8, (v >> 8) as u8, v as u8)
}

impl Tokens {
    pub fn new(scheme: Scheme, reduced_motion: bool) -> Self {
        let p = match scheme {
            Scheme::Dark => Palette {
                bg: hex(0x0E0D11),
                panel: hex(0x151419),
                raised: hex(0x1B1A20),
                control: hex(0x222127),
                control_hover: hex(0x2C2B33),
                control_pressed: hex(0x36343E),
                border: hex(0x29282F),
                border_ctl: hex(0x747080),
                border_strong: hex(0x938F9E),
                text: hex(0xEDEBF0),
                text_2: hex(0xA29EAC),
                text_3: hex(0x77737F),
                accent: hex(0xB07CE6),
                on_accent: hex(0x1C1226),
                accent_dim: Color32::from_rgba_unmultiplied(0xB0, 0x7C, 0xE6, 36),
                live: hex(0xFCF434),
                live_fill: hex(0xFCF434),
                on_live: hex(0x2C2C2C),
                success: hex(0x74D69F),
                warning: hex(0xEFC25E),
                danger: hex(0xFF8080),
                info: hex(0x86B4FF),
            },
            Scheme::Light => Palette {
                bg: hex(0xF4F3F6),
                panel: hex(0xFFFFFF),
                raised: hex(0xFAFAFB),
                control: hex(0xF1F0F4),
                control_hover: hex(0xE7E5EC),
                control_pressed: hex(0xDBD8E1),
                border: hex(0xE2E0E7),
                border_ctl: hex(0x86828F),
                border_strong: hex(0x5D5966),
                text: hex(0x19171D),
                text_2: hex(0x58545F),
                text_3: hex(0x86828E),
                accent: hex(0x7A3DBA),
                on_accent: hex(0xFFFFFF),
                accent_dim: Color32::from_rgba_unmultiplied(0x7A, 0x3D, 0xBA, 26),
                live: hex(0x7C6C00),
                live_fill: hex(0xFCF434),
                on_live: hex(0x2C2C2C),
                success: hex(0x1D7B46),
                warning: hex(0x8F5B00),
                danger: hex(0xBF2E39),
                info: hex(0x2556C2),
            },
        };
        Self {
            scheme,
            p,
            reduced_motion,
        }
    }

    pub fn get(ctx: &egui::Context) -> Self {
        ctx.data(|d| d.get_temp::<Tokens>(Id::new("freedigi-tokens")))
            .unwrap_or_else(|| Self::new(Scheme::Dark, false))
    }

    pub fn install(self, ctx: &egui::Context) {
        ctx.data_mut(|d| d.insert_temp(Id::new("freedigi-tokens"), self));
        let p = self.p;
        let control = CornerRadius::same(Radius::CONTROL);
        let w = |bg: Color32, stroke: Color32, fg: Color32| WidgetVisuals {
            bg_fill: bg,
            weak_bg_fill: bg,
            bg_stroke: Stroke::new(1.0_f32, stroke),
            corner_radius: control,
            fg_stroke: Stroke::new(1.0_f32, fg),
            expansion: 0.0,
        };
        let mut visuals = match self.scheme {
            Scheme::Dark => egui::Visuals::dark(),
            Scheme::Light => egui::Visuals::light(),
        };
        visuals.override_text_color = None;
        visuals.panel_fill = p.bg;
        visuals.window_fill = p.raised;
        visuals.window_stroke = Stroke::new(1.0_f32, p.border);
        visuals.extreme_bg_color = p.control;
        visuals.text_edit_bg_color = Some(p.control);
        visuals.faint_bg_color = p.control.gamma_multiply(0.55);
        visuals.code_bg_color = p.control;
        visuals.selection = Selection {
            bg_fill: p.accent_dim,
            stroke: Stroke::new(1.0_f32, p.accent),
        };
        visuals.hyperlink_color = p.accent;
        visuals.warn_fg_color = p.warning;
        visuals.error_fg_color = p.danger;
        visuals.window_corner_radius = CornerRadius::same(Radius::CARD);
        visuals.menu_corner_radius = CornerRadius::same(Radius::CARD);
        let shadow = Shadow {
            offset: [0, 8],
            blur: 24,
            spread: 0,
            color: Color32::from_black_alpha(if self.scheme == Scheme::Dark { 110 } else { 40 }),
        };
        visuals.window_shadow = shadow;
        visuals.popup_shadow = shadow;
        visuals.widgets = Widgets {
            noninteractive: w(p.panel, p.border, p.text_2),
            inactive: w(p.control, p.border_ctl, p.text),
            hovered: WidgetVisuals {
                fg_stroke: Stroke::new(1.5_f32, p.text),
                ..w(p.control_hover, p.border_strong, p.text)
            },
            active: WidgetVisuals {
                fg_stroke: Stroke::new(2.0_f32, p.text),
                ..w(p.control_pressed, p.accent, p.text)
            },
            open: w(p.control_hover, p.accent, p.text),
        };
        visuals.slider_trailing_fill = true;
        visuals.handle_shape = egui::style::HandleShape::Circle;
        visuals.striped = true;
        visuals.indent_has_left_vline = false;
        visuals.interact_cursor = Some(egui::CursorIcon::PointingHand);

        let mut style = (*ctx.style()).clone();
        style.visuals = visuals;
        let s = &mut style.spacing;
        s.item_spacing = egui::vec2(Space::S, Space::S);
        s.button_padding = egui::vec2(Space::M, 6.0);
        s.interact_size = egui::vec2(CONTROL_H, CONTROL_H);
        s.window_margin = Margin::same(Space::M as i8);
        s.menu_margin = Margin::same(6);
        s.combo_height = 280.0;
        s.slider_width = 240.0;
        s.slider_rail_height = 4.0;
        s.icon_width = 16.0;
        s.icon_width_inner = 8.0;
        s.icon_spacing = 8.0;
        s.scroll = egui::style::ScrollStyle::thin();
        style.text_styles = [
            (TextStyle::Small, FontId::proportional(Type::SMALL)),
            (TextStyle::Body, FontId::proportional(Type::BODY)),
            (TextStyle::Button, semibold(Type::BODY)),
            (TextStyle::Heading, bold(Type::PAGE)),
            (TextStyle::Monospace, FontId::monospace(12.5)),
        ]
        .into();
        style.animation_time = if self.reduced_motion { 0.0 } else { 0.12 };
        ctx.set_style(style);
    }
}

pub fn semibold(size: f32) -> FontId {
    FontId::new(size, FontFamily::Name("semibold".into()))
}
pub fn bold(size: f32) -> FontId {
    FontId::new(size, FontFamily::Name("bold".into()))
}

/// Nunito in three weights. egui selects weight by family, so each weight is a family.
pub fn install_fonts(ctx: &egui::Context) {
    let mut fonts = egui::FontDefinitions::default();
    for (name, bytes) in [
        (
            "Nunito",
            &include_bytes!("../../assets/fonts/Nunito-Regular.ttf")[..],
        ),
        (
            "Nunito-SemiBold",
            &include_bytes!("../../assets/fonts/Nunito-SemiBold.ttf")[..],
        ),
        (
            "Nunito-Bold",
            &include_bytes!("../../assets/fonts/Nunito-Bold.ttf")[..],
        ),
    ] {
        fonts
            .font_data
            .insert(name.into(), egui::FontData::from_static(bytes).into());
    }
    // Hack (already embedded for monospace) is the only bundled font with ← ↑ → ↓.
    let proportional = fonts.families.get_mut(&FontFamily::Proportional).unwrap();
    proportional.insert(0, "Nunito".into());
    proportional.push("Hack".into());
    let fallback = proportional[1..].to_vec();
    for (family, font) in [("semibold", "Nunito-SemiBold"), ("bold", "Nunito-Bold")] {
        let mut list = vec![font.to_owned()];
        list.extend(fallback.iter().cloned());
        fonts.families.insert(FontFamily::Name(family.into()), list);
    }
    ctx.set_fonts(fonts);
}

/// System fonts covering CJK, in preference order. Missing paths are skipped.
const SYSTEM_FALLBACKS: [&str; 7] = [
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
    "/System/Library/Fonts/STHeiti Light.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
];

/// Maps a file read-only for the rest of the process. Unlike a heap copy, clean
/// file-backed pages are shared with the OS cache and only touched glyphs load.
fn map_file(path: &str) -> Option<&'static [u8]> {
    use std::os::fd::AsRawFd;
    unsafe extern "C" {
        fn mmap(
            addr: *mut std::ffi::c_void,
            len: usize,
            prot: i32,
            flags: i32,
            fd: i32,
            offset: i64,
        ) -> *mut std::ffi::c_void;
    }
    // Same values on macOS and Linux.
    const PROT_READ: i32 = 1;
    const MAP_PRIVATE: i32 = 2;
    let file = std::fs::File::open(path).ok()?;
    let len = usize::try_from(file.metadata().ok()?.len()).ok()?;
    if len == 0 {
        return None;
    }
    // SAFETY: a read-only private mapping of a regular file; the pointer is checked
    // and the mapping is never unmapped, so the slice stays valid for 'static.
    unsafe {
        let ptr = mmap(
            std::ptr::null_mut(),
            len,
            PROT_READ,
            MAP_PRIVATE,
            file.as_raw_fd(),
            0,
        );
        (ptr as isize != -1).then(|| std::slice::from_raw_parts(ptr as *const u8, len))
    }
}

/// Whether `text` can be drawn without missing-glyph boxes. Controller-provided text
/// (the factory profile name is 配置1) may need CJK, which Nunito lacks; the first
/// time it does, a system font is mapped as a fallback. It is not embedded because
/// CJK fonts are tens of megabytes.
pub fn can_render(ctx: &egui::Context, text: &str) -> bool {
    use std::sync::atomic::{AtomicBool, Ordering};
    static TRIED: AtomicBool = AtomicBool::new(false);
    if text.is_ascii() || ctx.fonts_mut(|f| f.has_glyphs(&FontId::proportional(Type::BODY), text)) {
        return true;
    }
    if TRIED.swap(true, Ordering::Relaxed) {
        return false;
    }
    let Some(bytes) = SYSTEM_FALLBACKS.iter().find_map(|path| map_file(path)) else {
        return false;
    };
    let families = [
        FontFamily::Proportional,
        FontFamily::Name("semibold".into()),
        FontFamily::Name("bold".into()),
    ]
    .map(|family| egui::epaint::text::InsertFontFamily {
        family,
        priority: egui::epaint::text::FontPriority::Lowest,
    });
    ctx.add_font(egui::epaint::text::FontInsert::new(
        "system-cjk",
        egui::FontData::from_static(bytes),
        families.into(),
    ));
    // The new font takes effect on the next frame.
    ctx.request_repaint();
    true
}

#[cfg(test)]
pub fn contrast(a: Color32, b: Color32) -> f32 {
    fn lum(c: Color32) -> f32 {
        let f = |v: u8| {
            let v = v as f32 / 255.0;
            if v <= 0.03928 {
                v / 12.92
            } else {
                ((v + 0.055) / 1.055).powf(2.4)
            }
        };
        0.2126 * f(c.r()) + 0.7152 * f(c.g()) + 0.0722 * f(c.b())
    }
    let (x, y) = (lum(a), lum(b));
    (x.max(y) + 0.05) / (x.min(y) + 0.05)
}

#[cfg(test)]
mod tests {
    use super::*;
    /// Guards against the old theme's invisible borders and states (≈1.0–1.5:1).
    #[test]
    fn control_boundaries_and_text_meet_wcag() {
        for scheme in [Scheme::Dark, Scheme::Light] {
            let p = Tokens::new(scheme, false).p;
            let checks = [
                ("border_ctl/panel", p.border_ctl, p.panel, 3.0),
                ("border_ctl/control", p.border_ctl, p.control, 3.0),
                ("border_ctl/bg", p.border_ctl, p.bg, 3.0),
                (
                    "border_strong/control_hover",
                    p.border_strong,
                    p.control_hover,
                    3.0,
                ),
                ("accent/panel", p.accent, p.panel, 3.0),
                ("text/panel", p.text, p.panel, 4.5),
                ("text/control_pressed", p.text, p.control_pressed, 4.5),
                ("text_2/panel", p.text_2, p.panel, 4.5),
                ("text_2/bg", p.text_2, p.bg, 4.5),
                ("on_accent/accent", p.on_accent, p.accent, 4.5),
                ("on_live/live_fill", p.on_live, p.live_fill, 4.5),
                ("live/panel", p.live, p.panel, 4.5),
                ("success/panel", p.success, p.panel, 4.5),
                ("warning/panel", p.warning, p.panel, 4.5),
                ("danger/panel", p.danger, p.panel, 4.5),
            ];
            for (name, a, b, min) in checks {
                let ratio = contrast(a, b);
                assert!(ratio >= min, "{scheme:?} {name}: {ratio:.2} < {min}");
            }
        }
    }
}
