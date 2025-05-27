# macOS Custom Contextual Cursor (Arrow/IBeam) Demo (Swift)

This is a command-line Swift application that demonstrates:
1.  Setting up a `CGEventTap` to monitor system-wide mouse movement events.
2.  Parsing simple Windows `.cur` files for an Arrow and an IBeam cursor.
3.  Drawing a custom cursor image (either Arrow or IBeam) in a dedicated, transparent, borderless window that follows the mouse pointer, respecting the active `.cur` file's hotspot.
4.  Using macOS Accessibility APIs to detect if the UI element under the mouse pointer is a potential text input area.
5.  **Automatically switching between the custom Arrow and custom IBeam cursor images based on this detected context.**
6.  Toggling between the standard system cursor and the custom contextual cursor.

## Functionality

The application will:
1.  Attempt to load and parse two `.cur` files: `arrow.cur` and `ibeam.cur` from the same directory as the executable. (User-provided, see below).
2.  Set up a `CGEventTap` on a background thread to listen for `mouseMoved` events globally.
3.  If the custom cursor mode is active:
    *   The event tap's callback will update the position of the custom cursor window. The window is positioned so that the hotspot of the *currently displayed custom cursor* (Arrow or IBeam) aligns with the actual mouse pointer.
    *   The callback also uses Accessibility APIs to inspect the UI element under the mouse.
    *   Based on whether the element is a text input area, the application will automatically switch the `CustomCursorView` to display either the parsed `ibeam.cur` image or the `arrow.cur` image.
    *   The size of the custom cursor window may change if the Arrow and IBeam cursors have different dimensions.
4.  The main thread listens for user input:
    *   Pressing **Enter** toggles between "System Cursor Active" and "Custom Cursor Active."
    *   When "Custom Cursor Active," the Arrow/IBeam switching happens automatically.
    *   Typing **`quit`** and pressing Enter terminates the application.

## Requirements

* macOS
* Swift compiler (comes with Xcode Command Line Tools)
* **User-provided `arrow.cur` and `ibeam.cur` files.**

## Sample `.cur` File Requirements

You **must** provide two files, `arrow.cur` and `ibeam.cur`, in the same directory where you run the `CustomCursorDemo` executable.

For this Proof of Concept, the parser expects both files to have the following properties:
*   **Format:** Windows Cursor (.cur) file.
*   **Color Depth:** 32-bit ARGB (e.g., RGBA with 8 bits per channel).
*   **Compression:** Uncompressed (BI_RGB).
*   **Size:** Small sizes like 16x16 or 32x32 pixels are ideal.
*   **Hotspot:** The parser will read the hotspot from each `.cur` file's header.

**If `arrow.cur` or `ibeam.cur` are missing or not in the expected format, the application will print an error and likely exit.**

## Permissions

**This application CRITICALLY requires Accessibility permissions.** These are needed for:
1.  **`CGEventTap`:** To monitor global mouse movements for custom cursor positioning.
2.  **Accessibility API for UI Inspection:** To detect text input context for Arrow/IBeam switching.

To grant Accessibility permissions:
1.  Open **System Settings** > **Privacy & Security** > **Accessibility**.
2.  Unlock to make changes.
3.  Add the application:
    *   If running the compiled executable: Drag `CustomCursorDemo` to the list.
    *   If running via Terminal: Add your **Terminal** application to the list.

**Restart the application (or Terminal) after granting permissions.**

## Build Instructions

1.  Save the Swift code as `main.swift`.
2.  Ensure `arrow.cur` and `ibeam.cur` are in the same directory.
3.  Open Terminal and navigate to this directory.
4.  Compile:
    ```bash
    swiftc main.swift -o CustomCursorDemo -framework Cocoa -framework ApplicationServices
    ```
    This creates `CustomCursorDemo`.

## Running the Application

1.  Make sure `arrow.cur` and `ibeam.cur` are in the current directory.
2.  Run from Terminal:
    ```bash
    ./CustomCursorDemo
    ```
3.  Observe console output for `.cur` parsing status.
4.  Press **Enter** to activate the custom cursor mode.
5.  Move the mouse over different UI elements:
    *   Over general UI: The custom Arrow cursor should be shown.
    *   Over text fields (e.g., in TextEdit, Safari's address bar): The custom IBeam cursor should automatically appear.
    *   The console will log "Mouse over text input: YES/NO..." messages.
6.  Press **Enter** again to switch back to the system cursor.
7.  Type `quit` and press **Enter** to exit.

## Contextual Switching Notes

*   **Accuracy:** IBeam detection relies on `kAXRoleAttribute` matching `kAXTextFieldRole`, `kAXTextAreaRole`, or `kAXTextViewRole`. This is a PoC and may not work for all applications or complex UI frameworks (especially web content within browsers, which often presents as a single `kAXWebAreaRole`).
*   **Lag/Performance:** There might be a slight delay in cursor switching due to the polling nature of Accessibility API calls on mouse moves.
*   **Hotspot & Size Changes:** The application attempts to adjust the window size and use the correct hotspot when switching between Arrow and IBeam cursors if their dimensions/hotspots differ.

## Troubleshooting

*   **File Parsing Errors:** Ensure `arrow.cur` and `ibeam.cur` meet the format requirements (32-bit ARGB, uncompressed).
*   **"Failed to create event tap..." / No Custom Cursor Movement / No Context Switching:** Accessibility permissions issue. Re-check "Permissions".
*   **Cursor Misaligned:** Hotspot logic or coordinate conversion.
*   **IBeam Not Appearing Correctly:** The UI element might not have one of the recognized AXRoles. Test with standard AppKit apps like TextEdit.
*   **Application doesn't quit with Control-C:** Use the `quit` command.The `main.swift` file was updated in the previous step. It now includes:
1.  Global variables `arrowCursorData` and `iBeamCursorData` to store parsed cursor information (including `NSImage`).
2.  The `main()` function now calls `parseCurFile` for both `./arrow.cur` and `./ibeam.cur`.
3.  A global boolean `isOverTextInputGlobal` is set by `checkUIElementForTextInput`.
4.  `CustomCursorView` now has:
    *   `arrowImage` and `iBeamImage` properties.
    *   An `isTextContext` property observed by `isOverTextInputGlobal`'s `didSet`.
    *   The `draw(_:)` method selects between `arrowImage` and `iBeamImage` based on `isTextContext`.
5.  The `updateCustomCursorPosition` function now:
    *   Selects the hotspot from `arrowCursorData` or `iBeamCursorData` based on `isOverTextInputGlobal`.
    *   Adjusts the custom cursor window's content size if the Arrow and IBeam cursors have different dimensions.
6.  The main toggle remains for System vs. Custom cursor. The Arrow/IBeam switch is automatic when the custom cursor is active.

The `README.md` was also updated in the previous step to reflect these changes, including requiring `ibeam.cur` and explaining the new contextual switching behavior.

Both parts of the subtask are complete.
# mac_cursor
