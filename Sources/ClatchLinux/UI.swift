// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import CGtk
import Foundation

/// Small builders over GTK 4 / libadwaita widgets. Everything here exists in
/// GTK 4.6 and libadwaita 1.1 (Ubuntu 22.04), the oldest versions supported.
@MainActor
enum UI {
    // MARK: Containers

    static func vbox(_ spacing: Int32 = 12, _ children: [GPtr?] = []) -> GPtr {
        let box = g(gtk_box_new(GTK_ORIENTATION_VERTICAL, spacing))
        children.compactMap { $0 }.forEach { gtk_box_append(box.t(), $0.t()) }
        return box
    }

    static func hbox(_ spacing: Int32 = 8, _ children: [GPtr?] = []) -> GPtr {
        let box = g(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, spacing))
        children.compactMap { $0 }.forEach { gtk_box_append(box.t(), $0.t()) }
        return box
    }

    static func append(_ box: GPtr, _ child: GPtr?) {
        guard let child else { return }
        gtk_box_append(box.t(), child.t())
    }

    static func margins(_ widget: GPtr, _ all: Int32) -> GPtr {
        gtk_widget_set_margin_top(widget.t(), all)
        gtk_widget_set_margin_bottom(widget.t(), all)
        gtk_widget_set_margin_start(widget.t(), all)
        gtk_widget_set_margin_end(widget.t(), all)
        return widget
    }

    @discardableResult
    static func css(_ widget: GPtr, _ classes: String...) -> GPtr {
        classes.forEach { gtk_widget_add_css_class(widget.t(), $0) }
        return widget
    }

    static func expand(_ widget: GPtr, h: Bool = true, v: Bool = false) -> GPtr {
        gtk_widget_set_hexpand(widget.t(), h ? 1 : 0)
        gtk_widget_set_vexpand(widget.t(), v ? 1 : 0)
        return widget
    }

    static func align(_ widget: GPtr, h: GtkAlign? = nil, v: GtkAlign? = nil) -> GPtr {
        if let h { gtk_widget_set_halign(widget.t(), h) }
        if let v { gtk_widget_set_valign(widget.t(), v) }
        return widget
    }

    static func tooltip(_ widget: GPtr, _ text: String) -> GPtr {
        gtk_widget_set_tooltip_text(widget.t(), text)
        return widget
    }

    static func sensitive(_ widget: GPtr, _ on: Bool) -> GPtr {
        gtk_widget_set_sensitive(widget.t(), on ? 1 : 0)
        return widget
    }

    // MARK: Text

    static func label(_ text: String, _ classes: [String] = [], wrap: Bool = true, xalign: Float = 0) -> GPtr {
        let label = g(gtk_label_new(text))
        gtk_label_set_wrap(label.t(), wrap ? 1 : 0)
        if wrap { gtk_label_set_wrap_mode(label.t(), PANGO_WRAP_WORD_CHAR) }
        gtk_label_set_xalign(label.t(), xalign)
        classes.forEach { gtk_widget_add_css_class(label.t(), $0) }
        return label
    }

    static func caption(_ text: String) -> GPtr { label(text, ["caption", "dim-label"]) }

    static func heading(_ text: String) -> GPtr { label(text, ["heading"], wrap: true) }

    static func ellipsized(_ text: String, _ classes: [String] = []) -> GPtr {
        let l = label(text, classes, wrap: false)
        gtk_label_set_ellipsize(l.t(), PANGO_ELLIPSIZE_END)
        return l
    }

    // MARK: Buttons

    static func button(_ title: String, _ classes: [String] = [], _ action: @escaping Action) -> GPtr {
        let button = g(gtk_button_new_with_label(title))
        classes.forEach { gtk_widget_add_css_class(button.t(), $0) }
        onSignal(button, "clicked", action)
        return button
    }

    static func iconButton(_ icon: String, _ tooltipText: String, _ classes: [String] = ["flat"], _ action: @escaping Action) -> GPtr {
        let button = g(gtk_button_new_from_icon_name(icon))
        classes.forEach { gtk_widget_add_css_class(button.t(), $0) }
        gtk_widget_set_tooltip_text(button.t(), tooltipText)
        onSignal(button, "clicked", action)
        return button
    }

    /// A button whose content is any widget (a profile row, a session…).
    static func button(content: GPtr, _ classes: [String] = ["flat"], _ action: @escaping Action) -> GPtr {
        let button = g(gtk_button_new())
        gtk_button_set_child(button.t(), content.t())
        classes.forEach { gtk_widget_add_css_class(button.t(), $0) }
        onSignal(button, "clicked", action)
        return button
    }

    /// Two buttons filling a row: secondary on the left, the suggested action on the right.
    static func buttonRow(_ secondary: (String, Action), _ primary: (String, Action), destructive: Bool = false) -> GPtr {
        let left = expand(button(secondary.0, ["pill"], secondary.1))
        let right = expand(button(primary.0, ["pill", destructive ? "destructive-action" : "suggested-action"], primary.1))
        let row = hbox(8, [left, right])
        gtk_box_set_homogeneous(row.t(), 1)
        return row
    }

    /// A popover menu attached to a "⋯" button: (title, enabled, action).
    static func menuButton(_ items: [(String, Bool, Action)?], icon: String = "view-more-symbolic") -> GPtr {
        let menu = g(gtk_menu_button_new())
        gtk_menu_button_set_icon_name(menu.t(), icon)
        gtk_widget_add_css_class(menu.t(), "flat")
        let popover = g(gtk_popover_new())
        let list = vbox(0)
        for item in items {
            guard let (title, enabled, action) = item else {
                append(list, g(gtk_separator_new(GTK_ORIENTATION_HORIZONTAL)))
                continue
            }
            let entry = button(title, ["flat"]) {
                gtk_popover_popdown(popover.t())
                action()
            }
            if let child = gtk_button_get_child(entry.t()) { gtk_label_set_xalign(OpaquePointer(child), 0) }
            gtk_widget_set_sensitive(entry.t(), enabled ? 1 : 0)
            append(list, entry)
        }
        gtk_popover_set_child(popover.t(), list.t())
        gtk_menu_button_set_popover(menu.t(), popover.t())
        return align(menu, v: GTK_ALIGN_CENTER)
    }

    // MARK: Rows (libadwaita)

    /// A boxed list (the libadwaita card list).
    static func list(_ rows: [GPtr]) -> GPtr {
        let list = g(gtk_list_box_new())
        gtk_list_box_set_selection_mode(list.t(), GTK_SELECTION_NONE)
        gtk_widget_add_css_class(list.t(), "boxed-list")
        rows.forEach { gtk_list_box_append(list.t(), $0.t()) }
        return list
    }

    static func row(_ title: String, subtitle: String? = nil, prefix: GPtr? = nil, suffix: [GPtr] = [],
                    activate: Action? = nil) -> GPtr {
        let row = g(adw_action_row_new())
        adw_preferences_row_set_title(row.t(), escape(title))
        if let subtitle { adw_action_row_set_subtitle(row.t(), escape(subtitle)) }
        if let prefix { adw_action_row_add_prefix(row.t(), prefix.t()) }
        suffix.forEach { adw_action_row_add_suffix(row.t(), $0.t()) }
        if let activate {
            gtk_list_box_row_set_activatable(row.t(), 1)
            onSignal(row, "activated", activate)
        }
        return row
    }

    /// A row with a switch on the right.
    static func switchRow(_ title: String, subtitle: String? = nil, isOn: Bool, enabled: Bool = true,
                          _ changed: @escaping @MainActor (Bool) -> Void) -> GPtr {
        let toggle = g(gtk_switch_new())
        gtk_switch_set_active(toggle.t(), isOn ? 1 : 0)
        gtk_widget_set_valign(toggle.t(), GTK_ALIGN_CENTER)
        onSignal1(toggle, "notify::active") { _ in
            let on = gtk_switch_get_active(toggle.t()) != 0
            if on != isOn { changed(on) }
        }
        let row = self.row(title, subtitle: subtitle, suffix: [toggle])
        adw_action_row_set_activatable_widget(row.t(), toggle.t())
        gtk_widget_set_sensitive(row.t(), enabled ? 1 : 0)
        return row
    }

    static func group(_ title: String?, description: String? = nil, _ children: [GPtr]) -> GPtr {
        let group = g(adw_preferences_group_new())
        if let title { adw_preferences_group_set_title(group.t(), escape(title)) }
        if let description { adw_preferences_group_set_description(group.t(), escape(description)) }
        children.forEach { adw_preferences_group_add(group.t(), $0.t()) }
        return group
    }

    /// Pango markup escaping, for libadwaita titles (which are markup).
    static func escape(_ text: String) -> String {
        String(owned: g_markup_escape_text(text, -1)) ?? text
    }

    // MARK: Inputs

    static func entry(_ text: String = "", placeholder: String = "", activate: Action? = nil) -> GPtr {
        let entry = g(gtk_entry_new())
        gtk_editable_set_text(entry.t(), text)
        gtk_entry_set_placeholder_text(entry.t(), placeholder)
        if let activate { onSignal(entry, "activate", activate) }
        return entry
    }

    static func text(of entry: GPtr) -> String { String(gstring: gtk_editable_get_text(entry.t())) ?? "" }

    /// A labelled field: caption above the input.
    static func field(_ title: String, _ input: GPtr) -> GPtr {
        vbox(4, [label(title, ["caption-heading"]), input])
    }

    /// A multi-line text box in a frame.
    static func textArea(_ text: String, monospace: Bool = true, height: Int32 = 72) -> GPtr {
        let view = g(gtk_text_view_new())
        if monospace { gtk_text_view_set_monospace(view.t(), 1) }
        gtk_text_view_set_wrap_mode(view.t(), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_left_margin(view.t(), 8)
        gtk_text_view_set_right_margin(view.t(), 8)
        gtk_text_view_set_top_margin(view.t(), 6)
        gtk_text_view_set_bottom_margin(view.t(), 6)
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(view.t()), text, -1)
        let scroller = g(gtk_scrolled_window_new())
        gtk_scrolled_window_set_child(scroller.t(), view.t())
        gtk_scrolled_window_set_min_content_height(scroller.t(), height)
        gtk_scrolled_window_set_policy(scroller.t(), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        let frame = g(gtk_frame_new(nil))
        gtk_frame_set_child(frame.t(), scroller.t())
        return frame
    }

    /// The text of a textArea(…).
    static func text(ofArea frame: GPtr) -> String {
        guard let scroller = gtk_frame_get_child(frame.t()),
              let view = gtk_scrolled_window_get_child(GPtr(scroller).t()) else { return "" }
        let buffer = gtk_text_view_get_buffer(GPtr(view).t())
        var start = GtkTextIter(), end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        return String(owned: gtk_text_buffer_get_text(buffer, &start, &end, 0)) ?? ""
    }

    /// A dropdown over plain strings.
    static func dropdown(_ items: [String], selected: Int, _ changed: @escaping @MainActor (Int) -> Void) -> GPtr {
        var cStrings = items.map { strdup($0) } + [nil]
        let model = cStrings.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) {
                gtk_string_list_new($0)
            }
        }
        cStrings.forEach { free($0) }
        let dropdown = g(gtk_drop_down_new(GPtr(model!).t(), nil))
        gtk_drop_down_set_selected(dropdown.t(), guint(max(0, selected)))
        onSignal1(dropdown, "notify::selected") { _ in
            changed(Int(gtk_drop_down_get_selected(dropdown.t())))
        }
        return dropdown
    }

    /// A segmented control (linked toggle buttons). Calls `changed` with the new index.
    static func segmented(_ titles: [String], selected: Int, _ changed: @escaping @MainActor (Int) -> Void) -> GPtr {
        let box = css(hbox(0), "linked")
        var first: GPtr?
        for (index, title) in titles.enumerated() {
            let toggle = g(gtk_toggle_button_new_with_label(title))
            gtk_widget_set_hexpand(toggle.t(), 1)
            if let first { gtk_toggle_button_set_group(toggle.t(), first.t()) } else { first = toggle }
            gtk_toggle_button_set_active(toggle.t(), index == selected ? 1 : 0)
            onSignal(toggle, "toggled") {
                if gtk_toggle_button_get_active(toggle.t()) != 0 && index != selected { changed(index) }
            }
            append(box, toggle)
        }
        return box
    }

    // MARK: Images

    static func image(file: String, size: Int32) -> GPtr {
        let image = g(gtk_image_new_from_file(file))
        gtk_image_set_pixel_size(image.t(), size)
        return image
    }

    static func icon(_ name: String, size: Int32 = 16) -> GPtr {
        let image = g(gtk_image_new_from_icon_name(name))
        gtk_image_set_pixel_size(image.t(), size)
        return image
    }

    /// A rounded card (libadwaita "card" style), optionally tinted with a CSS class.
    static func card(_ child: GPtr, tint: String? = nil, padding: Int32 = 12) -> GPtr {
        let box = vbox(0, [margins(child, padding)])
        css(box, "card")
        if let tint { css(box, tint) }
        return box
    }

    // MARK: Style

    /// Clatch's own CSS (tints, the switcher's look). Loaded once.
    static func installStyle() {
        let provider = gtk_css_provider_new()
        let css = """
        .clatch-tint-accent { background-color: alpha(@accent_bg_color, 0.14); }
        .clatch-tint-warning { background-color: alpha(@warning_color, 0.16); }
        .clatch-tint-error { background-color: alpha(@error_color, 0.16); }
        .clatch-tint-success { background-color: alpha(@success_color, 0.16); }
        .clatch-chip { padding: 2px 8px; border-radius: 999px; background-color: alpha(currentColor, 0.08); font-size: smaller; }
        .clatch-running { color: @success_color; }
        .clatch-swatch { min-width: 22px; min-height: 22px; padding: 0; border-radius: 999px; }
        .clatch-swatch.selected { box-shadow: 0 0 0 2px @window_bg_color, 0 0 0 4px @window_fg_color; }
        window.clatch-switcher, window.clatch-switcher > * { background: transparent; box-shadow: none; }
        .clatch-switcher-surface {
            background-color: alpha(@window_bg_color, 0.82);
            border-radius: 28px;
            border: 1px solid alpha(@window_fg_color, 0.10);
            box-shadow: 0 18px 48px alpha(black, 0.32);
            padding: 18px 18px 12px 18px;
        }
        .clatch-tile { border-radius: 20px; padding: 12px 8px 10px 8px; transition: background-color 180ms ease-out, box-shadow 180ms ease-out; }
        .clatch-tile image { transition: -gtk-icon-transform 180ms ease-out; -gtk-icon-transform: scale(0.94); }
        .clatch-tile.selected { background-color: alpha(@accent_bg_color, 0.22); box-shadow: inset 0 0 0 1px alpha(@accent_bg_color, 0.55); }
        .clatch-tile.selected image { -gtk-icon-transform: scale(1.1); }
        .clatch-dot { min-width: 10px; min-height: 10px; border-radius: 999px; background-color: @success_color; box-shadow: 0 0 0 2px @window_bg_color; }
        """
        gtk_css_provider_load_from_data(provider, css, -1)
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), GPtr(provider!).t(),
                                                   guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
    }
}
