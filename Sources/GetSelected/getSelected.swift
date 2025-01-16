import Foundation
@preconcurrency import ApplicationServices.HIServices
import Cocoa

/// 1. Get selected text, try to get text by AXUI first.
/// 2. If failed, try to get text by menu action copy.
public func getSelectedText() async throws -> String? {
    

    // Try AXUI method first
    let axResult = await getSelectedTextByAXUI()
    switch axResult {
    case let .success(text):
        if !text.isEmpty {
            
            return text
        } else {
            
            // Fall through to try menu action copy
        }

    case let .failure(error):
        _ = ()
    }

    // If AXUI fails or returns empty text, try menu action copy
    if let menuCopyText = try await getSelectedTextByMenuBarActionCopy() {
        if !menuCopyText.isEmpty {
            
            return menuCopyText
        } else {
            
        }
    }

    _ = ()
    return nil
}

/// Get selected text by AXUI
func getSelectedTextByAXUI() async -> Result<String, AXError> {
    

    let systemWideElement = AXUIElementCreateSystemWide()
    var focusedElementRef: CFTypeRef?

    // Get the currently focused element
    let focusedElementResult = AXUIElementCopyAttributeValue(
        systemWideElement,
        kAXFocusedUIElementAttribute as CFString,
        &focusedElementRef
    )

    guard focusedElementResult == .success,
        let focusedElement = focusedElementRef as! AXUIElement?
    else {
        _ = ()
        return .failure(focusedElementResult)
    }

    var selectedTextValue: CFTypeRef?

    // Get the selected text
    let selectedTextResult = AXUIElementCopyAttributeValue(
        focusedElement,
        kAXSelectedTextAttribute as CFString,
        &selectedTextValue
    )

    guard selectedTextResult == .success else {
        _ = ()
        return .failure(selectedTextResult)
    }

    guard let selectedText = selectedTextValue as? String else {
        _ = ()
        return .failure(.noValue)
    }

    
    return .success(selectedText)
}

/// Get selected text by menu bar action copy
///
/// Refer to Copi: https://github.com/s1ntoneli/Copi/blob/531a12fdc2da66c809951926ce88af02593e0723/Copi/Utilities/SystemUtilities.swift#L257
@MainActor
func getSelectedTextByMenuBarActionCopy() async throws -> String? {
    

    guard let copyItem = findEnabledCopyItemInFrontmostApp() else {
        return nil
    }

    return await getSelectedTextWithAction {
        try copyItem.performAction(.press)
    }
}

/// Get selected text by shortcut copy
func getSelectedTextByShortcutCopy() async -> String? {
    

    guard checkIsProcessTrusted(prompt: true) else {
        _ = ()
        return nil
    }

    return await getSelectedTextWithAction {
        postCopyEvent()
    }
}
/// Copy text and paste text.
func copyTextAndPaste(_ text: String) async {

    let newContent = await getNextPasteboardContent(triggeredBy: {
        text.copyToClipboard()
    }, preservePasteboard: false)

    if let text = newContent {
        postPasteEvent()
    }
}

/// Post copy event: Cmd+C
func postCopyEvent() {
    let sender = KeySender(key: .c, modifiers: .command)
    sender.sendGlobally()
}

/// Post paste event: Cmd+V
func postPasteEvent() {
    let sender = KeySender(key: .v, modifiers: .command)
    sender.sendGlobally()
}

extension String {
    func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(self, forType: .string)
    }
}
@MainActor
func getSelectedTextWithAction(
    action: @escaping () throws -> Void
) async -> String? {
    await getNextPasteboardContent(triggeredBy: action)
}

/// Get the next pasteboard content after executing an action.
/// - Parameters:
///   - action: The action that triggers the pasteboard change
///   - preservePasteboard: Whether to preserve the original pasteboard content
/// - Returns: The new pasteboard content if changed, nil if failed or timeout
@MainActor
func getNextPasteboardContent(
    triggeredBy action: @escaping () throws -> Void,
    preservePasteboard: Bool = true
) async -> String? {
    

    let pasteboard = NSPasteboard.general
    let initialChangeCount = pasteboard.changeCount
    var newContent: String?

    let executeAction = { @MainActor in
        do {
            
            try action()
        } catch {
            _ = ()
            return
        }

        await pollTask { @MainActor in
            // Check if the pasteboard content has changed
            if pasteboard.changeCount != initialChangeCount {
                // !!!: The pasteboard content may be nil or other strange content(such as old content) if the pasteboard is changing by other applications in the same time, like PopClip.
                newContent = pasteboard.string()
                if let newContent {
                    
                    return true
                }

                _ = ()
                return false
            }
            return false
        }
    }

    if preservePasteboard {
        await pasteboard.performTemporaryTask(executeAction)
    } else {
        await executeAction()
    }

    return newContent
}
@discardableResult
func pollTask(
    _ task: @escaping () async -> Bool,
    every duration: Duration = .seconds(0.005),
    timeout: TimeInterval = 5
) async -> Bool {
    let startTime = Date()
    while !Task.isCancelled, Date().timeIntervalSince(startTime) < timeout {
        if await task() {
            return true
        }
        try? await Task.sleep(for: duration)
    }
    return false
}

extension AXError: @retroactive Error {}


func findEnabledCopyItemInFrontmostApp() -> UIElement? {
    guard checkIsProcessTrusted(prompt: true) else {
        return nil
    }

    let frontmostApp = NSWorkspace.shared.frontmostApplication
    guard let frontmostApp, let appElement = Application(frontmostApp) else {
        return nil
    }

    guard let copyItem = appElement.findCopyMenuItem(),
        copyItem.isEnabled == true
    else {
        return nil
    }


    return copyItem
}

extension UIElement {
    /// Find the copy item element, identifier is "copy:", or title is "Copy".
    /// Search strategy: Start from the 4th item (usually Edit menu),
    /// then expand to adjacent items alternately.
    /// Search index order: 3 -> 2 -> 4 -> 1 -> 5 -> 0 -> 6
    func findCopyMenuItem() -> UIElement? {
        guard let menu, let menuChildren = menu.children else {
            return nil
        }

        let totalItems = menuChildren.count

        // Start from index 3 (4th item) if available
        let startIndex = 3

        // If we have enough items, try the 4th item first (usually Edit menu)
        if totalItems > startIndex {
            let editMenu = menuChildren[startIndex]
            if let copyElement = findCopyMenuItemIn(editMenu) {
                return copyElement
            }

            // Search adjacent items alternately
            for offset in 1...(max(startIndex, totalItems - startIndex - 1)) {
                // Try left item
                let leftIndex = startIndex - offset
                if leftIndex >= 0 {
                    if let copyElement = findCopyMenuItemIn(menuChildren[leftIndex]) {
                        return copyElement
                    }
                }

                // Try right item
                let rightIndex = startIndex + offset
                if rightIndex < totalItems {
                    if let copyElement = findCopyMenuItemIn(menuChildren[rightIndex]) {
                        return copyElement
                    }
                }

                // If both indices are out of bounds, stop searching
                if leftIndex < 0 && rightIndex >= totalItems {
                    break
                }
            }
        }

        // If still not found, search the entire menu as fallback
        return findCopyMenuItemIn(menu)
    }

    /// Check if the element is a copy element, identifier is "copy:", means copy action selector.
    var isCopyIdentifier: Bool {
        identifier == SystemMenuItem.copy.rawValue
    }

    /// Check if the element is a copy element, title is "Copy".
    var isCopyTitle: Bool {
        guard let title = title else {
            return false
        }
        return copyTitles.contains(title)
    }
}

/// NSRunningApplication extension description: localizedName (bundleIdentifier)
extension NSRunningApplication {
    public override var description: String {
        "\(localizedName ?? "") (\(bundleIdentifier ?? ""))"
    }
}

private func findCopyMenuItemIn(_ menuElement: UIElement) -> UIElement? {
    menuElement.deepFirst { element in
        guard let identifier = element.identifier else {
            return false
        }

        if element.isCopyIdentifier {
            return true
        }

        if element.cmdChar == "C", element.isCopyTitle {
            return true
        }
        return false
    }
}

/// Menu bar copy titles set, include most of the languages.
private let copyTitles: Set<String> = [
    "Copy",  // English
    "拷贝", "复制",  // Simplified Chinese
    "拷貝", "複製",  // Traditional Chinese
    "コピー",  // Japanese
    "복사",  // Korean
    "Copier",  // French
    "Copiar",  // Spanish, Portuguese
    "Copia",  // Italian
    "Kopieren",  // German
    "Копировать",  // Russian
    "Kopiëren",  // Dutch
    "Kopiér",  // Danish
    "Kopiera",  // Swedish
    "Kopioi",  // Finnish
    "Αντιγραφή",  // Greek
    "Kopyala",  // Turkish
    "Salin",  // Indonesian
    "Sao chép",  // Vietnamese
    "คัดลอก",  // Thai
    "Копіювати",  // Ukrainian
    "Kopiuj",  // Polish
    "Másolás",  // Hungarian
    "Kopírovat",  // Czech
    "Kopírovať",  // Slovak
    "Kopiraj",  // Croatian, Serbian (Latin)
    "Копирај",  // Serbian (Cyrillic)
    "Копиране",  // Bulgarian
    "Kopēt",  // Latvian
    "Kopijuoti",  // Lithuanian
    "Copiază",  // Romanian
    "העתק",  // Hebrew
    "نسخ",  // Arabic
    "کپی",  // Persian
]


import AppKit

class Keys: @unchecked Sendable {
nonisolated(unsafe) static var kBackupItemsKey: UInt8 = 0
}

extension NSPasteboard {
    /// Protect the pasteboard items from being changed by temporary tasks.
    @MainActor
    func performTemporaryTask(
        _ task: @escaping () async -> Void,
        restoreDelay: TimeInterval = 0
    ) async {
        saveCurrentContents()

        await task()

        if restoreDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(restoreDelay * 1_000_000_000))
        }
        restoreOriginalContents()
    }
}

extension NSPasteboard {
    @MainActor
    func saveCurrentContents() {
        var backupItems = [NSPasteboardItem]()
        if let items = pasteboardItems {
            for item in items {
                let backupItem = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) {
                        backupItem.setData(data, forType: type)
                    }
                }
                backupItems.append(backupItem)
            }
        }

        if !backupItems.isEmpty {
            self.backupItems = backupItems
        }
    }

    @MainActor
    func restoreOriginalContents() {
        if let items = backupItems {
            clearContents()
            writeObjects(items)
            backupItems = nil
        }
    }

    private var backupItems: [NSPasteboardItem]? {
        get {
            objc_getAssociatedObject(self, &Keys.kBackupItemsKey) as? [NSPasteboardItem]
        }
        set {
            objc_setAssociatedObject(self, &Keys.kBackupItemsKey, newValue, .OBJC_ASSOCIATION_RETAIN)
        }
    }
}

extension NSPasteboard {
    func setString(_ string: String?) {
        clearContents()
        if let string {
            setString(string, forType: .string)
        }
    }

    func string() -> String? {
        // Check if there is text type data
        guard let types = types, types.contains(.string) else {
            return nil
        }
        return string(forType: .string)
    }
}
enum Action: String {
    case press           = "AXPress"
    case increment       = "AXIncrement"
    case decrement       = "AXDecrement"
    case confirm         = "AXConfirm"
    case pick            = "AXPick"
    case cancel          = "AXCancel"
    case raise           = "AXRaise"
    case showMenu        = "AXShowMenu"
    case delete          = "AXDelete"
    case showAlternateUI = "AXShowAlternateUI"
    case showDefaultUI   = "AXShowDefaultUI"
}

class UIElement {
    let element: AXUIElement

    /// Create a UIElement from a raw AXUIElement object.
    ///
    /// The state and role of the AXUIElement is not checked.
    required init(_ nativeElement: AXUIElement) {
        // Since we are dealing with low-level C APIs, it never hurts to double check types.
        assert(CFGetTypeID(nativeElement) == AXUIElementGetTypeID(),
               "nativeElement is not an AXUIElement")

        element = nativeElement
    }

    /// Checks if the current process is a trusted accessibility client. If false, all APIs will
    /// throw errors.
    ///
    /// - parameter withPrompt: Whether to show the user a prompt if the process is untrusted. This
    ///                         happens asynchronously and does not affect the return value.
    class func isProcessTrusted(withPrompt showPrompt: Bool = false) -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: showPrompt as CFBoolean
        ]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }


    /// Performs the action `action` on the element, returning on success.
    ///
    /// - note: If the action times out, it might mean that the application is taking a long time to
    ///         actually perform the action. It doesn't necessarily mean that the action wasn't
    ///         performed.
    /// - throws: `Error.ActionUnsupported` if the action is not supported.
    func performAction(_ action: Action) throws {
        try performAction(action.rawValue)
    }

    func performAction(_ action: String) throws {
        let error = AXUIElementPerformAction(element, action as CFString)

        guard error == .success else {
            throw error
        }
    }

       // MARK: - Attributes

    /// Returns the list of all attributes.
    ///
    /// Does not include parameterized attributes.
    func attributes() throws -> [Attribute] {
        let attrs = try attributesAsStrings()
        for attr in attrs where Attribute(rawValue: attr) == nil {
            print("Unrecognized attribute: \(attr)")
        }
        return attrs.compactMap({ Attribute(rawValue: $0) })
    }

    // This version is named differently so the caller doesn't have to specify the return type when
    // using the enum version.
    func attributesAsStrings() throws -> [String] {
        var names: CFArray?
        let error = AXUIElementCopyAttributeNames(element, &names)

        if error == .noValue || error == .attributeUnsupported {
            return []
        }

        guard error == .success else {
            throw error
        }

        // We must first convert the CFArray to a native array, then downcast to an array of
        // strings.
        return names! as [AnyObject] as! [String]
    }

    /// Returns whether `attribute` is supported by this element.
    ///
    /// The `attribute` method returns nil for unsupported attributes and empty attributes alike,
    /// which is more convenient than dealing with exceptions (which are used for more serious
    /// errors). However, if you'd like to specifically test an attribute is actually supported, you
    /// can use this method.
    func attributeIsSupported(_ attribute: Attribute) throws -> Bool {
        return try attributeIsSupported(attribute.rawValue)
    }

    func attributeIsSupported(_ attribute: String) throws -> Bool {
        // Ask to copy 0 values, since we are only interested in the return code.
        var value: CFArray?
        let error = AXUIElementCopyAttributeValues(element, attribute as CFString, 0, 0, &value)

        if error == .attributeUnsupported {
            return false
        }

        if error == .noValue {
            return true
        }

        guard error == .success else {
            throw error
        }

        return true
    }

    /// Returns whether `attribute` is writeable.
    func attributeIsSettable(_ attribute: Attribute) throws -> Bool {
        return try attributeIsSettable(attribute.rawValue)
    }

    func attributeIsSettable(_ attribute: String) throws -> Bool {
        var settable: DarwinBoolean = false
        let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)

        if error == .noValue || error == .attributeUnsupported {
            return false
        }

        guard error == .success else {
            throw error
        }

        return settable.boolValue
    }

    /// Returns the value of `attribute`, if it exists.
    ///
    /// - parameter attribute: The name of a (non-parameterized) attribute.
    ///
    /// - returns: An optional containing the value of `attribute` as the desired type, or nil.
    ///            If `attribute` is an array, all values are returned.
    ///
    /// - warning: This method force-casts the attribute to the desired type, which will abort if
    ///            the cast fails. If you want to check the return type, ask for Any.
    func attribute<T>(_ attribute: Attribute) throws -> T? {
        return try self.attribute(attribute.rawValue)
    }

    func attribute<T>(_ attribute: String) throws -> T? {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)

        if error == .noValue || error == .attributeUnsupported {
            return nil
        }

        guard error == .success else {
            throw error
        }

        guard let unpackedValue = (unpackAXValue(value!) as? T) else {
            throw AXError.illegalArgument
        }
        
        return unpackedValue
    }

    /// Sets the value of `attribute` to `value`.
    ///
    /// - warning: Unlike read-only methods, this method throws if the attribute doesn't exist.
    ///
    /// - throws:
    ///   - `Error.AttributeUnsupported`: `attribute` isn't supported.
    ///   - `Error.IllegalArgument`: `value` is an illegal value.
    ///   - `Error.Failure`: A temporary failure occurred.
    func setAttribute(_ attribute: Attribute, value: Any) throws {
        try setAttribute(attribute.rawValue, value: value)
    }

    func setAttribute(_ attribute: String, value: Any) throws {
        let error = AXUIElementSetAttributeValue(element, attribute as CFString, packAXValue(value))

        guard error == .success else {
            throw error
        }
    }

    /// Gets multiple attributes of the element at once.
    ///
    /// - parameter attributes: An array of attribute names. Nonexistent attributes are ignored.
    ///
    /// - returns: A dictionary mapping provided parameter names to their values. Parameters which
    ///            don't exist or have no value will be absent.
    ///
    /// - throws: If there are any errors other than .NoValue or .AttributeUnsupported, it will
    ///           throw the first one it encounters.
    ///
    /// - note: Presumably you would use this API for performance, though it's not explicitly
    ///         documented by Apple that there is actually a difference.
    func getMultipleAttributes(_ names: Attribute...) throws -> [Attribute: Any] {
        return try getMultipleAttributes(names)
    }

    func getMultipleAttributes(_ attributes: [Attribute]) throws -> [Attribute: Any] {
        let values = try fetchMultiAttrValues(attributes.map({ $0.rawValue }))
        return try packMultiAttrValues(attributes, values: values)
    }

    func getMultipleAttributes(_ attributes: [String]) throws -> [String: Any] {
        let values = try fetchMultiAttrValues(attributes)
        return try packMultiAttrValues(attributes, values: values)
    }

    // Helper: Gets list of values
    fileprivate func fetchMultiAttrValues(_ attributes: [String]) throws -> [AnyObject] {
        var valuesCF: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element,
            attributes as CFArray,
            // keep going on errors (particularly NoValue)
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &valuesCF)

        guard error == .success else {
            throw error
        }

        return valuesCF! as [AnyObject]
    }

    // Helper: Packs names, values into dictionary
    fileprivate func packMultiAttrValues<Attr>(_ attributes: [Attr],
                                               values: [AnyObject]) throws -> [Attr: Any] {
        var result = [Attr: Any]()
        for (index, attribute) in attributes.enumerated() {
            if try checkMultiAttrValue(values[index]) {
                result[attribute] = unpackAXValue(values[index])
            }
        }
        return result
    }

    // Helper: Checks if value is present and not an error (throws on nontrivial errors).
    fileprivate func checkMultiAttrValue(_ value: AnyObject) throws -> Bool {
        // Check for null
        if value is NSNull {
            return false
        }

        // Check for error
        if CFGetTypeID(value) == AXValueGetTypeID() &&
            AXValueGetType(value as! AXValue).rawValue == kAXValueAXErrorType {
            var error: AXError = AXError.success
            AXValueGetValue(value as! AXValue, AXValueType(rawValue: kAXValueAXErrorType)!, &error)

            assert(error != .success)
            if error == .noValue || error == .attributeUnsupported {
                return false
            } else {
                throw error
            }
        }

        return true
    }

    // MARK: Array attributes

    /// Returns all the values of the attribute as an array of the given type.
    ///
    /// - parameter attribute: The name of the array attribute.
    ///
    /// - throws: `Error.IllegalArgument` if the attribute isn't an array.
    func arrayAttribute<T>(_ attribute: Attribute) throws -> [T]? {
        return try arrayAttribute(attribute.rawValue)
    }

    func arrayAttribute<T>(_ attribute: String) throws -> [T]? {
        guard let value: Any = try self.attribute(attribute) else {
            return nil
        }
        guard let array = value as? [AnyObject] else {
            // For consistency with the other array attribute APIs, throw if it's not an array.
            throw AXError.illegalArgument
        }
        return array.map({ unpackAXValue($0) as! T })
    }

    /// Returns a subset of values from an array attribute.
    ///
    /// - parameter attribute: The name of the array attribute.
    /// - parameter startAtIndex: The index of the array to start taking values from.
    /// - parameter maxValues: The maximum number of values you want.
    ///
    /// - returns: An array of up to `maxValues` values starting at `startAtIndex`.
    ///   - The array is empty if `startAtIndex` is out of range.
    ///   - `nil` if the attribute doesn't exist or has no value.
    ///
    /// - throws: `Error.IllegalArgument` if the attribute isn't an array.
    func valuesForAttribute<T: AnyObject>
    (_ attribute: Attribute, startAtIndex index: Int, maxValues: Int) throws -> [T]? {
        return try valuesForAttribute(attribute.rawValue, startAtIndex: index, maxValues: maxValues)
    }

    func valuesForAttribute<T: AnyObject>
    (_ attribute: String, startAtIndex index: Int, maxValues: Int) throws -> [T]? {
        var values: CFArray?
        let error = AXUIElementCopyAttributeValues(
            element, attribute as CFString, index, maxValues, &values
        )

        if error == .noValue || error == .attributeUnsupported {
            return nil
        }

        guard error == .success else {
            throw error
        }

        let array = values! as [AnyObject]
        return array.map({ unpackAXValue($0) as! T })
    }

    /// Returns the number of values an array attribute has.
    /// - returns: The number of values, or `nil` if `attribute` isn't an array (or doesn't exist).
    func valueCountForAttribute(_ attribute: Attribute) throws -> Int? {
        return try valueCountForAttribute(attribute.rawValue)
    }

    func valueCountForAttribute(_ attribute: String) throws -> Int? {
        var count: Int = 0
        let error = AXUIElementGetAttributeValueCount(element, attribute as CFString, &count)

        if error == .attributeUnsupported || error == .illegalArgument {
            return nil
        }

        guard error == .success else {
            throw error
        }

        return count
    }

    // MARK: Parameterized attributes

    /// Returns a list of all parameterized attributes of the element.
    ///
    /// Parameterized attributes are attributes that require parameters to retrieve. For example,
    /// the cell contents of a spreadsheet might require the row and column of the cell you want.
    func parameterizedAttributes() throws -> [Attribute] {
        return try parameterizedAttributesAsStrings().compactMap({ Attribute(rawValue: $0) })
    }

    func parameterizedAttributesAsStrings() throws -> [String] {
        var names: CFArray?
        let error = AXUIElementCopyParameterizedAttributeNames(element, &names)

        if error == .noValue || error == .attributeUnsupported {
            return []
        }

        guard error == .success else {
            throw error
        }

        // We must first convert the CFArray to a native array, then downcast to an array of
        // strings.
        return names! as [AnyObject] as! [String]
    }

    /// Returns the value of the parameterized attribute `attribute` with parameter `param`.
    ///
    /// The expected type of `param` depends on the attribute. See the
    /// [NSAccessibility Informal Protocol Reference](https://developer.apple.com/library/mac/documentation/Cocoa/Reference/ApplicationKit/Protocols/NSAccessibility_Protocol/)
    /// for more info.
    func parameterizedAttribute<T, U>(_ attribute: Attribute, param: U) throws -> T? {
        return try parameterizedAttribute(attribute.rawValue, param: param)
    }

    func parameterizedAttribute<T, U>(_ attribute: String, param: U) throws -> T? {
        var value: AnyObject?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element, attribute as CFString, param as AnyObject, &value
        )

        if error == .noValue || error == .attributeUnsupported {
            return nil
        }

        guard error == .success else {
            throw error
        }

        return (unpackAXValue(value!) as! T)
    }

    // MARK: Attribute helpers

    // Checks if the value is an AXValue and if so, unwraps it.
    // If the value is an AXUIElement, wraps it in UIElement.
    fileprivate func unpackAXValue(_ value: AnyObject) -> Any {
        switch CFGetTypeID(value) {
        case AXUIElementGetTypeID():
            return UIElement(value as! AXUIElement)
        case AXValueGetTypeID():
            let type = AXValueGetType(value as! AXValue)
            switch type {
            case .axError:
                var result: AXError = .success
                let success = AXValueGetValue(value as! AXValue, type, &result)
                assert(success)
                return result
            case .cfRange:
                var result: CFRange = CFRange()
                let success = AXValueGetValue(value as! AXValue, type, &result)
                assert(success)
                return result
            case .cgPoint:
                var result: CGPoint = CGPoint.zero
                let success = AXValueGetValue(value as! AXValue, type, &result)
                assert(success)
                return result
            case .cgRect:
                var result: CGRect = CGRect.zero
                let success = AXValueGetValue(value as! AXValue, type, &result)
                assert(success)
                return result
            case .cgSize:
                var result: CGSize = CGSize.zero
                let success = AXValueGetValue(value as! AXValue, type, &result)
                assert(success)
                return result
            case .illegal:
                return value
            @unknown default:
                return value
            }
        default:
            return value
        }
    }

    // Checks if the value is one supported by AXValue and if so, wraps it.
    // If the value is a UIElement, unwraps it to an AXUIElement.
    fileprivate func packAXValue(_ value: Any) -> AnyObject {
        switch value {
        case let val as UIElement:
            return val.element
        case var val as CFRange:
            return AXValueCreate(AXValueType(rawValue: kAXValueCFRangeType)!, &val)!
        case var val as CGPoint:
            return AXValueCreate(AXValueType(rawValue: kAXValueCGPointType)!, &val)!
        case var val as CGRect:
            return AXValueCreate(AXValueType(rawValue: kAXValueCGRectType)!, &val)!
        case var val as CGSize:
            return AXValueCreate(AXValueType(rawValue: kAXValueCGSizeType)!, &val)!
        default:
            return value as AnyObject // must be an object to pass to AX
        }
    }

    
    // MARK: -

    /// Returns the process ID of the application that the element is a part of.
    ///
    /// Throws only if the element is invalid (`Errors.InvalidUIElement`).
    func pid() throws -> pid_t {
        var pid: pid_t = -1
        let error = AXUIElementGetPid(element, &pid)

        guard error == .success else {
            throw error
        }

        return pid
    }

    /// The timeout in seconds for all messages sent to this element. Use this to control how long a
    /// method call can delay execution. The default is `0`, which means to use the global timeout.
    ///
    /// - note: Only applies to this instance of UIElement, not other instances that happen to equal
    ///         it.
    /// - seeAlso: `UIElement.globalMessagingTimeout(_:)`
    var messagingTimeout: Float = 0 {
        didSet {
            messagingTimeout = max(messagingTimeout, 0)
            let error = AXUIElementSetMessagingTimeout(element, messagingTimeout)

            // InvalidUIElement errors are only relevant when actually passing messages, so we can
            // ignore them here.
            guard error == .success || error == .invalidUIElement else {
                fatalError("Unexpected error setting messaging timeout: \(error)")
            }
        }
    }

    // Gets the element at the specified coordinates.
    // This can only be called on applications and the system-wide element, so it is internal here.
    func elementAtPosition(_ x: Float, _ y: Float) throws -> UIElement? {
        var result: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(element, x, y, &result)

        if error == .noValue {
            return nil
        }

        guard error == .success else {
            throw error
        }

        return UIElement(result!)
    }

    // TODO: convenience functions for attributes
    // TODO: get any attribute as a UIElement or [UIElement] (or a subclass)
    // TODO: promoters
}

// MARK: - CustomStringConvertible

extension UIElement: CustomStringConvertible {
    var description: String {
        var roleString: String
        var description: String?
        let pid = try? self.pid()
        do {
            let role = try self.role()
            roleString = role?.rawValue ?? "UIElementNoRole"

            switch role {
            case .some(.application):
                description = pid
                    .flatMap { NSRunningApplication(processIdentifier: $0) }
                    .flatMap { $0.bundleIdentifier } ?? ""
            case .some(.window):
                description = (try? attribute(.title) ?? "") ?? ""
            default:
                break
            }
        } catch AXError.invalidUIElement {
            roleString = "InvalidUIElement"
        } catch {
            roleString = "UnknownUIElement"
        }

        let pidString = (pid == nil) ? "??" : String(pid!)
        return "<\(roleString) \""
             + "\(description ?? String(describing: element))"
             + "\" (pid=\(pidString))>"
    }

    var inspect: String {
        guard let attributeNames = try? attributes() else {
            return "InvalidUIElement"
        }
        guard let attributes = try? getMultipleAttributes(attributeNames) else {
            return "InvalidUIElement"
        }
        return "\(attributes)"
    }
}

// MARK: - Equatable

extension UIElement: Equatable {}
func ==(lhs: UIElement, rhs: UIElement) -> Bool {
    return CFEqual(lhs.element, rhs.element)
}

// MARK: - Convenience getters

extension UIElement {
    /// Returns the role (type) of the element, if it reports one.
    ///
    /// Almost all elements report a role, but this could return nil for elements that aren't
    /// finished initializing.
    ///
    /// - seeAlso: [Roles](https://developer.apple.com/library/mac/documentation/AppKit/Reference/NSAccessibility_Protocol_Reference/index.html#//apple_ref/doc/constant_group/Roles)
    func role() throws -> Role? {
        // should this be non-optional?
        if let str: String = try self.attribute(.role) {
            return Role(rawValue: str)
        } else {
            return nil
        }
    }

    /// - seeAlso: [Subroles](https://developer.apple.com/library/mac/documentation/AppKit/Reference/NSAccessibility_Protocol_Reference/index.html#//apple_ref/doc/constant_group/Subroles)
    func subrole() throws -> Subrole? {
        if let str: String = try self.attribute(.subrole) {
            return Subrole(rawValue: str)
        } else {
            return nil
        }
    }
}

extension UIElement {
    
    var isCopy: Bool {
        identifier == SystemMenuItem.copy.rawValue || (cmdChar == SystemMenuItem.copy.cmdChar && cmdModifiers == SystemMenuItem.copy.cmdModifiers)
    }
    
    func findMenuItem(cmdChar: String, cmdModifiers: Int, cmdVirtualKey: Int) -> UIElement? {
        return menu?.deepFirst { $0.cmdChar == cmdChar && $0.cmdModifiers == cmdModifiers && $0.cmdVirtualKey == cmdVirtualKey }
    }
    
    func findMenuItem(title: String) -> UIElement? {
        return menu?.deepFirst(where: { $0.title == title })
    }
    
    func findCopy() -> UIElement? {
        return menu?.deepFirst { $0.isCopy }
    }

    enum SystemMenuItem: String {
        case copy = "copy:"
        case paste = "paste:"
        case cut = "cut:"

        var cmdChar: String {
            switch self {
            case .copy:
                "C"
            case .paste:
                "P"
            case .cut:
                "X"
            }
        }
        
        var cmdModifiers: Int {
            switch self {
            case .copy:
                0
            case .paste:
                0
            case .cut:
                0
            }
        }
        
        var cmdVirtualKey: Int? {
            switch self {
            case .copy:
                nil
            case .paste:
                nil
            case .cut:
                nil
            }
        }
    }
}

extension Attribute {
    static let cmdVirtualKey = "AXMenuItemCmdVirtualKey"
    static let cmdChar = "AXMenuItemCmdChar"
    static let cmdModifiers = "AXMenuItemCmdModifiers"
}

extension UIElement {
    
    var cmdChar: String? {
        return try? attribute(Attribute.cmdChar)
    }
    
    var cmdVirtualKey: Int? {
        return try? attribute(Attribute.cmdVirtualKey)
    }
    
    var cmdModifiers: Int? {
        return try? attribute(Attribute.cmdModifiers)
    }
    
    var title: String? {
        return try? attribute(.title)
    }
    
    var identifier: String? {
        return try? attribute(.identifier)
    }
    
    var menu: UIElement? {
        return try? attribute(.menuBar)
    }
    
    var isEnabled: Bool? {
        return try? attribute(.enabled)
    }
    
    var children: [UIElement]? {
        do {
            let axElements: [AXUIElement]? = try attribute(.children)
            return axElements?.map({ UIElement($0) })
        } catch {}
        return nil
    }
    
    func deepFirst(where condition: @escaping (UIElement) -> Bool) -> UIElement? {
        if condition(self) {
            return self
        }
        
        for child in children ?? [] {
            if let res = child.deepFirst(where: { condition($0) }) {
                return res
            }
        }

        return nil
    }
}
enum Attribute: String {
    // Standard attributes
    case role                                   = "AXRole" //(NSString *) - type, non-localized (e.g. radioButton)
    case roleDescription                        = "AXRoleDescription" //(NSString *) - user readable role (e.g. "radio button")
    case subrole                                = "AXSubrole" //(NSString *) - type, non-localized (e.g. closeButton)
    case help                                   = "AXHelp" //(NSString *) - instance description (e.g. a tool tip)
    case value                                  = "AXValue" //(id)         - element's value
    case minValue                               = "AXMinValue" //(id)         - element's min value
    case maxValue                               = "AXMaxValue" //(id)         - element's max value
    case enabled                                = "AXEnabled" //(NSNumber *) - (boolValue) responds to user?
    case focused                                = "AXFocused" //(NSNumber *) - (boolValue) has keyboard focus?
    case parent                                 = "AXParent" //(id)         - element containing you
    case children                               = "AXChildren" //(NSArray *)  - elements you contain
    case window                                 = "AXWindow" //(id)         - UIElement for the containing window
    case topLevelUIElement                      = "AXTopLevelUIElement" //(id)         - UIElement for the containing top level element
    case selectedChildren                       = "AXSelectedChildren" //(NSArray *)  - child elements which are selected
    case visibleChildren                        = "AXVisibleChildren" //(NSArray *)  - child elements which are visible
    case position                               = "AXPosition" //(NSValue *)  - (pointValue) position in screen coords
    case size                                   = "AXSize" //(NSValue *)  - (sizeValue) size
    case frame                                  = "AXFrame" //(NSValue *)  - (rectValue) frame
    case contents                               = "AXContents" //(NSArray *)  - main elements
    case title                                  = "AXTitle" //(NSString *) - visible text (e.g. of a push button)
    case description                            = "AXDescription" //(NSString *) - instance description
    case shownMenu                              = "AXShownMenu" //(id)         - menu being displayed
    case valueDescription                       = "AXValueDescription" //(NSString *)  - text description of value

    case sharedFocusElements                    = "AXSharedFocusElements" //(NSArray *)  - elements that share focus

    // Misc attributes
    case previousContents                       = "AXPreviousContents" //(NSArray *)  - main elements
    case nextContents                           = "AXNextContents" //(NSArray *)  - main elements
    case header                                 = "AXHeader" //(id)         - UIElement for header.
    case edited                                 = "AXEdited" //(NSNumber *) - (boolValue) is it dirty?
    case tabs                                   = "AXTabs" //(NSArray *)  - UIElements for tabs
    case horizontalScrollBar                    = "AXHorizontalScrollBar" //(id)       - UIElement for the horizontal scroller
    case verticalScrollBar                      = "AXVerticalScrollBar" //(id)         - UIElement for the vertical scroller
    case overflowButton                         = "AXOverflowButton" //(id)         - UIElement for overflow
    case incrementButton                        = "AXIncrementButton" //(id)         - UIElement for increment
    case decrementButton                        = "AXDecrementButton" //(id)         - UIElement for decrement
    case filename                               = "AXFilename" //(NSString *) - filename
    case expanded                               = "AXExpanded" //(NSNumber *) - (boolValue) is expanded?
    case selected                               = "AXSelected" //(NSNumber *) - (boolValue) is selected?
    case splitters                              = "AXSplitters" //(NSArray *)  - UIElements for splitters
    case document                               = "AXDocument" //(NSString *) - url as string - for document
    case activationPoint                        = "AXActivationPoint" //(NSValue *)  - (pointValue)

    case url                                    = "AXURL" //(NSURL *)    - url
    case index                                  = "AXIndex" //(NSNumber *)  - (intValue)

    case rowCount                               = "AXRowCount" //(NSNumber *)  - (intValue) number of rows

    case columnCount                            = "AXColumnCount" //(NSNumber *)  - (intValue) number of columns

    case orderedByRow                           = "AXOrderedByRow" //(NSNumber *)  - (boolValue) is ordered by row?

    case warningValue                           = "AXWarningValue" //(id)  - warning value of a level indicator, typically a number

    case criticalValue                          = "AXCriticalValue" //(id)  - critical value of a level indicator, typically a number

    case placeholderValue                       = "AXPlaceholderValue" //(NSString *)  - placeholder value of a control such as a text field

    case containsProtectedContent               = "AXContainsProtectedContent" // (NSNumber *) - (boolValue) contains protected content?
    case alternateUIVisible                     = "AXAlternateUIVisible" //(NSNumber *) - (boolValue)

    // Linkage attributes
    case titleUIElement                         = "AXTitleUIElement" //(id)       - UIElement for the title
    case servesAsTitleForUIElements             = "AXServesAsTitleForUIElements" //(NSArray *) - UIElements this titles
    case linkedUIElements                       = "AXLinkedUIElements" //(NSArray *) - corresponding UIElements

    // Text-specific attributes
    case selectedText                           = "AXSelectedText" //(NSString *) - selected text
    case selectedTextRange                      = "AXSelectedTextRange" //(NSValue *)  - (rangeValue) range of selected text
    case numberOfCharacters                     = "AXNumberOfCharacters" //(NSNumber *) - number of characters
    case visibleCharacterRange                  = "AXVisibleCharacterRange" //(NSValue *)  - (rangeValue) range of visible text
    case sharedTextUIElements                   = "AXSharedTextUIElements" //(NSArray *)  - text views sharing text
    case sharedCharacterRange                   = "AXSharedCharacterRange" //(NSValue *)  - (rangeValue) part of shared text in this view
    case insertionPointLineNumber               = "AXInsertionPointLineNumber" //(NSNumber *) - line# containing caret
    case selectedTextRanges                     = "AXSelectedTextRanges" //(NSArray<NSValue *> *) - array of NSValue (rangeValue) ranges of selected text
    /// - note: private/undocumented attribute
    case textInputMarkedRange                   = "AXTextInputMarkedRange"

    // Parameterized text-specific attributes
    case lineForIndexParameterized              = "AXLineForIndexParameterized" //(NSNumber *) - line# for char index; param:(NSNumber *)
    case rangeForLineParameterized              = "AXRangeForLineParameterized" //(NSValue *)  - (rangeValue) range of line; param:(NSNumber *)
    case stringForRangeParameterized            = "AXStringForRangeParameterized" //(NSString *) - substring; param:(NSValue * - rangeValue)
    case rangeForPositionParameterized          = "AXRangeForPositionParameterized" //(NSValue *)  - (rangeValue) composed char range; param:(NSValue * - pointValue)
    case rangeForIndexParameterized             = "AXRangeForIndexParameterized" //(NSValue *)  - (rangeValue) composed char range; param:(NSNumber *)
    case boundsForRangeParameterized            = "AXBoundsForRangeParameterized" //(NSValue *)  - (rectValue) bounds of text; param:(NSValue * - rangeValue)
    case rtfForRangeParameterized               = "AXRTFForRangeParameterized" //(NSData *)   - rtf for text; param:(NSValue * - rangeValue)
    case styleRangeForIndexParameterized        = "AXStyleRangeForIndexParameterized" //(NSValue *)  - (rangeValue) extent of style run; param:(NSNumber *)
    case attributedStringForRangeParameterized  = "AXAttributedStringForRangeParameterized" //(NSAttributedString *) - does _not_ use attributes from Appkit/AttributedString.h

    // Text attributed string attributes and constants
    case fontText                               = "AXFontText" //(NSDictionary *)  - NSAccessibilityFontXXXKey's
    case foregroundColorText                    = "AXForegroundColorText" //CGColorRef
    case backgroundColorText                    = "AXBackgroundColorText" //CGColorRef
    case underlineColorText                     = "AXUnderlineColorText" //CGColorRef
    case strikethroughColorText                 = "AXStrikethroughColorText" //CGColorRef
    case underlineText                          = "AXUnderlineText" //(NSNumber *)     - underline style
    case superscriptText                        = "AXSuperscriptText" //(NSNumber *)     - superscript>0, subscript<0
    case strikethroughText                      = "AXStrikethroughText" //(NSNumber *)     - (boolValue)
    case shadowText                             = "AXShadowText" //(NSNumber *)     - (boolValue)
    case attachmentText                         = "AXAttachmentText" //id - corresponding element
    case linkText                               = "AXLinkText" //id - corresponding element
    case autocorrectedText                      = "AXAutocorrectedText" //(NSNumber *)     - (boolValue)

    // Textual list attributes and constants. Examples: unordered or ordered lists in a document.
    case listItemPrefixText                     = "AXListItemPrefixText" // NSAttributedString, the prepended string of the list item. If the string is a common unicode character (e.g. a bullet •), return that unicode character. For lists with images before the text, return a reasonable label of the image.
    case listItemIndexText                      = "AXListItemIndexText" // NSNumber, integerValue of the line index. Each list item increments the index, even for unordered lists. The first item should have index 0.
    case listItemLevelText                      = "AXListItemLevelText" // NSNumber, integerValue of the indent level. Each sublist increments the level. The first item should have level 0.

    // MisspelledText attributes
    case misspelledText                         = "AXMisspelledText" //(NSNumber *)     - (boolValue)
    case markedMisspelledText                   = "AXMarkedMisspelledText" //(NSNumber *) - (boolValue)

    // Window-specific attributes
    case main                                   = "AXMain" //(NSNumber *) - (boolValue) is it the main window?
    case minimized                              = "AXMinimized" //(NSNumber *) - (boolValue) is window minimized?
    case closeButton                            = "AXCloseButton" //(id) - UIElement for close box (or nil)
    case zoomButton                             = "AXZoomButton" //(id) - UIElement for zoom box (or nil)
    case minimizeButton                         = "AXMinimizeButton" //(id) - UIElement for miniaturize box (or nil)
    case toolbarButton                          = "AXToolbarButton" //(id) - UIElement for toolbar box (or nil)
    case proxy                                  = "AXProxy" //(id) - UIElement for title's icon (or nil)
    case growArea                               = "AXGrowArea" //(id) - UIElement for grow box (or nil)
    case modal                                  = "AXModal" //(NSNumber *) - (boolValue) is the window modal
    case defaultButton                          = "AXDefaultButton" //(id) - UIElement for default button
    case cancelButton                           = "AXCancelButton" //(id) - UIElement for cancel button
    case fullScreenButton                       = "AXFullScreenButton" //(id) - UIElement for full screen button (or nil)
    /// - note: private/undocumented attribute
    case fullScreen                             = "AXFullScreen" //(NSNumber *) - (boolValue) is the window fullscreen

    // Application-specific attributes
    case menuBar                                = "AXMenuBar" //(id)         - UIElement for the menu bar
    case windows                                = "AXWindows" //(NSArray *)  - UIElements for the windows
    case frontmost                              = "AXFrontmost" //(NSNumber *) - (boolValue) is the app active?
    case hidden                                 = "AXHidden" //(NSNumber *) - (boolValue) is the app hidden?
    case mainWindow                             = "AXMainWindow" //(id)         - UIElement for the main window.
    case focusedWindow                          = "AXFocusedWindow" //(id)         - UIElement for the key window.
    case focusedUIElement                       = "AXFocusedUIElement" //(id)         - Currently focused UIElement.
    case extrasMenuBar                          = "AXExtrasMenuBar" //(id)         - UIElement for the application extras menu bar.
    /// - note: private/undocumented attribute
    case enhancedUserInterface                  = "AXEnhancedUserInterface" //(NSNumber *) - (boolValue) is the enhanced user interface active?

    case orientation                            = "AXOrientation" //(NSString *) - NSAccessibilityXXXOrientationValue

    case columnTitles                           = "AXColumnTitles" //(NSArray *)  - UIElements for titles

    case searchButton                           = "AXSearchButton" //(id)         - UIElement for search field search btn
    case searchMenu                             = "AXSearchMenu" //(id)         - UIElement for search field menu
    case clearButton                            = "AXClearButton" //(id)         - UIElement for search field clear btn

    // Table/outline view attributes
    case rows                                   = "AXRows" //(NSArray *)  - UIElements for rows
    case visibleRows                            = "AXVisibleRows" //(NSArray *)  - UIElements for visible rows
    case selectedRows                           = "AXSelectedRows" //(NSArray *)  - UIElements for selected rows
    case columns                                = "AXColumns" //(NSArray *)  - UIElements for columns
    case visibleColumns                         = "AXVisibleColumns" //(NSArray *)  - UIElements for visible columns
    case selectedColumns                        = "AXSelectedColumns" //(NSArray *)  - UIElements for selected columns
    case sortDirection                          = "AXSortDirection" //(NSString *) - see sort direction values below

    // Cell-based table attributes
    case selectedCells                          = "AXSelectedCells" //(NSArray *)  - UIElements for selected cells
    case visibleCells                           = "AXVisibleCells" //(NSArray *)  - UIElements for visible cells
    case rowHeaderUIElements                    = "AXRowHeaderUIElements" //(NSArray *)  - UIElements for row headers
    case columnHeaderUIElements                 = "AXColumnHeaderUIElements" //(NSArray *)  - UIElements for column headers

    // Cell-based table parameterized attributes.  The parameter for this attribute is an NSArray containing two NSNumbers, the first NSNumber specifies the column index, the second NSNumber specifies the row index.
    case cellForColumnAndRowParameterized       = "AXCellForColumnAndRowParameterized" // (id) - UIElement for cell at specified row and column

    // Cell attributes.  The index range contains both the starting index, and the index span in a table.
    case rowIndexRange                          = "AXRowIndexRange" //(NSValue *)  - (rangeValue) location and row span
    case columnIndexRange                       = "AXColumnIndexRange" //(NSValue *)  - (rangeValue) location and column span

    // Layout area attributes
    case horizontalUnits                        = "AXHorizontalUnits" //(NSString *) - see ruler unit values below
    case verticalUnits                          = "AXVerticalUnits" //(NSString *) - see ruler unit values below
    case horizontalUnitDescription              = "AXHorizontalUnitDescription" //(NSString *)
    case verticalUnitDescription                = "AXVerticalUnitDescription" //(NSString *)

    // Layout area parameterized attributes
    case layoutPointForScreenPointParameterized = "AXLayoutPointForScreenPointParameterized" //(NSValue *)  - (pointValue); param:(NSValue * - pointValue)
    case layoutSizeForScreenSizeParameterized   = "AXLayoutSizeForScreenSizeParameterized" //(NSValue *)  - (sizeValue); param:(NSValue * - sizeValue)
    case screenPointForLayoutPointParameterized = "AXScreenPointForLayoutPointParameterized" //(NSValue *)  - (pointValue); param:(NSValue * - pointValue)
    case screenSizeForLayoutSizeParameterized   = "AXScreenSizeForLayoutSizeParameterized" //(NSValue *)  - (sizeValue); param:(NSValue * - sizeValue)

    // Layout item attributes
    case handles                                = "AXHandles" //(NSArray *)  - UIElements for handles

    // Outline attributes
    case disclosing                             = "AXDisclosing" //(NSNumber *) - (boolValue) is disclosing rows?
    case disclosedRows                          = "AXDisclosedRows" //(NSArray *)  - UIElements for disclosed rows
    case disclosedByRow                         = "AXDisclosedByRow" //(id)         - UIElement for disclosing row
    case disclosureLevel                        = "AXDisclosureLevel" //(NSNumber *) - indentation level

    // Slider attributes
    case allowedValues                          = "AXAllowedValues" //(NSArray<NSNumber *> *) - array of allowed values
    case labelUIElements                        = "AXLabelUIElements" //(NSArray *) - array of label UIElements
    case labelValue                             = "AXLabelValue" //(NSNumber *) - value of a label UIElement

    // Matte attributes
    // Attributes no longer supported
    case matteHole                              = "AXMatteHole" //(NSValue *) - (rect value) bounds of matte hole in screen coords
    case matteContentUIElement                  = "AXMatteContentUIElement" //(id) - UIElement clipped by the matte

    // Ruler view attributes
    case markerUIElements                       = "AXMarkerUIElements" //(NSArray *)
    case markerValues                           = "AXMarkerValues" //
    case markerGroupUIElement                   = "AXMarkerGroupUIElement" //(id)
    case units                                  = "AXUnits" //(NSString *) - see ruler unit values below
    case unitDescription                        = "AXUnitDescription" //(NSString *)
    case markerType                             = "AXMarkerType" //(NSString *) - see ruler marker type values below
    case markerTypeDescription                  = "AXMarkerTypeDescription" //(NSString *)

    // UI element identification attributes
    case identifier                             = "AXIdentifier" //(NSString *)

    // System-wide attributes
    case focusedApplication                     = "AXFocusedApplication"

    // Unknown attributes
    case functionRowTopLevelElements            = "AXFunctionRowTopLevelElements"
    case childrenInNavigationOrder              = "AXChildrenInNavigationOrder"
}
enum Role: String {
    case unknown            = "AXUnknown"
    case button             = "AXButton"
    case radioButton        = "AXRadioButton"
    case checkBox           = "AXCheckBox"
    case slider             = "AXSlider"
    case tabGroup           = "AXTabGroup"
    case textField          = "AXTextField"
    case staticText         = "AXStaticText"
    case textArea           = "AXTextArea"
    case scrollArea         = "AXScrollArea"
    case popUpButton        = "AXPopUpButton"
    case menuButton         = "AXMenuButton"
    case table              = "AXTable"
    case application        = "AXApplication"
    case group              = "AXGroup"
    case radioGroup         = "AXRadioGroup"
    case list               = "AXList"
    case scrollBar          = "AXScrollBar"
    case valueIndicator     = "AXValueIndicator"
    case image              = "AXImage"
    case menuBar            = "AXMenuBar"
    case menu               = "AXMenu"
    case menuItem           = "AXMenuItem"
    case menuBarItem        = "AXMenuBarItem"
    case column             = "AXColumn"
    case row                = "AXRow"
    case toolbar            = "AXToolbar"
    case busyIndicator      = "AXBusyIndicator"
    case progressIndicator  = "AXProgressIndicator"
    case window             = "AXWindow"
    case drawer             = "AXDrawer"
    case systemWide         = "AXSystemWide"
    case outline            = "AXOutline"
    case incrementor        = "AXIncrementor"
    case browser            = "AXBrowser"
    case comboBox           = "AXComboBox"
    case splitGroup         = "AXSplitGroup"
    case splitter           = "AXSplitter"
    case colorWell          = "AXColorWell"
    case growArea           = "AXGrowArea"
    case sheet              = "AXSheet"
    case helpTag            = "AXHelpTag"
    case matte              = "AXMatte"
    case ruler              = "AXRuler"
    case rulerMarker        = "AXRulerMarker"
    case link               = "AXLink"
    case disclosureTriangle = "AXDisclosureTriangle"
    case grid               = "AXGrid"
    case relevanceIndicator = "AXRelevanceIndicator"
    case levelIndicator     = "AXLevelIndicator"
    case cell               = "AXCell"
    case popover            = "AXPopover"
    case layoutArea         = "AXLayoutArea"
    case layoutItem         = "AXLayoutItem"
    case handle             = "AXHandle"
}
enum Subrole: String {
    case unknown              = "AXUnknown"
    case closeButton          = "AXCloseButton"
    case zoomButton           = "AXZoomButton"
    case minimizeButton       = "AXMinimizeButton"
    case toolbarButton        = "AXToolbarButton"
    case tableRow             = "AXTableRow"
    case outlineRow           = "AXOutlineRow"
    case secureTextField      = "AXSecureTextField"
    case standardWindow       = "AXStandardWindow"
    case dialog               = "AXDialog"
    case systemDialog         = "AXSystemDialog"
    case floatingWindow       = "AXFloatingWindow"
    case systemFloatingWindow = "AXSystemFloatingWindow"
    case incrementArrow       = "AXIncrementArrow"
    case decrementArrow       = "AXDecrementArrow"
    case incrementPage        = "AXIncrementPage"
    case decrementPage        = "AXDecrementPage"
    case searchField          = "AXSearchField"
    case textAttachment       = "AXTextAttachment"
    case textLink             = "AXTextLink"
    case timeline             = "AXTimeline"
    case sortButton           = "AXSortButton"
    case ratingIndicator      = "AXRatingIndicator"
    case contentList          = "AXContentList"
    case definitionList       = "AXDefinitionList"
    case fullScreenButton     = "AXFullScreenButton"
    case toggle               = "AXToggle"
    case switchSubrole        = "AXSwitch"
    case descriptionList      = "AXDescriptionList"
}
@discardableResult
func checkIsProcessTrusted(prompt: Bool = false) -> Bool {
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let opts = [promptKey: prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(opts)
}
//
// KeyEvent.swift
// KeySender
//

import Carbon.HIToolbox
import CoreGraphics

// MARK: - KeyEvent

/// A representation of a key event that can be sent by an
/// instance of `KeySender`.
struct KeyEvent {
    /// The key associated with this key event.
    var key: Key

    /// The modifier keys associated with this key event.
    var modifiers: [Modifier]

    /// Creates a key event with the given keys and modifiers.
    init(key: Key, modifiers: [Modifier]) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Creates a key event with the given keys and modifiers.
    init(key: Key, modifiers: Modifier...) {
        self.init(key: key, modifiers: modifiers)
    }
}

extension KeyEvent: Codable { }

extension KeyEvent: Equatable { }

extension KeyEvent: Hashable { }

// MARK: - KeyEvent.Key

extension KeyEvent {
    /// Constants that represent the various keys available on a keyboard.
    enum Key: CaseIterable {

        // MARK: ANSI

        /// The ANSI A key.
        case a
        /// The ANSI B key.
        case b
        /// The ANSI C key.
        case c
        /// The ANSI D key.
        case d
        /// The ANSI E key.
        case e
        /// The ANSI F key.
        case f
        /// The ANSI G key.
        case g
        /// The ANSI H key.
        case h
        /// The ANSI I key.
        case i
        /// The ANSI J key.
        case j
        /// The ANSI K key.
        case k
        /// The ANSI L key.
        case l
        /// The ANSI M key.
        case m
        /// The ANSI N key.
        case n
        /// The ANSI O key.
        case o
        /// The ANSI P key.
        case p
        /// The ANSI Q key.
        case q
        /// The ANSI R key.
        case r
        /// The ANSI S key.
        case s
        /// The ANSI T key.
        case t
        /// The ANSI U key.
        case u
        /// The ANSI V key.
        case v
        /// The ANSI W key.
        case w
        /// The ANSI X key.
        case x
        /// The ANSI Y key.
        case y
        /// The ANSI Z key.
        case z

        /// The ANSI 0 key.
        case zero
        /// The ANSI 1 key.
        case one
        /// The ANSI 2 key.
        case two
        /// The ANSI 3 key.
        case three
        /// The ANSI 4 key.
        case four
        /// The ANSI 5 key.
        case five
        /// The ANSI 6 key.
        case six
        /// The ANSI 7 key.
        case seven
        /// The ANSI 8 key.
        case eight
        /// The ANSI 9 key.
        case nine

        /// The ANSI "-" key.
        case minus
        /// The ANSI "=" key.
        case equal
        /// The ANSI "[" key.
        case leftBracket
        /// The ANSI "]" key.
        case rightBracket
        /// The ANSI "\\" key.
        case backslash
        /// The ANSI ";" key.
        case semicolon
        /// The ANSI "'" key.
        case quote
        /// The ANSI "," key.
        case comma
        /// The ANSI "." key.
        case period
        /// The ANSI "/" key.
        case slash
        /// The ANSI "`" key.
        case grave

        /// The ANSI keypad Decimal key.
        case keypadDecimal
        /// The ANSI keypad Multiply key.
        case keypadMultiply
        /// The ANSI keypad Plus key.
        case keypadPlus
        /// The ANSI keypad Clear key.
        case keypadClear
        /// The ANSI keypad Divide key.
        case keypadDivide
        /// The ANSI keypad Enter key.
        case keypadEnter
        /// The ANSI keypad Minus key.
        case keypadMinus
        /// The ANSI keypad Equals key.
        case keypadEquals
        /// The ANSI keypad 0 key.
        case keypad0
        /// The ANSI keypad 1 key.
        case keypad1
        /// The ANSI keypad 2 key.
        case keypad2
        /// The ANSI keypad 3 key.
        case keypad3
        /// The ANSI keypad 4 key.
        case keypad4
        /// The ANSI keypad 5 key.
        case keypad5
        /// The ANSI keypad 6 key.
        case keypad6
        /// The ANSI keypad 7 key.
        case keypad7
        /// The ANSI keypad 8 key.
        case keypad8
        /// The ANSI keypad 9 key.
        case keypad9

        // MARK: Layout-independent

        /// The layout-independent Return key.
        case `return`
        /// The layout-independent Tab key.
        case tab
        /// The layout-independent Space key.
        case space
        /// The layout-independent Delete key.
        case delete
        /// The layout-independent Forward Felete key.
        case forwardDelete
        /// The layout-independent Escape key.
        case escape
        /// The layout-independent Volume Up key.
        case volumeUp
        /// The layout-independent Volume Down key.
        case volumeDown
        /// The layout-independent Mute key.
        case mute
        /// The layout-independent Home key.
        case home
        /// The layout-independent End key.
        case end
        /// The layout-independent Page Up key.
        case pageUp
        /// The layout-independent Page Down key.
        case pageDown

        /// The layout-independent Left Arrow key.
        case leftArrow
        /// The layout-independent Right Arrow key.
        case rightArrow
        /// The layout-independent Down Arrow key.
        case downArrow
        /// The layout-independent Up Arrow key.
        case upArrow

        /// The layout-independent F1 key.
        case f1
        /// The layout-independent F2 key.
        case f2
        /// The layout-independent F3 key.
        case f3
        /// The layout-independent F4 key.
        case f4
        /// The layout-independent F5 key.
        case f5
        /// The layout-independent F6 key.
        case f6
        /// The layout-independent F7 key.
        case f7
        /// The layout-independent F8 key.
        case f8
        /// The layout-independent F9 key.
        case f9
        /// The layout-independent F10 key.
        case f10
        /// The layout-independent F11 key.
        case f11
        /// The layout-independent F12 key.
        case f12
        /// The layout-independent F13 key.
        case f13
        /// The layout-independent F14 key.
        case f14
        /// The layout-independent F15 key.
        case f15
        /// The layout-independent F16 key.
        case f16
        /// The layout-independent F17 key.
        case f17
        /// The layout-independent F18 key.
        case f18
        /// The layout-independent F19 key.
        case f19
        /// The layout-independent F20 key.
        case f20

        // MARK: ISO

        /// The Section key that is available on ISO keyboards.
        case isoSection

        // MARK: JIS

        /// The Yen key that is available on JIS keyboards.
        case jisYen
        /// The Underscore key that is available on JIS keyboards.
        case jisUnderscore
        /// The Comma key that is available on JIS keyboard keypads.
        case jisKeypadComma
        /// The Eisu key that is available on JIS keyboards.
        case jisEisu
        /// The Kana key that is available on JIS keyboards.
        case jisKana

        // MARK: Instance Properties

        /// The raw value of this key.
        var rawValue: Int {
            switch self {
            case .a:
                return kVK_ANSI_A
            case .b:
                return kVK_ANSI_B
            case .c:
                return kVK_ANSI_C
            case .d:
                return kVK_ANSI_D
            case .e:
                return kVK_ANSI_E
            case .f:
                return kVK_ANSI_F
            case .g:
                return kVK_ANSI_G
            case .h:
                return kVK_ANSI_H
            case .i:
                return kVK_ANSI_I
            case .j:
                return kVK_ANSI_J
            case .k:
                return kVK_ANSI_K
            case .l:
                return kVK_ANSI_L
            case .m:
                return kVK_ANSI_M
            case .n:
                return kVK_ANSI_N
            case .o:
                return kVK_ANSI_O
            case .p:
                return kVK_ANSI_P
            case .q:
                return kVK_ANSI_Q
            case .r:
                return kVK_ANSI_R
            case .s:
                return kVK_ANSI_S
            case .t:
                return kVK_ANSI_T
            case .u:
                return kVK_ANSI_U
            case .v:
                return kVK_ANSI_V
            case .w:
                return kVK_ANSI_W
            case .x:
                return kVK_ANSI_X
            case .y:
                return kVK_ANSI_Y
            case .z:
                return kVK_ANSI_Z
            case .zero:
                return kVK_ANSI_0
            case .one:
                return kVK_ANSI_1
            case .two:
                return kVK_ANSI_2
            case .three:
                return kVK_ANSI_3
            case .four:
                return kVK_ANSI_4
            case .five:
                return kVK_ANSI_5
            case .six:
                return kVK_ANSI_6
            case .seven:
                return kVK_ANSI_7
            case .eight:
                return kVK_ANSI_8
            case .nine:
                return kVK_ANSI_9
            case .minus:
                return kVK_ANSI_Minus
            case .equal:
                return kVK_ANSI_Equal
            case .leftBracket:
                return kVK_ANSI_LeftBracket
            case .rightBracket:
                return kVK_ANSI_RightBracket
            case .backslash:
                return kVK_ANSI_Backslash
            case .semicolon:
                return kVK_ANSI_Semicolon
            case .quote:
                return kVK_ANSI_Quote
            case .comma:
                return kVK_ANSI_Comma
            case .period:
                return kVK_ANSI_Period
            case .slash:
                return kVK_ANSI_Slash
            case .grave:
                return kVK_ANSI_Grave
            case .keypadDecimal:
                return kVK_ANSI_KeypadDecimal
            case .keypadMultiply:
                return kVK_ANSI_KeypadMultiply
            case .keypadPlus:
                return kVK_ANSI_KeypadPlus
            case .keypadClear:
                return kVK_ANSI_KeypadClear
            case .keypadDivide:
                return kVK_ANSI_KeypadDivide
            case .keypadEnter:
                return kVK_ANSI_KeypadEnter
            case .keypadMinus:
                return kVK_ANSI_KeypadMinus
            case .keypadEquals:
                return kVK_ANSI_KeypadEquals
            case .keypad0:
                return kVK_ANSI_Keypad0
            case .keypad1:
                return kVK_ANSI_Keypad1
            case .keypad2:
                return kVK_ANSI_Keypad2
            case .keypad3:
                return kVK_ANSI_Keypad3
            case .keypad4:
                return kVK_ANSI_Keypad4
            case .keypad5:
                return kVK_ANSI_Keypad5
            case .keypad6:
                return kVK_ANSI_Keypad6
            case .keypad7:
                return kVK_ANSI_Keypad7
            case .keypad8:
                return kVK_ANSI_Keypad8
            case .keypad9:
                return kVK_ANSI_Keypad9
            case .return:
                return kVK_Return
            case .tab:
                return kVK_Tab
            case .space:
                return kVK_Space
            case .delete:
                return kVK_Delete
            case .forwardDelete:
                return kVK_ForwardDelete
            case .escape:
                return kVK_Escape
            case .volumeUp:
                return kVK_VolumeUp
            case .volumeDown:
                return kVK_VolumeDown
            case .mute:
                return kVK_Mute
            case .home:
                return kVK_Home
            case .end:
                return kVK_End
            case .pageUp:
                return kVK_PageUp
            case .pageDown:
                return kVK_PageDown
            case .leftArrow:
                return kVK_LeftArrow
            case .rightArrow:
                return kVK_RightArrow
            case .downArrow:
                return kVK_DownArrow
            case .upArrow:
                return kVK_UpArrow
            case .f1:
                return kVK_F1
            case .f2:
                return kVK_F2
            case .f3:
                return kVK_F3
            case .f4:
                return kVK_F4
            case .f5:
                return kVK_F5
            case .f6:
                return kVK_F6
            case .f7:
                return kVK_F7
            case .f8:
                return kVK_F8
            case .f9:
                return kVK_F9
            case .f10:
                return kVK_F10
            case .f11:
                return kVK_F11
            case .f12:
                return kVK_F12
            case .f13:
                return kVK_F13
            case .f14:
                return kVK_F14
            case .f15:
                return kVK_F15
            case .f16:
                return kVK_F16
            case .f17:
                return kVK_F17
            case .f18:
                return kVK_F18
            case .f19:
                return kVK_F19
            case .f20:
                return kVK_F20
            case .isoSection:
                return kVK_ISO_Section
            case .jisYen:
                return kVK_JIS_Yen
            case .jisUnderscore:
                return kVK_JIS_Underscore
            case .jisKeypadComma:
                return kVK_JIS_KeypadComma
            case .jisEisu:
                return kVK_JIS_Eisu
            case .jisKana:
                return kVK_JIS_Kana
            }
        }

        /// A string representation of the key.
        var stringValue: String {
            switch self {
            case .a:
                return "a"
            case .b:
                return "b"
            case .c:
                return "c"
            case .d:
                return "d"
            case .e:
                return "e"
            case .f:
                return "f"
            case .g:
                return "g"
            case .h:
                return "h"
            case .i:
                return "i"
            case .j:
                return "j"
            case .k:
                return "k"
            case .l:
                return "l"
            case .m:
                return "m"
            case .n:
                return "n"
            case .o:
                return "o"
            case .p:
                return "p"
            case .q:
                return "q"
            case .r:
                return "r"
            case .s:
                return "s"
            case .t:
                return "t"
            case .u:
                return "u"
            case .v:
                return "v"
            case .w:
                return "w"
            case .x:
                return "x"
            case .y:
                return "y"
            case .z:
                return "z"
            case .zero:
                return "0"
            case .one:
                return "1"
            case .two:
                return "2"
            case .three:
                return "3"
            case .four:
                return "4"
            case .five:
                return "5"
            case .six:
                return "6"
            case .seven:
                return "7"
            case .eight:
                return "8"
            case .nine:
                return "9"
            case .minus:
                return "-"
            case .equal:
                return "="
            case .leftBracket:
                return "["
            case .rightBracket:
                return "]"
            case .backslash:
                return "\\"
            case .semicolon:
                return ";"
            case .quote:
                return "'"
            case .comma:
                return ","
            case .period:
                return "."
            case .slash:
                return "/"
            case .grave:
                return "`"
            case .keypadDecimal:
                return "."
            case .keypadMultiply:
                return "*"
            case .keypadPlus:
                return "+"
            case .keypadClear:
                return "⌧"
            case .keypadDivide:
                return "÷"
            case .keypadEnter:
                return "\n"
            case .keypadMinus:
                return "-"
            case .keypadEquals:
                return "="
            case .keypad0:
                return "0"
            case .keypad1:
                return "1"
            case .keypad2:
                return "2"
            case .keypad3:
                return "3"
            case .keypad4:
                return "4"
            case .keypad5:
                return "5"
            case .keypad6:
                return "6"
            case .keypad7:
                return "7"
            case .keypad8:
                return "8"
            case .keypad9:
                return "9"
            case .return:
                return "\n"
            case .tab:
                return "\t"
            case .space:
                return " "
            case .delete:
                return "⌫"
            case .forwardDelete:
                return "⌦"
            case .escape:
                return "⎋"
            case .volumeUp:
                return "􏿮"
            case .volumeDown:
                return "􏿮"
            case .mute:
                return "􏿮"
            case .home:
                return "⇱"
            case .end:
                return "⇲"
            case .pageUp:
                return "⇞"
            case .pageDown:
                return "⇟"
            case .leftArrow:
                return "←"
            case .rightArrow:
                return "→"
            case .downArrow:
                return "↓"
            case .upArrow:
                return "↑"
            case .f1:
                return "F1"
            case .f2:
                return "F2"
            case .f3:
                return "F3"
            case .f4:
                return "F4"
            case .f5:
                return "F5"
            case .f6:
                return "F6"
            case .f7:
                return "F7"
            case .f8:
                return "F8"
            case .f9:
                return "F9"
            case .f10:
                return "F10"
            case .f11:
                return "F11"
            case .f12:
                return "F12"
            case .f13:
                return "F13"
            case .f14:
                return "F14"
            case .f15:
                return "F15"
            case .f16:
                return "F16"
            case .f17:
                return "F17"
            case .f18:
                return "F18"
            case .f19:
                return "F19"
            case .f20:
                return "F20"
            case .isoSection:
                return "§"
            case .jisYen:
                return "¥"
            case .jisUnderscore:
                return "_"
            case .jisKeypadComma:
                return ","
            case .jisEisu:
                return "英数"
            case .jisKana:
                return "かな"
            }
        }

        // MARK: Initializers

        init?(_ string: String) {
            guard let key = Self.allCases.first(where: { $0.stringValue.lowercased() == string.lowercased() }) else {
                return nil
            }
            self = key
        }

        init?(_ character: Character) {
            self.init(String(character))
        }
    }
}

extension KeyEvent.Key: Codable { }

extension KeyEvent.Key: Equatable { }

extension KeyEvent.Key: Hashable { }

// MARK: - KeyEvent.Modifier

extension KeyEvent {
    /// Constants that represent modifier keys associated with a key event.
    enum Modifier {
        /// The Caps Lock key.
        case capsLock

        /// The Command key.
        case command

        /// The Control key.
        case control

        /// The Fn (Function) key.
        case function

        /// The Help key.
        case help

        /// A key on the numeric pad.
        case numPad

        /// The Option, or Alt key.
        case option

        /// The Shift key.
        case shift

        // MARK: Instance Properties

        var rawValue: CGEventFlags {
            switch self {
            case .capsLock:
                return .maskAlphaShift
            case .command:
                return .maskCommand
            case .control:
                return .maskControl
            case .function:
                return .maskSecondaryFn
            case .help:
                return .maskHelp
            case .numPad:
                return .maskNumericPad
            case .option:
                return .maskAlternate
            case .shift:
                return .maskShift
            }
        }

        /// A string representation of the modifier.
        var stringValue: String {
            switch self {
            case .capsLock:
                return "⇪"
            case .command:
                return "⌘"
            case .control:
                return "⌃"
            case .function:
                return "fn"
            case .help:
                return "􏿮"
            case .numPad:
                return "􏿮"
            case .option:
                return "⌥"
            case .shift:
                return "⇧"
            }
        }

        // MARK: Static Methods

        static func flags(for modifiers: [Self]) -> CGEventFlags {
            var flags = CGEventFlags()
            for modifier in modifiers {
                flags.insert(modifier.rawValue)
            }
            return flags
        }
    }
}

extension KeyEvent.Modifier: Codable { }

extension KeyEvent.Modifier: Equatable { }

extension KeyEvent.Modifier: Hashable { }
//
// KeySender.swift
// KeySender
//

import Cocoa

/// A type that can send key events to any running application.
///
/// To create a key sender, call one of its initializers. You can create an
/// instance with multiple key events that will be sent in succession, a single
/// key event, a key and some modifiers, or a string. You then call one of the
/// `send(to:)`, `trySend(to:)`, or `sendGlobally()` methods to send the event
/// to a running application of your choice.
///
/// As long as that application can accept the keys that you send, the effect
/// will be the same as if the keys had been entered manually.
///
/// ```swift
/// let sender = KeySender(key: .c, modifiers: .command)
/// try sender.send(to: "TextEdit")
///
/// let stringSender = KeySender(string: "Hello")
/// stringSender.trySend(to: "TextEdit")
/// ```
///
/// - Note: The application you send the key events to must currently be running,
///   or sending the events will fail.
struct KeySender {
    /// The events that will be sent by this key sender.
    let events: [KeyEvent]

    /// Creates a sender for the given key events.
    init(for events: [KeyEvent]) {
        self.events = events
    }

    /// Creates a sender for the given key events.
    init(for events: KeyEvent...) {
        self.events = events
    }

    /// Creates a sender for the given key event.
    init(for event: KeyEvent) {
        self.events = [event]
    }

    /// Creates a sender for the given key and modifiers.
    ///
    /// This initializer works by creating a `KeyEvent` behind the scenes, then adding
    /// it to the instance's `events` property.
    init(key: KeyEvent.Key, modifiers: [KeyEvent.Modifier]) {
        self.init(for: KeyEvent(key: key, modifiers: modifiers))
    }

    /// Creates a sender for the given key and modifiers.
    ///
    /// This initializer works by creating a `KeyEvent` behind the scenes, then adding
    /// it to the instance's `events` property.
    init(key: KeyEvent.Key, modifiers: KeyEvent.Modifier...) {
        self.init(for: KeyEvent(key: key, modifiers: modifiers))
    }

    /// Creates a key sender for the given string.
    ///
    /// This initializer throws an error if the string contains an invalid character.
    /// Valid characters are those that appear on the keyboard, and that can be typed
    /// without the use of any modifiers. The exception is capital letters, which are
    /// valid. However, any character that requires a modifier key to be pressed, such
    /// as Shift-1 (for "!"), are invalid characters. To send one of these characters,
    /// use one of the other initializers to construct a key event using the key and
    /// modifiers necessary to type the character.
    init(for string: String) throws {
        var events = [KeyEvent]()
        for character in string {
            guard let key = KeyEvent.Key(character) else {
                throw KeySenderError("Invalid character. Cannot create key event.")
            }
            let event: KeyEvent
            if character.isUppercase {
                event = KeyEvent(key: key, modifiers: [.shift])
            } else {
                event = KeyEvent(key: key, modifiers: [])
            }
            events.append(event)
        }
        self.events = events
    }
}

// MARK: - Helper Methods

extension KeySender {
    // Tries to convert a string into an NSRunningApplication.
    private func target(from string: String) throws -> NSRunningApplication {
        guard let target = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == string }) else {
            throw KeySenderError("Application \"\(string)\" not currently running.")
        }
        return target
    }

    private func cgEvent(from keyEvent: KeyEvent, keyDown: Bool) -> CGEvent? {
        let event = CGEvent(
            keyboardEventSource: CGEventSource(stateID: .hidSystemState),
            virtualKey: CGKeyCode(keyEvent.key.rawValue),
            keyDown: keyDown
        )
        event?.flags = KeyEvent.Modifier.flags(for: keyEvent.modifiers)
        return event
    }

    // All local send methods delegate to this one.
    private func sendLocally(event: KeyEvent, application: NSRunningApplication, sendKeyUp: Bool) {
        cgEvent(from: event, keyDown: true)?.postToPid(application.processIdentifier)
        if sendKeyUp {
            cgEvent(from: event, keyDown: false)?.postToPid(application.processIdentifier)
        }
    }

    // All global send methods delegate to this one.
    private func sendGlobally(event: KeyEvent, sendKeyUp: Bool) {
        cgEvent(from: event, keyDown: true)?.post(tap: .cghidEventTap)
        if sendKeyUp {
            cgEvent(from: event, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Main Methods

extension KeySender {
    /// Sends this instance's events to the given running application.
    ///
    /// - Parameter application: An instance of `NSRunningApplication` that will receive
    ///   the event.
    func send(to application: NSRunningApplication, sendKeyUp: Bool = true) {
        for event in events {
            sendLocally(event: event, application: application, sendKeyUp: sendKeyUp)
        }
    }

    /// Sends this instance's events to the application with the given name.
    ///
    /// - Parameter application: The name of the application that will receive the event.
    func send(to application: String, sendKeyUp: Bool = true) throws {
        try send(to: target(from: application), sendKeyUp: sendKeyUp)
    }

    /// Attempts to send this instance's events to the application with the given name,
    /// printing an error to the console if the operation fails.
    ///
    /// - Parameter application: The name of the application that will receive the event.
    func trySend(to application: String, sendKeyUp: Bool = true) {
        do {
            try send(to: application, sendKeyUp: sendKeyUp)
        } catch {
            print(error.localizedDescription)
        }
    }

    /// Sends this instance's events globally, making the events visible to the system,
    /// rather than a single application.
    func sendGlobally(sendKeyUp: Bool = true) {
        for event in events {
            sendGlobally(event: event, sendKeyUp: sendKeyUp)
        }
    }

    /// Sends this instance's events to the application that has focus in the shared
    /// workspace.
    func sendToFrontmostApplication(sendKeyUp: Bool = true) throws {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            throw KeySenderError("No frontmost application exists.")
        }
        send(to: application)
    }

    /// Sends this instance's events to every running application.
    func sendToAllApplications(sendKeyUp: Bool = true) {
        for application in NSWorkspace.shared.runningApplications {
            send(to: application, sendKeyUp: sendKeyUp)
        }
    }

    /// Sends this instance's events to every running application that matches the
    /// given predicate.
    func send(where predicate: (NSRunningApplication) throws -> Bool) rethrows {
        for application in NSWorkspace.shared.runningApplications where try predicate(application) {
            send(to: application)
        }
    }

    /// Opens the given application (if it is not already open), and sends this
    /// instance's events.
    func openApplicationAndSend(_ application: String) throws {
        if let application = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.lowercased() == application.lowercased()
        }) {
            send(to: application)
        } else {
            let process = Process()
            process.arguments = ["-a", application]
            if #available(macOS 10.13, *) {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                try process.run()
            } else {
                process.launchPath = "/usr/bin/open"
                process.launch()
            }
            process.waitUntilExit()
            try openApplicationAndSend(application)
        }
    }
}
//
// KeySenderError.swift
// KeySender
//

import Foundation

/// An error that can be thrown during a key sending operation.
struct KeySenderError: LocalizedError {
    /// The message accompanying this error.
    let message: String

    var errorDescription: String? { message }

    /// Creates an error with the given message.
    init(_ message: String) {
        self.message = message
    }
}

/// A `UIElement` for an application.
final class Application: UIElement {
    // Creates a UIElement for the given process ID.
    // Does NOT check if the given process actually exists, just checks for a valid ID.
    convenience init?(forKnownProcessID processID: pid_t) {
        let appElement = AXUIElementCreateApplication(processID)
        self.init(appElement)

        if processID < 0 {
            return nil
        }
    }

    /// Creates an `Application` from a `NSRunningApplication` instance.
    /// - returns: The `Application`, or `nil` if the given application is not running.
    convenience init?(_ app: NSRunningApplication) {
        if app.isTerminated {
            return nil
        }
        self.init(forKnownProcessID: app.processIdentifier)
    }

    /// Create an `Application` from the process ID of a running application.
    /// - returns: The `Application`, or `nil` if the PID is invalid or the given application
    ///            is not running.
    convenience init?(forProcessID processID: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: processID) else {
            return nil
        }
        self.init(app)
    }

    /// Creates an `Application` for every running application with a UI.
    /// - returns: An array of `Application`s.
    class func all() -> [Application] {
        let runningApps = NSWorkspace.shared.runningApplications
        return runningApps
            .filter({ $0.activationPolicy != .prohibited })
            .compactMap({ Application($0) })
    }

    /// Creates an `Application` for every running instance of the given `bundleID`.
    /// - returns: A (potentially empty) array of `Application`s.
    class func allForBundleID(_ bundleID: String) -> [Application] {
        let runningApps = NSWorkspace.shared.runningApplications
        return runningApps
            .filter({ $0.bundleIdentifier == bundleID })
            .compactMap({ Application($0) })
    }

    /// Creates an `Observer` on this application, if it is still alive.
    func createObserver(_ callback: @escaping Observer.Callback) -> Observer? {
        do {
            return try Observer(processID: try pid(), callback: callback)
        } catch AXError.invalidUIElement {
            return nil
        } catch let error {
            fatalError("Caught unexpected error creating observer: \(error)")
        }
    }

    /// Creates an `Observer` on this application, if it is still alive.
    func createObserver(_ callback: @escaping Observer.CallbackWithInfo) -> Observer? {
        do {
            return try Observer(processID: try pid(), callback: callback)
        } catch AXError.invalidUIElement {
            return nil
        } catch let error {
            fatalError("Caught unexpected error creating observer: \(error)")
        }
    }

    /// Returns a list of the application's visible windows.
    /// - returns: An array of `UIElement`s, one for every visible window. Or `nil` if the list
    ///            cannot be retrieved.
    func windows() throws -> [UIElement]? {
        let axWindows: [AXUIElement]? = try attribute("AXWindows")
        return axWindows?.map({ UIElement($0) })
    }

    /// Returns the element at the specified top-down coordinates, or nil if there is none.
    override func elementAtPosition(_ x: Float, _ y: Float) throws -> UIElement? {
        return try super.elementAtPosition(x, y)
    }
}
import Cocoa
import Foundation
import Darwin

/// Observers watch for events on an application's UI elements.
///
/// Events are received as part of the application's default run loop.
///
/// - seeAlso: `UIElement` for a list of exceptions that can be thrown.
final class Observer {
    typealias Callback = (_ observer: Observer,
                                 _ element: UIElement,
                                 _ notification: AXNotification) -> Void
    typealias CallbackWithInfo = (_ observer: Observer,
                                         _ element: UIElement,
                                         _ notification: AXNotification,
                                         _ info: [String: AnyObject]?) -> Void

    let pid: pid_t
    let axObserver: AXObserver!
    let callback: Callback?
    let callbackWithInfo: CallbackWithInfo?

    fileprivate(set) lazy var application: Application =
        Application(forKnownProcessID: self.pid)!

    /// Creates and starts an observer on the given `processID`.
    init(processID: pid_t, callback: @escaping Callback) throws {
        var axObserver: AXObserver?
        let error = AXObserverCreate(processID, internalCallback, &axObserver)

        pid = processID
        self.axObserver = axObserver
        self.callback = callback
        callbackWithInfo = nil

        guard error == .success else {
            throw error
        }
        assert(axObserver != nil)

        start()
    }

    /// Creates and starts an observer on the given `processID`.
    ///
    /// Use this initializer if you want the extra user info provided with notifications.
    /// - seeAlso: [UserInfo Keys for Posting Accessibility Notifications](https://developer.apple.com/library/mac/documentation/AppKit/Reference/NSAccessibility_Protocol_Reference/index.html#//apple_ref/doc/constant_group/UserInfo_Keys_for_Posting_Accessibility_Notifications)
    init(processID: pid_t, callback: @escaping CallbackWithInfo) throws {
        var axObserver: AXObserver?
        let error = AXObserverCreateWithInfoCallback(processID, internalInfoCallback, &axObserver)

        pid = processID
        self.axObserver = axObserver
        self.callback = nil
        callbackWithInfo = callback

        guard error == .success else {
            throw error
        }
        assert(axObserver != nil)

        start()
    }

    deinit {
        stop()
    }

    /// Starts watching for events. You don't need to call this method unless you use `stop()`.
    ///
    /// If the observer has already been started, this method does nothing.
    func start() {
        CFRunLoopAddSource(
            RunLoop.current.getCFRunLoop(),
            AXObserverGetRunLoopSource(axObserver),
            CFRunLoopMode.defaultMode)
    }

    /// Stops sending events to your callback until the next call to `start`.
    ///
    /// If the observer has already been started, this method does nothing.
    ///
    /// - important: Events will still be queued in the target process until the Observer is started
    ///              again or destroyed. If you don't want them, create a new Observer.
    func stop() {
        CFRunLoopRemoveSource(
            RunLoop.current.getCFRunLoop(),
            AXObserverGetRunLoopSource(axObserver),
            CFRunLoopMode.defaultMode)
    }

    /// Adds a notification for the observer to watch.
    ///
    /// - parameter notification: The name of the notification to watch for.
    /// - parameter forElement: The element to watch for the notification on. Must belong to the
    ///                         application this observer was created on.
    /// - seeAlso: [Notificatons](https://developer.apple.com/library/mac/documentation/AppKit/Reference/NSAccessibility_Protocol_Reference/index.html#//apple_ref/c/data/NSAccessibilityAnnouncementRequestedNotification)
    /// - note: The underlying API returns an error if the notification is already added, but that
    ///         error is not passed on for consistency with `start()` and `stop()`.
    /// - throws: `Error.NotificationUnsupported`: The element does not support notifications (note
    ///           that the system-wide element does not support notifications).
    func addNotification(_ notification: AXNotification,
                                forElement element: UIElement) throws {
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let error = AXObserverAddNotification(
            axObserver, element.element, notification.rawValue as CFString, selfPtr
        )
        guard error == .success || error == .notificationAlreadyRegistered else {
            throw error
        }
    }

    /// Removes a notification from the observer.
    ///
    /// - parameter notification: The name of the notification to stop watching.
    /// - parameter forElement: The element to stop watching the notification on.
    /// - note: The underlying API returns an error if the notification is not present, but that
    ///         error is not passed on for consistency with `start()` and `stop()`.
    /// - throws: `Error.NotificationUnsupported`: The element does not support notifications (note
    ///           that the system-wide element does not support notifications).
    func removeNotification(_ notification: AXNotification,
                                   forElement element: UIElement) throws {
        let error = AXObserverRemoveNotification(
            axObserver, element.element, notification.rawValue as CFString
        )
        guard error == .success || error == .notificationNotRegistered else {
            throw error
        }
    }
}

private func internalCallback(_ axObserver: AXObserver,
                              axElement: AXUIElement,
                              notification: CFString,
                              userData: UnsafeMutableRawPointer?) {
    guard let userData = userData else { fatalError("userData should be an AXSwift.Observer") }

    let observer = Unmanaged<Observer>.fromOpaque(userData).takeUnretainedValue()
    let element = UIElement(axElement)
    guard let notif = AXNotification(rawValue: notification as String) else {
        NSLog("Unknown AX notification %s received", notification as String)
        return
    }
    observer.callback!(observer, element, notif)
}

private func internalInfoCallback(_ axObserver: AXObserver,
                                  axElement: AXUIElement,
                                  notification: CFString,
                                  cfInfo: CFDictionary,
                                  userData: UnsafeMutableRawPointer?) {
    guard let userData = userData else { fatalError("userData should be an AXSwift.Observer") }

    let observer = Unmanaged<Observer>.fromOpaque(userData).takeUnretainedValue()
    let element = UIElement(axElement)
    let info = cfInfo as NSDictionary? as! [String: AnyObject]?
    guard let notif = AXNotification(rawValue: notification as String) else {
        NSLog("Unknown AX notification %s received", notification as String)
        return
    }
    observer.callbackWithInfo!(observer, element, notif, info)
}
enum AXNotification: String {
    // Focus notifications
    case mainWindowChanged       = "AXMainWindowChanged"
    case focusedWindowChanged    = "AXFocusedWindowChanged"
    case focusedUIElementChanged = "AXFocusedUIElementChanged"
    case focusedTabChanged       = "AXFocusedTabChanged"

    // Application notifications
    case applicationActivated    = "AXApplicationActivated"
    case applicationDeactivated  = "AXApplicationDeactivated"
    case applicationHidden       = "AXApplicationHidden"
    case applicationShown        = "AXApplicationShown"

    // Window notifications
    case windowCreated           = "AXWindowCreated"
    case windowMoved             = "AXWindowMoved"
    case windowResized           = "AXWindowResized"
    case windowMiniaturized      = "AXWindowMiniaturized"
    case windowDeminiaturized    = "AXWindowDeminiaturized"

    // Drawer & sheet notifications
    case drawerCreated           = "AXDrawerCreated"
    case sheetCreated            = "AXSheetCreated"

    // Element notifications
    case uiElementDestroyed      = "AXUIElementDestroyed"
    case valueChanged            = "AXValueChanged"
    case titleChanged            = "AXTitleChanged"
    case resized                 = "AXResized"
    case moved                   = "AXMoved"
    case created                 = "AXCreated"

    // Used when UI changes require the attention of assistive application.  Pass along a user info
    // dictionary with the key NSAccessibilityUIElementsKey and an array of elements that have been
    // added or changed as a result of this layout change.
    case layoutChanged           = "AXLayoutChanged"

    // Misc notifications
    case helpTagCreated          = "AXHelpTagCreated"
    case selectedTextChanged     = "AXSelectedTextChanged"
    case rowCountChanged         = "AXRowCountChanged"
    case selectedChildrenChanged = "AXSelectedChildrenChanged"
    case selectedRowsChanged     = "AXSelectedRowsChanged"
    case selectedColumnsChanged  = "AXSelectedColumnsChanged"
    case loadComplete            = "AXLoadComplete"

    case rowExpanded             = "AXRowExpanded"
    case rowCollapsed            = "AXRowCollapsed"

    // Cell-table notifications
    case selectedCellsChanged    = "AXSelectedCellsChanged"

    // Layout area notifications
    case unitsChanged            = "AXUnitsChanged"
    case selectedChildrenMoved   = "AXSelectedChildrenMoved"

    // This notification allows an application to request that an announcement be made to the user
    // by an assistive application such as VoiceOver.  The notification requires a user info
    // dictionary with the key NSAccessibilityAnnouncementKey and the announcement as a localized
    // string.  In addition, the key NSAccessibilityAnnouncementPriorityKey should also be used to
    // help an assistive application determine the importance of this announcement.  This
    // notification should be posted for the application element.
    case announcementRequested   = "AXAnnouncementRequested"
}
