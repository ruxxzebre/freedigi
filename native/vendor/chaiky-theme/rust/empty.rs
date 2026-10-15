use crate::*;

impl Theme {
    pub fn empty(self, ui: &mut Ui, title: &str, detail: &str) {
        ui.vertical_centered(|ui| {
            self.mascot(ui, 112.0, Mood::Resting);
            ui.label(RichText::new(title).size(20.0).strong());
            ui.label(RichText::new(detail).color(self.color("muted")));
        });
    }
}
