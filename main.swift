import Cocoa
import ApplicationServices

// --- Global State ---
var isSystemCursorVisible = true
var isCustomCursorActive = false
var customCursorWindow: NSWindow?
var customCursorView: CustomCursorView?
var eventTap: CFMachPort?
var lastLoggedRole: String?

// Parsed cursor data
var arrowCursorData: CursorImageData?
var iBeamCursorData: CursorImageData?
var isOverTextInputGlobal: Bool = false { // Global flag for text input context
    didSet {
        if oldValue != isOverTextInputGlobal {
            // Trigger view update when context changes
            DispatchQueue.main.async {
                customCursorView?.isTextContext = isOverTextInputGlobal
                // Re-evaluate window position if hotspot changes
                if isCustomCursorActive, let location = NSEvent.mouseLocationForCGEvent() {
                     updateCustomCursorPosition(location: location)
                }
            }
        }
    }
}


// Structure to hold parsed .cur data
struct CursorImageData {
    let width: Int
    let height: Int
    let hotspotX: Int
    let hotspotY: Int
    let pixelData: Data
    var nsImage: NSImage? // Cache the NSImage
}

// --- Custom View for Drawing the Cursor ---
class CustomCursorView: NSView {
    var arrowImage: NSImage?
    var iBeamImage: NSImage?
    
    var isTextContext: Bool = false {
        didSet {
            if oldValue != isTextContext {
                self.needsDisplay = true
            }
        }
    }

    var currentHotspot: NSPoint {
        if isTextContext, let iBeamHotspotX = iBeamCursorData?.hotspotX, let iBeamHotspotY = iBeamCursorData?.hotspotY {
            return NSPoint(x: iBeamHotspotX, y: iBeamHotspotY)
        } else if let arrowHotspotX = arrowCursorData?.hotspotX, let arrowHotspotY = arrowCursorData?.hotspotY {
            return NSPoint(x: arrowHotspotX, y: arrowHotspotY)
        }
        return .zero
    }
    
    var currentImageSize: NSSize {
        if isTextContext, let iBeamImg = iBeamImage {
            return iBeamImg.size
        } else if let arrowImg = arrowImage {
            return arrowImg.size
        }
        return .zero
    }


    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.clear.set()
        dirtyRect.fill()

        let imageToDraw = isTextContext ? iBeamImage : arrowImage
        imageToDraw?.draw(in: bounds)
    }

    func updateImages(arrow: NSImage?, iBeam: NSImage?) {
        self.arrowImage = arrow
        self.iBeamImage = iBeam
        self.needsDisplay = true
    }
}

// --- Accessibility Helper ---
func getAccessibilityElement(at point: CGPoint) -> AXUIElement? {
    let systemWideElement = AXUIElementCreateSystemWide()
    var element: AXUIElement?
    let error = AXUIElementCopyElementAtPosition(systemWideElement, Float(point.x), Float(point.y), &element)
    if error == .success && element != nil {
        return element
    }
    return nil
}

func getAttributeValue(element: AXUIElement, attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    return value
}

func isPotentiallyTextInputRole(_ role: String?) -> Bool {
    guard let role = role else { return false }
    let textInputRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole]
    return textInputRoles.contains(role)
}

func checkUIElementForTextInput(at point: CGPoint) {
    guard let element = getAccessibilityElement(at: point) else {
        isOverTextInputGlobal = false
        return
    }
    guard let roleRef = getAttributeValue(element: element, attribute: kAXRoleAttribute) else {
        isOverTextInputGlobal = false
        return
    }
    let role = roleRef as? String
    
    let isText = isPotentiallyTextInputRole(role)
    if isText != isOverTextInputGlobal { // Only update if state changed
        print("Mouse over text input: \(isText ? "YES" : "NO") (Role: \(role ?? "Unknown"))")
    }
    isOverTextInputGlobal = isText
}


// --- Minimal .cur Parser ---
func parseCurFile(atPath path: String) -> CursorImageData? {
    guard let fileData = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        print("Error: Could not read .cur file at \(path)")
        return nil
    }
    guard fileData.count >= 22 else {
        print("Error: .cur file too small at \(path).")
        return nil
    }

    let type = fileData[2...3].withUnsafeBytes { $0.load(as: UInt16.self) }
    guard type == 2 else {
        print("Error: File at \(path) is not a .CUR file (type: \(type)).")
        return nil
    }
    let imageCount = fileData[4...5].withUnsafeBytes { $0.load(as: UInt16.self) }
    guard imageCount > 0 else {
        print("Error: .cur file at \(path) contains no images.")
        return nil
    }

    var width = Int(fileData[6])
    var height = Int(fileData[7])
    if width == 0 { width = 256 }
    if height == 0 { height = 256 }

    let hotspotX = Int(fileData[10...11].withUnsafeBytes { $0.load(as: UInt16.self) })
    let hotspotY = Int(fileData[12...13].withUnsafeBytes { $0.load(as: UInt16.self) })
    let imageDataOffset = Int(fileData[18...21].withUnsafeBytes { $0.load(as: UInt32.self) })

    guard fileData.count >= imageDataOffset + 40 else {
        print("Error: File data too small for image data offset and BITMAPINFOHEADER at \(path).")
        return nil
    }

    let bitCountOffset = imageDataOffset + 14
    let bitCount = fileData[bitCountOffset...(bitCountOffset+1)].withUnsafeBytes { $0.load(as: UInt16.self) }
    guard bitCount == 32 else {
        print("Error: Expected 32-bpp .cur file at \(path), got \(bitCount)-bpp.")
        return nil
    }

    let compressionOffset = imageDataOffset + 16
    let compression = fileData[compressionOffset...(compressionOffset+3)].withUnsafeBytes { $0.load(as: UInt32.self) }
    guard compression == 0 else {
        print("Error: Expected uncompressed .cur file (BI_RGB) at \(path), got compression type \(compression).")
        return nil
    }
    
    let pixelDataStartOffset = imageDataOffset + 40
    let expectedPixelDataSize = width * height * 4

    guard fileData.count >= pixelDataStartOffset + expectedPixelDataSize else {
        print("Error: Not enough data in file for \(width)x\(height) 32bpp image at \(path).")
        return nil
    }

    var pixelData = Data(fileData[pixelDataStartOffset..<(pixelDataStartOffset + expectedPixelDataSize)])
    var rgbaData = Data(count: expectedPixelDataSize)
    for y in 0..<height {
        for x in 0..<width {
            let srcY = height - 1 - y
            let srcIndex = (srcY * width + x) * 4
            let destIndex = (y * width + x) * 4
            if srcIndex + 3 >= pixelData.count || destIndex + 3 >= rgbaData.count { continue }
            let b = pixelData[srcIndex]; let g = pixelData[srcIndex + 1]; let r = pixelData[srcIndex + 2]; let a = pixelData[srcIndex + 3]
            rgbaData[destIndex] = r; rgbaData[destIndex + 1] = g; rgbaData[destIndex + 2] = b; rgbaData[destIndex + 3] = a
        }
    }
    
    // Create NSImage from raw RGBA data
    guard let provider = CGDataProvider(data: rgbaData as CFData) else {
        print("Failed to create CGDataProvider for \(path).")
        return nil
    }
    guard let cgImage = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    ) else {
        print("Failed to create CGImage for \(path).")
        return nil
    }
    let finalImage = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))

    print("Parsed .cur: \(path) - \(width)x\(height), hotspot: (\(hotspotX), \(hotspotY))")
    return CursorImageData(width: width, height: height, hotspotX: hotspotX, hotspotY: hotspotY, pixelData: rgbaData, nsImage: finalImage)
}

// --- Event Tap Utilities ---
extension NSEvent {
    // Helper to get mouse location for CGEvent, as event.location is not always available
    // or might be stale if not on the main thread for UI updates.
    static func mouseLocationForCGEvent() -> CGPoint? {
        // This is a trick: create a dummy CGEvent to get current mouse location.
        // This is generally more reliable than caching from the event tap callback if not on main thread.
        // However, for direct use in eventTapCallback, event.location should be fine.
        // This function becomes more useful if updateCustomCursorPosition is called outside the tap.
        guard let event = CGEvent(source: nil) else { return nil }
        return event.location
    }
}

func updateCustomCursorPosition(location: CGPoint) {
    guard isCustomCursorActive, let window = customCursorWindow, let view = customCursorView else { return }

    let currentCursorImage = isOverTextInputGlobal ? iBeamCursorData : arrowCursorData
    guard let currentParsedData = currentCursorImage else { return }

    // Adjust window size if cursor images have different dimensions
    let newSize = NSSize(width: currentParsedData.width, height: currentParsedData.height)
    if window.frame.size != newSize {
        window.setContentSize(newSize)
        view.frame.size = newSize // Ensure view also resizes
        view.needsDisplay = true // Redraw with new image if size changed
    }
    
    guard let mainScreen = NSScreen.main else { return }
    let screenHeight = mainScreen.frame.height
    
    let windowX = location.x - CGFloat(currentParsedData.hotspotX)
    let windowY = screenHeight - location.y - (CGFloat(currentParsedData.height) - CGFloat(currentParsedData.hotspotY))
    
    // This needs to be on main thread for UI updates
    DispatchQueue.main.async {
        window.setFrameOrigin(NSPoint(x: windowX, y: windowY))
    }
}


// --- Event Tap Callback ---
func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .mouseMoved {
        let location = event.location
        if isCustomCursorActive {
            updateCustomCursorPosition(location: location)
            checkUIElementForTextInput(at: location) // This will update isOverTextInputGlobal
        }
    } else if type == .tapDisabledByTimeout {
        print("Event tap disabled by timeout. Re-enabling.")
        if let currentTap = eventTap { CGEvent.tapEnable(tap: currentTap, enable: true) }
    } else if type == .tapDisabledByUserInput {
        print("Event tap disabled by user input (permissions issue?).")
    }
    return Unmanaged.passUnretained(event)
}

// --- Setup Functions ---
func setupCustomCursorWindow() {
    // Initial size based on arrow cursor, will be adjusted dynamically
    let initialWidth = arrowCursorData?.width ?? 32
    let initialHeight = arrowCursorData?.height ?? 32

    customCursorView = CustomCursorView(frame: NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight))
    customCursorView?.updateImages(arrow: arrowCursorData?.nsImage, iBeam: iBeamCursorData?.nsImage)

    customCursorWindow = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight),
        styleMask: .borderless, backing: .buffered, defer: false
    )

    guard let window = customCursorWindow, let view = customCursorView else { return }
    window.isOpaque = false
    window.backgroundColor = NSColor.clear
    window.level = .statusBar 
    window.ignoresMouseEvents = true
    window.contentView = view
}

func setupEventTap() {
    let eventMask = (1 << CGEventType.mouseMoved.rawValue)
    eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(eventMask), callback: eventTapCallback, userInfo: nil)
    guard let currentTap = eventTap else {
        print("Failed to create event tap. Ensure Accessibility permissions are granted.")
        return
    }
    print("Event tap created.")
    let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, currentTap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: currentTap, enable: true)
    CFRunLoopRun()
    print("Event tap run loop finished.")
}

func main() {
    let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
    if !AXIsProcessTrustedWithOptions(options) {
        print("WARNING: Accessibility permissions NOT granted. App functionality will be severely limited.")
        print("Grant in System Settings > Privacy & Security > Accessibility for this app/terminal.")
    }

    arrowCursorData = parseCurFile(atPath: "./arrow.cur")
    iBeamCursorData = parseCurFile(atPath: "./ibeam.cur")

    guard arrowCursorData != nil, iBeamCursorData != nil else {
        print("Failed to load one or both .cur files. Ensure 'arrow.cur' and 'ibeam.cur' are present and valid.")
        exit(1)
    }
    
    DispatchQueue.main.async {
        setupCustomCursorWindow()
    }

    let eventTapQueue = DispatchQueue(label: "com.example.eventTapQueue", qos: .userInitiated)
    eventTapQueue.async {
        setupEventTap()
    }

    print("Application started. Press Enter to toggle system/custom cursor. 'quit' to exit.")
    print("When custom cursor active, it will switch between Arrow and IBeam based on context.")

    DispatchQueue.main.async {
        NSCursor.unhide()
        isSystemCursorVisible = true
        isCustomCursorActive = false
        print("System cursor active.")
    }

    while let input = readLine() {
        if input.lowercased() == "quit" {
            print("Exiting application..."); exit(0)
        }
        DispatchQueue.main.sync {
            if isCustomCursorActive {
                customCursorWindow?.orderOut(nil)
                NSCursor.unhide()
                isCustomCursorActive = false
                isSystemCursorVisible = true
                isOverTextInputGlobal = false // Reset context state
                print("System cursor active.")
            } else {
                NSCursor.hide()
                customCursorWindow?.orderFront(nil)
                isCustomCursorActive = true
                isSystemCursorVisible = false
                // Initial check for position and context
                if let location = NSEvent.mouseLocationForCGEvent() {
                    updateCustomCursorPosition(location: location)
                    checkUIElementForTextInput(at: location)
                }
                print("Custom cursor active. Auto-switching Arrow/IBeam.")
            }
        }
        print("Press Enter to toggle. 'quit' to exit.")
    }
}

main()