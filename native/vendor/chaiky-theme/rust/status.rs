use crate::*;

impl Theme {
    pub fn status(self, ui: &mut Ui, label: &str, tone: Tone, pending: bool) {
        ui.horizontal(|ui| {
            if pending && !self.reduced_motion {
                ui.spinner();
            }
            self.badge(ui, label, tone);
        });
    }
}
