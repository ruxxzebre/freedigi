use crate::*;

impl Theme {
    pub fn card<R>(self, ui: &mut Ui, body: impl FnOnce(&mut Ui) -> R) -> egui::InnerResponse<R> {
        egui::Frame::new()
            .fill(self.color("surface"))
            .stroke(Stroke::new(1.0_f32, self.color("line")))
            .corner_radius(18)
            .inner_margin(Margin::same(20))
            .show(ui, |ui| {
                ui.set_width(ui.available_width());
                body(ui)
            })
    }
}
