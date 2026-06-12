using Gtk4

# Minimal test with hierarchy
win = GtkWindow("Test", 800, 600)
main_box = GtkBox(:v)
push!(win, main_box)

# Add a frame with a button
frame = GtkFrame("Test Frame")
frame_box = GtkBox(:v)
btn = GtkButton("Click Me")
label = GtkLabel("Hello")

push!(frame_box, btn)
push!(frame_box, label)
push!(frame, frame_box)
push!(main_box, frame)

# Show everything explicitly
show(label)
show(btn)
show(frame_box)
show(frame)
show(main_box)
show(win)

if !isinteractive()
    Gtk4.GLib.main()
end