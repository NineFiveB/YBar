-- macOS maps app names to glyphs in the "sketchybar-app-font" icon font,
-- which does not exist on Windows. This stub keeps `require` working; item
-- files treat a nil lookup as "no app icon" and leave those labels with
-- drawing = false. (Workspace pills show names/numbers; front_app can use
-- the engine's real shell icons via image = "app.<Name>" instead.)
return {}
