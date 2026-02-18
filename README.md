# Tk Paint

A simple paint tool for Inferno OS using the Tk window toolkit.

## Features

-   **Canvas**: Draw freely with the mouse.
-   **Colors**: Select from a palette (Black, White, Red, Green, Blue, Yellow).
-   **Save**: Save your drawing to an Inferno image file (default `out.bit`).
-   **Open**: Open and display existing Inferno image files.
-   **Clear**: Clear the canvas.

## Usage

1.  Run `tkpaint` from the shell.
2.  Draw on the white canvas area.
3.  Click "Save" to save to the filename specified in the entry box.
4.  Click "Open" to load the filename specified.

## Internals

Uses a Tk canvas for the UI and an off-screen `Draw->Image` to store the pixel data for saving/loading.
