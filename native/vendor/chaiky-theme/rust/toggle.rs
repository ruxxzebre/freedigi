use crate::*;

impl Theme {
    /// Label and pill share one hit area; pending disables input without erasing state.
    pub fn toggle(self, ui: &mut Ui, label: &str, value: &mut bool, pending: bool) -> Response {
        let text = format!(
            "{}   {}{}",
            if *value { "ON" } else { "OFF" },
            label,
            if pending { " · waiting" } else { "" }
        );
        let mut response = ui.add_enabled(!pending, egui::Button::new(text).selected(*value));
        if response.clicked() {
            *value = !*value;
            response.mark_changed();
        }
        response.widget_info(|| {
            egui::WidgetInfo::selected(
                egui::WidgetType::Checkbox,
                ui.is_enabled() && !pending,
                *value,
                label,
            )
        });
        response
    }
}
