use crate::*;

impl Theme {
    /// Atomic, non-clickable pill: stays intact in a wrapping row.
    pub fn badge(self, ui: &mut Ui, label: &str, tone: Tone) -> Response {
        ui.add(
            egui::Button::new(RichText::new(label).size(12.0).color(self.tone(tone)))
                .fill(self.tone(tone).gamma_multiply(0.12))
                .stroke(Stroke::NONE)
                .corner_radius(20)
                .sense(egui::Sense::hover())
                .wrap_mode(egui::TextWrapMode::Extend),
        )
    }
}
