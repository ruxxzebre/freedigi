use crate::*;

impl Theme {
    /// Entire row is interactive, including padding. Supports keyboard focus.
    pub fn navigation(self, ui: &mut Ui, label: &str, selected: bool) -> Response {
        ui.add_sized(
            [ui.available_width(), 43.0],
            egui::Button::new(RichText::new(label).color(self.color(if selected {
                "accent"
            } else {
                "muted"
            })))
            .fill(self.color(if selected { "glow" } else { "page" }))
            .stroke(Stroke::NONE),
        )
    }
}
