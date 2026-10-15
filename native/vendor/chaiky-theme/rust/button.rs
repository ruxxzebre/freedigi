use crate::*;

impl Theme {
    pub fn button(self, ui: &mut Ui, label: &str, primary: bool) -> Response {
        let mut button = egui::Button::new(RichText::new(label).color(self.color(if primary {
            "on-accent"
        } else {
            "ink"
        })));
        if primary {
            button = button.fill(self.color("accent"));
        }
        ui.add(button)
    }
}
