//
//  Copyright 2018 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import R2Shared
import SafariServices
import SwiftSoup
import UIKit
import WebKit

public protocol EPUBNavigatorDelegate: VisualNavigatorDelegate, SelectableNavigatorDelegate {

    // MARK: - WebView Customization

    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController)

    // MARK: - Deprecated
    
    // Implement `NavigatorDelegate.navigator(didTapAt:)` instead.
    func middleTapHandler()

    // Implement `NavigatorDelegate.navigator(locationDidChange:)` instead, to save the last read location.
    func willExitPublication(documentIndex: Int, progression: Double?)
    func didChangedDocumentPage(currentDocumentIndex: Int)
    func didNavigateViaInternalLinkTap(to documentIndex: Int)

    /// Implement `NavigatorDelegate.navigator(presentError:)` instead.
    func presentError(_ error: NavigatorError)
    
    func handleTapOnTrimmedInternalLink(link: String)

}

public extension EPUBNavigatorDelegate {

    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController) {}

    func middleTapHandler() {}
    func willExitPublication(documentIndex: Int, progression: Double?) {}
    func didChangedDocumentPage(currentDocumentIndex: Int) {}
    func didNavigateViaInternalLinkTap(to documentIndex: Int) {}
    func presentError(_ error: NavigatorError) {}
    func handleTapOnTrimmedInternalLink(link: String) {}
}


public typealias EPUBContentInsets = (top: CGFloat, bottom: CGFloat)

public typealias ScriptToExecute = (name: String, script: String)

open class EPUBNavigatorViewController: UIViewController, VisualNavigator, SelectableNavigator, DecorableNavigator, Loggable {

    public enum EPUBError: Error {
        /// Returned when calling evaluateJavaScript() before a resource is loaded.
        case spreadNotLoaded
    }

    public struct Configuration {
        /// Default user settings.
        public var userSettings: UserSettings

        /// Editing actions which will be displayed in the default text selection menu.
        ///
        /// The default set of editing actions is `EditingAction.defaultActions`.
        ///
        /// You can provide custom actions with `EditingAction(title: "Highlight", action: #selector(highlight:))`.
        /// Then, implement the selector in one of your classes in the responder chain. Typically, in the
        /// `UIViewController` wrapping the `EPUBNavigatorViewController`.
        public var editingActions: [EditingAction]

        /// Content insets used to add some vertical margins around reflowable EPUB publications.
        /// The insets can be configured for each size class to allow smaller margins on compact
        /// screens.
        public var contentInset: [UIUserInterfaceSizeClass: EPUBContentInsets]

        /// Number of positions (as in `Publication.positionList`) to preload before the current page.
        public var preloadPreviousPositionCount: Int
        
        /// Number of positions (as in `Publication.positionList`) to preload after the current page.
        public var preloadNextPositionCount: Int

        /// Supported HTML decoration templates.
        public var decorationTemplates: [Decoration.Style.Id: HTMLDecorationTemplate]

        /// Logs the state changes when true.
        public var debugState: Bool
        
        public var longPressAccessibilityLabel: String?
        
        public var trimmedToc: [Link]?
        
        ///  Show selection menu
        public var showMenu: Bool
        
        public init(
            userSettings: UserSettings = UserSettings(),
            editingActions: [EditingAction] = EditingAction.defaultActions,
            contentInset: [UIUserInterfaceSizeClass: EPUBContentInsets] = [
                .compact: (top: 20, bottom: 20),
                .regular: (top: 44, bottom: 44)
            ],
            preloadPreviousPositionCount: Int = 2,
            preloadNextPositionCount: Int = 6,
            decorationTemplates: [Decoration.Style.Id: HTMLDecorationTemplate] = HTMLDecorationTemplate.defaultTemplates(),
            debugState: Bool = false,
            showMenu: Bool = true
        ) {
            self.userSettings = userSettings
            self.editingActions = editingActions
            self.contentInset = contentInset
            self.preloadPreviousPositionCount = preloadPreviousPositionCount
            self.preloadNextPositionCount = preloadNextPositionCount
            self.decorationTemplates = decorationTemplates
            self.debugState = debugState
            self.showMenu = showMenu
        }
    }

    public weak var delegate: EPUBNavigatorDelegate? {
        didSet { notifyCurrentLocation() }
    }
    
    public var currentWebView: UIView? {
        return (paginationView.currentView as? EPUBSpreadView)?.webView
    }
    
    public var onSelection: ((_ selection: Selection) -> Void)?
    public var onSelectionWithScrollSize: ((_ selection: Selection, _ scrollSize: CGSize) -> Void)?
    public var isAllowingSelection = true
    
    public var onScrollViewDidScroll: ((Double) -> Void)?
    public var onReachedEndOfSpread: ((Bool) -> Void)?
    var onSpreadDidLoad: ((EPUBSpreadView) -> Void)?
    var spreadViewDidLoad: ((EPUBSpreadView) -> Void)?
    
    /// Keeps an array with the JS scripts that will be executed manually or automatically when the spreadViews are being loaded
    private var scriptsToExecute: [ScriptToExecute] = []

    public var onScriptAppliedError: ((Error) -> Void)?

    public var userSettings: UserSettings

    public var readingProgression: ReadingProgression {
        didSet { updateUserSettingStyle() }
    }
    
    public var currentSpreadViewScrollSize: CGSize {
        get {
            return (paginationView.currentView as? EPUBSpreadView)?.scrollView.contentSize ?? CGSize(width: 1.0, height: 1.0)
        }
    }
    
    public var isCurrentSpreadFixedLayout: Bool {
        get {
            return (paginationView.currentView as? EPUBSpreadView)?.spread.layout == .fixed
        }
    }
    
    public var contentSizeHeight: CGFloat? {
        paginationView.currentViewContentHeight
    }
    
    /// Navigation state.
    private enum State: Equatable {
        /// Loading the spreads, for example after changing the user settings or loading the publication.
        case loading
        /// Waiting for further navigation instructions.
        case idle
        /// Jumping to `pendingLocator`.
        case jumping(pendingLocator: Locator)
        /// Turning the page in the given `direction`.
        case moving(direction: EPUBSpreadView.Direction)
        
        mutating func transition(_ event: Event) -> Bool {
            switch (self, event) {
            
            // All events are ignored when loading spreads, except for `loaded` and `load`.
            case (.loading, .load):
                return true
            case (.loading, .loaded):
                self = .idle
            case (.loading, _):
                return false

            case (.idle, .jump(let locator)):
                self = .jumping(pendingLocator: locator)
            case (.idle, .move(let direction)):
                self = .moving(direction: direction)

            case (.jumping, .jumped):
                self = .idle
            // Moving or jumping to another locator is not allowed during a pending jump.
            case (.jumping, .jump),
                 (.jumping, .move):
                return false
                
            case (.moving, .moved):
                self = .idle
            // Moving or jumping to another locator is not allowed during a pending move.
            case (.moving, .jump),
                 (.moving, .move):
                return false

            // Loading the spreads is always possible, because it can be triggered by rotating the
            // screen. In which case it cancels any on-going state.
            case (_, .load):
                self = .loading
                
            default:
                log(.error, "Invalid event \(event) for state \(self)")
                return false
            }
            
            return true
        }
    }
    
    /// Navigation event.
    private enum Event: Equatable {
        /// Load the spreads, for example after changing the user settings or loading the publication.
        case load
        /// The spreads were loaded.
        case loaded
        /// Jump to the given locator.
        case jump(Locator)
        /// Finished jumping to a locator.
        case jumped
        /// Turn the page in the given direction.
        case move(EPUBSpreadView.Direction)
        /// Finished turning the page.
        case moved
    }
    
    /// Current navigation state.
    private var state: State = .loading {
        didSet {
            if (config.debugState) {
                log(.debug, "* transitioned to \(state)")
            }
            
            // Disable user interaction while transitioning, to avoid UX issues.
            switch state {
            case .loading, .jumping, .moving:
                paginationView.isUserInteractionEnabled = false
            case .idle:
                paginationView.isUserInteractionEnabled = true
            }
        }
    }

    public var onSpreadViewShouldDefaultToWebview: (() -> Bool)?
    public var onComputedExternalUrlString: ((String) -> Void)?

    let config: Configuration
    private let publication: Publication
    private let initialLocation: Locator?
    private let editingActions: EditingActionsController

    /// Base URL on the resources server to the files in Static/
    /// Used to serve Readium CSS.
    private let resourcesURL: URL

    public init(
        publication: Publication,
        initialLocation: Locator? = nil,
        resourcesServer: ResourcesServer,
        config: Configuration = .init()
    ) {
        assert(!publication.isRestricted, "The provided publication is restricted. Check that any DRM was properly unlocked using a Content Protection.")
        
        self.publication = publication
        self.initialLocation = initialLocation
        self.editingActions = EditingActionsController(actions: config.editingActions, rights: publication.rights, showMenu: config.showMenu)
        self.readingProgression = publication.metadata.effectiveReadingProgression
        self.config = config
        self.userSettings = config.userSettings
        
        publication.userProperties.properties = userSettings.userProperties.properties
        var verticalScroll = false
        if let scroll = userSettings.userProperties.getProperty(reference: ReadiumCSSReference.scroll.rawValue) as? Switchable {
            verticalScroll = scroll.on
        }
        self.paginationView = PaginationView(frame: .zero, preloadPreviousPositionCount: config.preloadPreviousPositionCount, preloadNextPositionCount: config.preloadNextPositionCount, verticalScroll: verticalScroll)

        self.resourcesURL = {
            do {
                return try resourcesServer.serve(
                    Bundle.module.resourceURL!.appendingPathComponent("Assets/Static"),
                    at: "/r2-navigator/epub"
                )
            } catch {
                EPUBNavigatorViewController.log(.error, error)
                return URL(string: "")!
            }
        }()

        super.init(nibName: nil, bundle: nil)
        
        self.onSpreadDidLoad = handleSpreadLoad(config: config)
        self.editingActions.delegate = self
        self.paginationView.delegate = self
    }

    @available(*, unavailable)
    public required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    open override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        paginationView.backgroundColor = .clear
        paginationView.frame = view.bounds
        paginationView.autoresizingMask = [.flexibleHeight, .flexibleWidth]
        view.addSubview(paginationView)
        
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTapBackground)))

        editingActions.updateSharedMenuController()
        
        reloadSpreads(at: initialLocation)
    }
    
    /// Intercepts tap gesture when the web views are not loaded.
    @objc private func didTapBackground(_ gesture: UITapGestureRecognizer) {
        guard state == .loading else { return }
        let point = gesture.location(in: view)
        delegate?.navigator(self, didTapAt: point)
    }

    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        paginationView.loadedViews.values.forEach {
            ($0 as? EPUBSpreadView)?.enableJSMessages()
            ($0 as? EPUBSpreadView)?.registerNotifications()
        }
    }
    
    open override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        // FIXME: Deprecated, to be removed at some point.
        if let currentResourceIndex = currentResourceIndex {
            let progression = currentLocation?.locations.progression
            delegate?.willExitPublication(documentIndex: currentResourceIndex, progression: progression)
        }
        
        paginationView.loadedViews.values.forEach {
            ($0 as? EPUBSpreadView)?.disableJSMessages()
            ($0 as? EPUBSpreadView)?.unregisterNotifications()
        }
    }
    
    open override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        if self.savedLocation == nil {
            self.savedLocation = currentLocation
        }
        coordinator.animate { [weak self] context in
            self?.reloadSpreads()
        }
        /// the pagination view under the hood is waiting on the main queue for 0.5 seconds to go to the location. Multiple rapid screen orientation changes causes us to lose this ephemeral state and reset the location to the beginning of the chapter, so we wait 1 second to nil out this optional `savedLocation`
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.savedLocation = nil
        }
    }

    @discardableResult
    private func on(_ event: Event) -> Bool {
        assert(Thread.isMainThread, "Raising navigation events must be done from the main thread")
        
        if (config.debugState) {
            log(.debug, "-> on \(event)")
        }
        
        return state.transition(event)
    }
    
    /// Mapping between reading order hrefs and the table of contents title.
    private lazy var tableOfContentsTitleByHref: [String: String] = {
        func fulfill(linkList: [Link]) -> [String: String] {
            var result = [String: String]()
            
            for link in linkList {
                if let title = link.title {
                    result[link.href] = title
                }
                let subResult = fulfill(linkList: link.children)
                result.merge(subResult) { (current, another) -> String in
                    return current
                }
            }
            return result
        }
        
        return fulfill(linkList: publication.tableOfContents)
    }()

    /// Goes to the next or previous page in the given scroll direction.
    private func go(to direction: EPUBSpreadView.Direction, animated: Bool, completion completionBlock: @escaping () -> Void) -> Bool {
        guard on(.move(direction)) else {
            return false
        }
        
        let completion = {
            self.on(.moved)
            completionBlock()
        }
        
        if
            let spreadView = paginationView.currentView as? EPUBSpreadView,
            spreadView.go(to: direction, animated: animated, completion: completion)
        {
            return true
        }
        
        let isRTL = (readingProgression == .rtl)
        let delta = isRTL ? -1 : 1
        let moved: Bool = {
            switch direction {
            case .left:
                let location: PageLocation = isRTL ? .start : .end
                return paginationView.goToIndex(currentSpreadIndex - delta, location: location, animated: animated, completion: completion)
            case .right:
                let location: PageLocation = isRTL ? .end : .start
                return paginationView.goToIndex(currentSpreadIndex + delta, location: location, animated: animated, completion: completion)
            }
        }()
        
        if !moved {
            on(.moved)
        }
        
        return moved
    }
    
    
    // MARK: - User settings
    
    public func updateUserSettingStyle() {
        assert(Thread.isMainThread, "User settings must be updated from the main thread")
        _updateUserSettingsStyle()
    }
    
    private lazy var _updateUserSettingsStyle = execute(
        when: { [weak self] in self?.state == .idle && self?.paginationView.isEmpty == false },
        pollingInterval: userSettingsStylePollingInterval
    ) { [weak self] in
        guard let self = self else { return }

        if let scroll = self.userSettings.userProperties.getProperty(reference: ReadiumCSSReference.scroll.rawValue) as? Switchable {
            self.paginationView.verticalScroll = scroll.on
            self.paginationView.layoutSubviews()
        }
        self.reloadSpreads()

        let location = self.currentLocation
        for (_, view) in self.paginationView.loadedViews {
            (view as? EPUBSpreadView)?.applyUserSettingsStyle()
        }

        // Re-positions the navigator to the location before applying the settings
        if let location = location {
            self.go(to: location)
        }
    }

    /// Polling interval to refresh user settings styles
    ///
    /// The polling that we perform to update the styles copes with the fact
    /// that we cannot know when the web view has finished layout. From
    /// empirical observations it appears that the completion speed of that
    /// work is vastly dependent on the version of the OS, probably in
    /// conjunction with performance-related variables such as the CPU load,
    /// age of the device/battery, memory pressure.
    ///
    /// Having too small a value here may cause race conditions inside the
    /// navigator code, causing for example failure to open the navigator to
    /// the intended initial location.
    private let userSettingsStylePollingInterval: TimeInterval = {
        if #available(iOS 14, *) {
            return 0.1
        } else if #available(iOS 13, *) {
            return 0.5
        } else {
            return 2.0
        }
    }()

    
    // MARK: - Pagination and spreads
    
    private let paginationView: PaginationView
    private var spreads: [EPUBSpread] = []

    /// Index of the currently visible spread.
    public var currentSpreadIndex: Int {
        return paginationView.currentIndex
    }

    // Reading order index of the left-most resource in the visible spread.
    private var currentResourceIndex: Int? {
        guard spreads.indices.contains(currentSpreadIndex) else {
            return nil
        }
        
        return publication.readingOrder.firstIndex(withHREF: spreads[currentSpreadIndex].left.href)
    }

    private func reloadSpreads(at locator: Locator? = nil) {
        let isLandscape = (view.bounds.width > view.bounds.height)
        let pageCountPerSpread = EPUBSpread.pageCountPerSpread(for: publication, userSettings: userSettings, isLandscape: isLandscape)
        
        guard
            // Already loaded with the expected amount of spreads.
            spreads.first?.pageCount != pageCountPerSpread,
            on(.load)
        else {
            return
        }

        let locator = locator ?? savedLocation ?? currentLocation
        spreads = EPUBSpread.makeSpreads(for: publication, readingProgression: readingProgression, pageCountPerSpread: pageCountPerSpread)
        
        var initialIndex: Int
        
        if let href = locator?.href, let foundIndex = spreads.firstIndex(withHref: href) {
            initialIndex = foundIndex
        } else {
            initialIndex = 0
        }
        
        if let trimmedToc = self.config.trimmedToc {
            let pageNumbers = trimmedToc.map(\.href).map(trimEpubHrefComments).compactMap(spreads.firstIndex)
            initialIndex = max(pageNumbers.first ?? 0, initialIndex)
            paginationView.pageNumbers = pageNumbers
        }
        
        paginationView.reloadAtIndex(initialIndex, location: PageLocation(locator), pageCount: spreads.count, readingProgression: readingProgression) {
            self.on(.loaded)
        }
    }

    private func loadedSpreadView(forHREF href: String) -> EPUBSpreadView? {
        paginationView.loadedViews
            .compactMap { _, view in view as? EPUBSpreadView }
            .first { $0.spread.links.first(withHREF: href) != nil}
    }

    
    // MARK: - Navigator
    
    public var progressWithinSpread: Double? {
        guard let spreadView = paginationView.currentView as? EPUBSpreadView else {
            return nil
        }
        
        let link = spreadView.focusedResource ?? spreadView.spread.leading
        let href = link.href
        // There are some cases when the progression might come as a negative value, in order to avoid the app to crash we set the value to 0
        var progression = spreadView.progression(in: href)
        progression = progression > 0 ? progression : 0
        
        guard let currentLocation = currentLocation,
              let trimmedToc = config.trimmedToc,
              let trimmedLocation = publication.trimmedPositions(currentLocation, trimmedToc: trimmedToc),
              let index = trimmedLocation.firstIndex(
                where: { $0.firstIndex(where: { location in
                    currentLocation.href == location.href
                }) != nil }),
              let positionList = Optional(trimmedLocation[index]),
              positionList.count != 0 else { return nil }
        let positionIndex = Int(ceil(progression * Double(positionList.count - 1)))
        return positionList[positionIndex].locations.totalProgression
    }
    
    public var currentLocation: Locator? {
        // Returns any pending locator to prevent returning invalid locations while loading it.
        if case let .jumping(pendingLocator) = state {
            return pendingLocator
        }
        
        guard let spreadView = paginationView.currentView as? EPUBSpreadView else {
            return nil
        }
        
        let link = spreadView.focusedResource ?? spreadView.spread.leading
        let href = link.href
        let progression = min(max(spreadView.progression(in: href), 0.0), 1.0)
        
        // The positions are not always available, for example a Readium WebPub doesn't have any
        // unless a Publication Positions Web Service is provided.
        if
            let index = publication.readingOrder.firstIndex(withHREF: href),
            let positionList = Optional(publication.positionsByReadingOrder[index]),
            positionList.count > 0
        {
            // Gets the current locator from the positionList, and fill its missing data.
            let positionIndex = Int(ceil(progression * Double(positionList.count - 1)))
            return positionList[positionIndex].copy(
                title: tableOfContentsTitleByHref[href],
                locations: { $0.progression = progression }
            )
        } else {
            return Locator(link: link).copy(
                locations: { $0.progression = progression }
            )
        }
    }
    
    public var savedLocation: Locator?

    /// Last current location notified to the delegate.
    /// Used to avoid sending twice the same location.
    private var notifiedCurrentLocation: Locator?
    
    private lazy var notifyCurrentLocation = execute(
        // If we're not in an `idle` state, we postpone the notification.
        when: { [weak self] in self?.state == .idle },
        pollingInterval: 0.1
    ) { [weak self] in
        guard
            let self = self,
            let delegate = self.delegate,
            let location = self.currentLocation,
            location != self.notifiedCurrentLocation
        else {
            return
        }

        self.notifiedCurrentLocation = location
        delegate.navigator(self, locationDidChange: location)
    }

    public func go(to locator: Locator, animated: Bool, completion: @escaping () -> Void) -> Bool {
        guard
            let spreadIndex = spreads.firstIndex(withHref: locator.href),
            on(.jump(locator))
        else {
            return false
        }
        
        return paginationView.goToIndex(spreadIndex, location: .locator(locator), animated: animated) {
            self.on(.jumped)
            completion()
        }
    }
    
    public func go(to link: Link, animated: Bool, completion: @escaping () -> Void) -> Bool {
        return go(to: Locator(link: link), animated: animated, completion: completion)
    }
    
    public func goForward(animated: Bool, completion: @escaping () -> Void) -> Bool {
        let direction: EPUBSpreadView.Direction = {
            switch readingProgression {
            case .ltr, .ttb, .auto:
                return .right
            case .rtl, .btt:
                return .left
            }
        }()
        return go(to: direction, animated: animated, completion: completion)
    }
    
    public func goBackward(animated: Bool, completion: @escaping () -> Void) -> Bool {
        let direction: EPUBSpreadView.Direction = {
            switch readingProgression {
            case .ltr, .ttb, .auto:
                return .left
            case .rtl, .btt:
                return .right
            }
        }()
        return go(to: direction, animated: animated, completion: completion)
    }

    // MARK: – SelectableNavigator

    public var currentSelection: Selection? { editingActions.selection }

    public func clearSelection() {
        for (_, pageView) in paginationView.loadedViews {
            (pageView as? EPUBSpreadView)?.webView.clearSelection()
        }
    }
    
    // if true user can select text otherwise not
    private var isTextSelectionEnabled = true
    // set the  property `isTextSelectionEnabled`
    public func setTextSelection(allow: Bool = true) {
        if #available(iOS 15.0, *) {
            for (_, pageView) in paginationView.loadedViews {
                (pageView as? EPUBSpreadView)?.webView.configuration.preferences.isTextInteractionEnabled = allow
            }
            isTextSelectionEnabled = allow
        }
    }

    // MARK: – DecorableNavigator

    private var decorations: [String: [DiffableDecoration]] = [:]

    /// Decoration group callbacks, indexed by the group name.
    private var decorationCallbacks: [String: [DecorableNavigator.OnActivatedCallback]] = [:]
    
    /// Decoration callbacks for all the decorations types (not using any group clasification)
    private var fullDecorationCallbacks: [DecorableNavigator.OnActivatedCallback] = []

    public func supports(decorationStyle style: Decoration.Style.Id) -> Bool {
        config.decorationTemplates.keys.contains(style)
    }

    public func apply(decorations: [Decoration], in group: String) {
        let source = self.decorations[group] ?? []
        let target = decorations.map { DiffableDecoration(decoration: $0) }

        self.decorations[group] = target

        if decorations.isEmpty {
            for (_, pageView) in paginationView.loadedViews {
                (pageView as? EPUBSpreadView)?.evaluateScript(
                    // The updates command are using `requestAnimationFrame()`, so we need it for
                    // `clear()` as well otherwise we might recreate a highlight after it has been
                    // cleared.
                    "requestAnimationFrame(function () { readium.getDecorations('\(group)').clear(); });"
                )
            }

        } else {
            for (href, changes) in target.changesByHREF(from: source) {
                guard let script = changes.javascript(forGroup: group, styles: config.decorationTemplates) else {
                    continue
                }
                loadedSpreadView(forHREF: href)?.evaluateScript(script, inHREF: href)
            }
        }
    }
        
    public func observeDecorationFullInteractions(onActivated: OnActivatedCallback?) {
        guard let onActivated = onActivated else {
            return
        }

        fullDecorationCallbacks.append(onActivated)
    }
    
    public func observeDecorationInteractions(inGroup group: String, onActivated: OnActivatedCallback?) {
        guard let onActivated = onActivated else {
            return
        }
        var callbacks = decorationCallbacks[group] ?? []
        callbacks.append(onActivated)
        decorationCallbacks[group] = callbacks

        for (_, view) in self.paginationView.loadedViews {
            (view as? EPUBSpreadView)?.evaluateScript("readium.getDecorations('\(group)').setActivable();")
        }
    }

    // MARK: – EPUB-specific extensions
    public func convertRectToNavigatorSpace(_ rect: CGRect) -> CGRect {
        guard let spreadView = paginationView.currentView as? EPUBSpreadView else {
            return rect
        }
        return spreadView.convertRectToNavigatorSpace(rect)
    }
    public func convertRectFromNavigatorSpace(_ rect: CGRect) -> CGRect {
        guard let spreadView = paginationView.currentView as? EPUBSpreadView else {
            return rect
        }
        return spreadView.convertRectFromNavigatorSpace(rect)
    }

    /// Evaluates the given JavaScript on the currently visible HTML resource.
    public func evaluateJavaScript(_ script: String, completion: ((Result<Any, Error>) -> Void)? = nil) {
        guard let spreadView = paginationView.currentView as? EPUBSpreadView else {
            DispatchQueue.main.async {
                completion?(.failure(EPUBError.spreadNotLoaded))
            }
            return
        }
        spreadView.evaluateScript(script, completion: completion)
    }
    
    @available(iOS 13, *)
    public func evaluateJavaScript(_ script: String) async -> Result<Any, Error>? {
        guard let spreadView = paginationView.currentView as? EPUBSpreadView else {
            return .failure(EPUBError.spreadNotLoaded)
        }
        
        return await spreadView.evaluateScript(script)
    }
    
    /// This adds or updates a script as part of the scripts that will be executed on the ePub document
    /// Usually this scripts are being used to handle accessibility support for the ePub
    /// - Parameter script: The script what will be added / updated
    public func setScriptToExecute(_ script: ScriptToExecute) {
        if let foundIndex = self.scriptsToExecute.firstIndex(where: { $0.name == script.name }) {
            self.scriptsToExecute[foundIndex] = script
            return
        }
        
        self.scriptsToExecute.append(script)
    }
    
    /// Removes a script from the list of scripts that eventually will be executed into the ePub
    /// - Parameter name: The name of the scripts
    public func removeScriptToExecute(name: String) {
        guard let foundIndex = self.scriptsToExecute.firstIndex(where: { $0.name == name }) else { return }
        self.scriptsToExecute.remove(at: foundIndex)
    }
        
    /// Returns whether or not a script is present in the list of scripts that will be executed
    /// - Parameter name: The name of the script
    /// - Returns: If the script was found or not
    public func scriptIsAlreadySet(name: String) -> Bool {
        return self.scriptsToExecute.firstIndex(where: { $0.name == name }) != nil
    }
}

extension EPUBNavigatorViewController: EPUBSpreadViewDelegate {
    func shouldSpreadViewDefaultToExternalWebView() -> Bool {
        return self.onSpreadViewShouldDefaultToWebview?() ?? false
    }
    
    private func trimSpreadView(_ spreadView: EPUBSpreadView) {
        guard let trimmedToc = config.trimmedToc else { return }
        let link = spreadView.spread.leading
        
        guard let chapterRef = publication.tableOfContents.find({ $0.href == link.href }) else { return }
        
        // With the given chapter associated with the spread identified, recursively get a flat list of all children (subchapters, sub-subchapters, etc.)
        let filteredChapters = chapterRef.flatChildren()
        
        // the trimmedToc parameter comes from the server, and doesn't have the notion of children. We want to get the "filled-in" version directly from the ToC, repeat the behavior vis-a-vis the children
        let trimmedSubchapters = trimmedToc
            .filter { $0.href.starts(with: link.href) }
            .compactMap({ subChapter in
                return filteredChapters.find { $0.href == subChapter.href }
            })
            .flatList()
        
        guard let serializedChapters = serializeJSONString(filteredChapters.map({ ["href": $0.href] })),
              let serializedTrimmedChapters = serializeJSONString(trimmedSubchapters.map({ ["href": $0.href] })) else { return }
        let script = """
        function run() {
            window.readium.hideSections(
                \(serializedChapters),
                \(serializedTrimmedChapters)
            )
        }
        run()
        """
        
        spreadView.evaluateScript(script)
    }
    
    func spreadViewDidLoad(_ spreadView: EPUBSpreadView) {
        let templates = config.decorationTemplates.reduce(into: [:]) { styles, item in
            styles[item.key.rawValue] = item.value.json
        }

        guard let stylesJSON = serializeJSONString(templates) else {
            log(.error, "Can't serialize decoration styles to JSON")
            return
        }
        var script = "readium.registerDecorationTemplates(\(stylesJSON.replacingOccurrences(of: "\\n", with: " ")));\n"

        script += decorationCallbacks
            .compactMap { group, callbacks in
                guard !callbacks.isEmpty else {
                    return nil
                }
                return "readium.getDecorations('\(group)').setActivable();"
            }
            .joined(separator: "\n")

        spreadView.evaluateScript("(function() {\n\(script)\n})();") { _ in
            for link in spreadView.spread.links {
                let href = link.href
                for (group, decorations) in self.decorations {
                    let decorations = decorations
                        .filter { $0.decoration.locator.href == href }
                        .map { DecorationChange.add($0.decoration) }

                    guard let script = decorations.javascript(forGroup: group, styles: self.config.decorationTemplates) else {
                        continue
                    }
                    spreadView.evaluateScript(script, inHREF: href)
                }
            }
        }
        
        spreadView.onOpenExternalLinkByDefault = { [weak self] url in
            let path = url.path
            let components = url.pathComponents
            let totalComponentsToExclude = components.count - 2
            let componentsToInclude = components.suffix(totalComponentsToExclude)
            var externalUrlPath = String(componentsToInclude.joined(separator: "/"))
            if let fragment = url.fragment {
                externalUrlPath += "#\(fragment)"
            }
            self?.onComputedExternalUrlString?(externalUrlPath)
        }
        
        // SF: HSA-475 Enabling video controls
        let videoControlScript = """
                let videoElements = document.getElementsByTagName("video");
                for(video of videoElements) {
                    video.setAttribute("controls",true);
                }
        """
        
        spreadView.evaluateScript(videoControlScript)
        trimSpreadView(spreadView)
        onSpreadDidLoad?(spreadView)
    }
    
    public func removeAnnotations() {
        for name in decorations.keys {
            apply(decorations: [], in: name)
        }
    }
    
    public func removeSharedAnnotations() {
        for name in decorations.keys where name == "sharedAnnotation" {
            apply(decorations: [], in: name)
        }
    }
    
    public func openAnnotationAt(locator: Locator, groupName: String) {
        execute(when: { [weak self] in
            self?.state == .idle
        }, pollingInterval: 0.5, {
            guard let locatorJson = serializeJSONString(locator.json) else { return }
            self.evaluateJavaScript(
                    """
                    window.readium.activateDecoration(\(locatorJson), "\(groupName)");
                    """
                    , completion: { result in
                        switch result {
                        case .failure(let err):
                            print(err)
                        default:
                            break
                        }
                    })
        })()
    }

    func spreadView(_ spreadView: EPUBSpreadView, didTapAt point: CGPoint) {
        // We allow taps in any state, because we should always be able to toggle the navigation bar,
        // even while a locator is pending.
        
        let point = view.convert(point, from: spreadView)
        delegate?.navigator(self, didTapAt: point)
        // FIXME: Deprecated, to be removed at some point.
        delegate?.middleTapHandler()
        
        // Uncomment to debug the coordinates of the tap point.
//        let tapView = UIView(frame: .init(x: 0, y: 0, width: 50, height: 50))
//        view.addSubview(tapView)
//        tapView.backgroundColor = .red
//        tapView.center = point
//        tapView.layer.cornerRadius = 25
//        tapView.layer.masksToBounds = true
//        UIView.animate(withDuration: 0.8, animations: {
//            tapView.alpha = 0
//        }) { _ in
//            tapView.removeFromSuperview()
//        }
    }
    
    func spreadView(_ spreadView: EPUBSpreadView, didTapOnExternalURL url: URL) {
        guard state == .idle else { return }
        
        delegate?.navigator(self, presentExternalURL: url)
    }
    
    func spreadView(_ spreadView: EPUBSpreadView, didTapOnInternalLink href: String, clickEvent: ClickEvent?) {
        // Check to see if this was a noteref link and give delegate the opportunity to display it.
        if
            let clickEvent = clickEvent,
            let interactive = clickEvent.interactiveElement,
            let (note, referrer) = getNoteData(anchor: interactive, href: href),
            let delegate = self.delegate
        {
            if !delegate.navigator(
                self,
                shouldNavigateToNoteAt: Link(href: href, type: "text/html"),
                content: note,
                referrer: referrer
            ) {
                return
            }
        }
        if let id = href.components(separatedBy: "#").last {
            spreadView.evaluateScript("window.readium.doesElementExist(\"\(id)\")") { [weak self] val in
                if case let .success(doesExist) = val, doesExist as? Bool == true {
                    self?.go(to: Link(href: href))
                } else if let trimmedToc = self?.config.trimmedToc,
                          !trimmedToc.contains(where: { $0.href == href }) {
                    self?.delegate?.handleTapOnTrimmedInternalLink(link: href)
                } else {
                    self?.go(to: Link(href: href))
                }
            }
        } else if let trimmedToc = config.trimmedToc, !trimmedToc.contains(where: { $0.href == href }) {
            self.delegate?.handleTapOnTrimmedInternalLink(link: href)
        } else {
            go(to: Link(href: href))
        }
    }
    
    /// Checks if the internal link is a noteref, and retrieves both the referring text of the link and the body of the note.
    ///
    /// Uses the navigation href from didTapOnInternalLink because it is normalized to a path within the book,
    /// whereas the anchor tag may have just a hash fragment like `#abc123` which is hard to work with.
    /// We do at least validate to ensure that the two hrefs match.
    ///
    /// Uses `#id` when retrieving the body of the note, not `aside#id` because it may be a `<section>`.
    /// See https://idpf.github.io/epub-vocabs/structure/#footnotes
    /// and http://kb.daisy.org/publishing/docs/html/epub-type.html#ex
    func getNoteData(anchor: String, href: String) -> (String, String)? {
        do {
            let doc = try parse(anchor)
            guard let link = try doc.select("a[epub:type=noteref]").first() else { return nil }
            
            let anchorHref = try link.attr("href")
            guard href.hasSuffix(anchorHref) else { return nil}
            
            let hashParts = href.split(separator: "#")
            guard hashParts.count == 2 else {
                log(.error, "Could not find hash in link \(href)")
                return nil
            }
            let id = String(hashParts[1])
            var withoutFragment = String(hashParts[0])
            if withoutFragment.hasPrefix("/") {
                withoutFragment = String(withoutFragment.dropFirst())
            }
            
            guard let base = publication.baseURL else {
                log(.error, "Couldn't get publication base URL")
                return nil
            }
            
            let absolute = base.appendingPathComponent(withoutFragment)
            
            log(.debug, "Fetching note contents from \(absolute.absoluteString)")
            let contents = try String(contentsOf: absolute)
            let document = try parse(contents)
            
            guard let aside = try document.select("#\(id)").first() else {
                log(.error, "Could not find the element '#\(id)' in document \(absolute)")
                return nil
            }
            
            return (try aside.html(), try link.html())
            
        } catch {
            log(.error, "Caught error while getting note content: \(error)")
            return nil
        }
    }
    
    func spreadView(_ spreadView: EPUBSpreadView, activatedDecorations: [ActivatedDecorationEvent]) {
        var adjustedDecorations = activatedDecorations
        var callbacks: [DecorableNavigator.OnActivatedCallback] = []
        
        for (index, activatedDecoration) in activatedDecorations.enumerated() {
            guard let decoration: Decoration = decorations[activatedDecoration.group]?
                    .first(where: { $0.decoration.id == activatedDecoration.id })
                    .map({ $0.decoration })
            else {
                continue
            }
            
            if let foundCallbacks = decorationCallbacks[activatedDecoration.group].takeIf({ !$0.isEmpty }) {
                callbacks.append(contentsOf: foundCallbacks)
            }
            
            adjustedDecorations[index].decoration = decoration
        }
        
        let onDecorationActivateEvents = adjustedDecorations.compactMap { (activatedDecoration) -> OnDecorationActivatedEvent? in
            guard let decoration = activatedDecoration.decoration else {
                return nil
            }
            
            return OnDecorationActivatedEvent(decoration: decoration,
                                       group: activatedDecoration.group,
                                       rect: activatedDecoration.frame,
                                       point: activatedDecoration.point)
        }
        
        for callback in callbacks {
            callback(onDecorationActivateEvents)
        }
        
        for callback in fullDecorationCallbacks {
            callback(onDecorationActivateEvents)
        }
    }

    func spreadView(_ spreadView: EPUBSpreadView, selectionDidChange text: Locator.Text?, frame: CGRect) {
        guard
            var locator = currentLocation,
            let text = text
        else {
            editingActions.selection = nil
            return
        }
        locator = locator.copy(locations: { locations in
            if spreadView.isScrollEnabled {
                locations.progression? += frame.origin.y/spreadView.scrollView.contentSize.height
            }
        }, text: { $0 = text })
        editingActions.selection = Selection(
            locator: locator,
            frame: frame
        )
    }

    func spreadViewPagesDidChange(_ spreadView: EPUBSpreadView) {
        if paginationView.currentView == spreadView {
            notifyCurrentLocation()
        }
    }
    
    func spreadView(_ spreadView: EPUBSpreadView, present viewController: UIViewController) {
        present(viewController, animated: true)
    }

}

extension EPUBNavigatorViewController {

    public var currentSpreadIsLoaded: Bool {
        guard let currentSpread = paginationView.currentView as? EPUBSpreadView else {
            return false
        }
        
        return currentSpread.spreadLoaded
    }

    func isSpreadVisible(_ spreadView: EPUBSpreadView) -> Bool {
        guard let current = paginationView.currentView else {
            return false
        }
        
        return current == spreadView
    }
    
    func handleSpreadLoad(config: Configuration) -> (EPUBSpreadView) -> Void {
        return { [weak self] spreadView in
            guard let self else { return }
            if let longPress = config.longPressAccessibilityLabel {
                spreadView.evaluateScript("window.readium.initializeAccessibility(\"\(longPress)\", undefined)")
            }

            self.applyScripts(spreadView: spreadView)
            if self.isSpreadVisible(spreadView) {
                self.spreadViewDidLoad?(spreadView)
            }
        }
    }
    
    /// Evaluates and applies the current script list into the ePub document
    /// In this case as we don't know what is current spreadView, we just send the parameter nil,
    /// and the internal 'applyScripts' will apply the script to the current displayed spreadView
    public func applyScripts() {
        self.applyScripts(spreadView: nil)
    }
    
    /// Evaluates and applies the current script list into the ePub document
    /// - Parameter spreadView: The spreadView where the script is going to run. If the value is nil, then script will be evaluated on the current visible spreadView
    private func applyScripts(spreadView: EPUBSpreadView?) {
        let resultHandler: (Result<Any, Error>) -> Void = { [weak self] result in
            switch result {
            case .failure(let error):
                self?.onScriptAppliedError?(error)
            case .success:
                break
            }
        }

        for script in self.scriptsToExecute {
            if let spreadView {
                spreadView.evaluateScript(script.script, completion: resultHandler)
            } else {
                self.evaluateJavaScript(script.script, completion: resultHandler)
            }
        }
    }
}

extension EPUBNavigatorViewController: EditingActionsControllerDelegate {
    
    func editingActionsDidPreventCopy(_ editingActions: EditingActionsController) {
        delegate?.navigator(self, presentError: .copyForbidden)
        // FIXME: Deprecated, to be removed at some point.
        delegate?.presentError(.copyForbidden)
    }

    func editingActions(_ editingActions: EditingActionsController, shouldShowMenuForSelection selection: Selection) -> Bool {
        onSelection?(selection)
        let spreadView = paginationView.currentView as? EPUBSpreadView
        onSelectionWithScrollSize?(selection, spreadView?.scrollView.contentSize ?? CGSize(width: 1.0, height: 1.0))
        return isAllowingSelection
    }

    func editingActions(_ editingActions: EditingActionsController, canPerformAction action: EditingAction, for selection: Selection) -> Bool {
        return isAllowingSelection
    }
}

extension EPUBNavigatorViewController: PaginationViewDelegate {
    
    func paginationView(_ paginationView: PaginationView, pageViewAtIndex index: Int) -> (UIView & PageView)? {
        let spread = spreads[index]
        if let trimmedToc = config.trimmedToc, !trimmedToc.isEmpty {
            let pageNumbers = trimmedToc.map(\.href).map(trimEpubHrefComments).compactMap({ [weak self] in self?.spreads.firstIndex(withHref: $0) })
            paginationView.pageNumbers = pageNumbers
        }
        
        if let trimmedToc = config.trimmedToc, trimmedToc.map(\.href).map(trimEpubHrefComments).map({ spread.contains(href: $0) }).filter({ $0 }).isEmpty {
            return nil
        }
        let spreadViewType = (spread.layout == .fixed) ? EPUBFixedSpreadView.self : EPUBReflowableSpreadView.self
        let spreadView = spreadViewType.init(
            publication: publication,
            spread: spread,
            resourcesURL: resourcesURL,
            readingProgression: readingProgression,
            userSettings: userSettings,
            scripts: [],
            animatedLoad: false,  // FIXME: custom animated
            editingActions: editingActions,
            contentInset: config.contentInset
        )
        spreadView.delegate = self

        let userContentController = spreadView.webView.configuration.userContentController
        delegate?.navigator(self, setupUserScripts: userContentController)

        if #available(iOS 14.5, *) {
            spreadView.webView.configuration.preferences.isTextInteractionEnabled = !config.editingActions.isEmpty && isTextSelectionEnabled
        }
        
        spreadView.registerJSMessage(named: "offsetChanged", handler: { [weak self] in
            self?.handleOffsetChanged(val: $0)
        })
        spreadView.registerJSMessage(named: "reachedEndOfSpread", handler: { [weak self] in
            self?.handleEndOfSpread(val: $0)
        })

        return spreadView
    }
    
    func handleOffsetChanged(val: Any) {
        if let double = val as? Double {
            onScrollViewDidScroll?(double)
        }
    }
    
    func handleEndOfSpread(val: Any) {
        if let reached = val as? Bool {
            onReachedEndOfSpread?(reached)
        }
    }
    
    func paginationViewDidUpdateViews(_ paginationView: PaginationView) {
        // notice that you should set the delegate before you load views
        // otherwise, when open the publication, you may miss the first invocation
        notifyCurrentLocation()
        evaluateJavaScript("window.readium.updateEndOfSpread()")

        // FIXME: Deprecated, to be removed at some point.
        if let currentResourceIndex = currentResourceIndex {
            delegate?.didChangedDocumentPage(currentDocumentIndex: currentResourceIndex)
        }
    }

    func paginationView(_ paginationView: PaginationView, positionCountAtIndex index: Int) -> Int {
        let spread = spreads[index]
        if let trimmedToc = config.trimmedToc, trimmedToc.map({ spread.contains(href: $0.href) }).filter({ $0 }).isEmpty {
            return 0
        }
        return spread.positionCount(in: publication)
    }
}


// MARK: - Deprecated

@available(*, unavailable, renamed: "EPUBNavigatorViewController")
public typealias NavigatorViewController = EPUBNavigatorViewController

@available(*, unavailable, message: "Use the `animated` parameter of `goTo` functions instead")
public enum PageTransition {
    case none
    case animated
}

extension EPUBNavigatorViewController {
    
    /// This initializer is deprecated.
    /// `license` is not needed anymore.
    @available(*, unavailable, renamed: "init(publication:initialLocation:resourcesServer:config:)")
    public convenience init(publication: Publication, license: DRMLicense?, initialLocation: Locator? = nil, resourcesServer: ResourcesServer, config: Configuration = .init()) {
        self.init(publication: publication, initialLocation: initialLocation, resourcesServer: resourcesServer, config: config)
    }
        
    /// This initializer is deprecated.
    /// Replace `pageTransition` by the `animated` property of the `goTo` functions.
    /// Replace `disableDragAndDrop` by `EditingAction.copy`, since drag and drop is equivalent to copy.
    /// Replace `initialIndex` and `initialProgression` by `initialLocation`.
    @available(*, unavailable, renamed: "init(publication:initialLocation:resourcesServer:config:)")
    public convenience init(for publication: Publication, license: DRMLicense? = nil, initialIndex: Int, initialProgression: Double?, pageTransition: PageTransition = .none, disableDragAndDrop: Bool = false, editingActions: [EditingAction] = EditingAction.defaultActions, contentInset: [UIUserInterfaceSizeClass: EPUBContentInsets]? = nil) {
        fatalError("This initializer is not available anymore.")
    }
    
    /// This initializer is deprecated.
    /// Use the new Configuration object.
    @available(*, unavailable, renamed: "init(publication:license:initialLocation:resourcesServer:config:)")
    public convenience init(publication: Publication, license: DRMLicense? = nil, initialLocation: Locator? = nil, editingActions: [EditingAction] = EditingAction.defaultActions, contentInset: [UIUserInterfaceSizeClass: EPUBContentInsets]? = nil, resourcesServer: ResourcesServer) {
        var config = Configuration()
        config.editingActions = editingActions
        if let contentInset = contentInset {
            config.contentInset = contentInset
        }
        self.init(publication: publication, initialLocation: initialLocation, resourcesServer: resourcesServer, config: config)
    }

    @available(*, unavailable, message: "Use the `animated` parameter of `goTo` functions instead")
    public var pageTransition: PageTransition {
        get { return .none }
        set {}
    }
    
    @available(*, unavailable, message: "Bookmark model is deprecated, use your own model and `currentLocation`")
    public var currentPosition: Bookmark? { nil }

    @available(*, unavailable, message: "Use `publication.readingOrder` instead")
    public func getReadingOrder() -> [Link] { return publication.readingOrder }
    
    @available(*, unavailable, message: "Use `publication.tableOfContents` instead")
    public func getTableOfContents() -> [Link] { return publication.tableOfContents }

    @available(*, unavailable, renamed: "go(to:)")
    public func displayReadingOrderItem(at index: Int) {}
    
    @available(*, unavailable, renamed: "go(to:)")
    public func displayReadingOrderItem(at index: Int, progression: Double) {}
    
    @available(*, unavailable, renamed: "go(to:)")
    public func displayReadingOrderItem(with href: String) -> Int? { nil }
    
}

public func trimEpubHrefComments(_ href: String) -> String {
    if href.contains("#") {
        return String(href.prefix(while: { $0 != "#" }))
    } else {
        return href
    }
}
