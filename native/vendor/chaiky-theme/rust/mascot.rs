use crate::*;

pub const GULL_SVG: &[u8] = include_bytes!("../gull.svg");

impl Theme {
    /// Original Chaiky gull, cached by egui's image loader. No idle animation loop.
    pub fn mascot(self, ui: &mut Ui, size: f32, mood: Mood) -> Response {
        egui_extras::install_image_loaders(ui.ctx());
        let response = ui.add(
            egui::Image::from_bytes("bytes://chaiky/gull.svg", GULL_SVG)
                .fit_to_exact_size(Vec2::splat(size)),
        );
        let label = match mood {
            Mood::Resting => "Chaiky is keeping you company",
            Mood::Happy => "Chaiky is ready",
            Mood::Working => "Chaiky is working",
            Mood::Concerned => "Chaiky needs a little help",
        };
        if mood == Mood::Working && !self.reduced_motion {
            ui.spinner();
        }
        response.on_hover_text(label)
    }
}
