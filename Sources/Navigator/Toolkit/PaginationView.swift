//
//  Copyright 2020 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import UIKit
import R2Shared
    
enum PageLocation: Equatable {
    case start
    case end
    case locator(Locator)
    
    init(_ locator: Locator?) {
        self = locator.map { .locator($0) }
            ?? .start
    }
    
    var isStart: Bool {
        switch self {
        case .start:
            return true
        case .locator(let locator) where locator.locations.progression ?? 0 == 0:
            return true
        default:
            return false
        }
    }
    
}

protocol PageView {
    /// Moves the page to the given internal location.
    func go(to location: PageLocation, completion: (() -> Void)?)
}

extension PageView {
    
    func go(to location: PageLocation) {
        go(to: location, completion: nil)
    }
    
}

protocol PaginationViewDelegate: AnyObject {
    /// Creates the page view for the page at given index.
    func paginationView(_ paginationView: PaginationView, pageViewAtIndex index: Int) -> (UIView & PageView)?
    
    /// Called when the page views were updated.
    func paginationViewDidUpdateViews(_ paginationView: PaginationView)

    /// Returns the number of positions (as in `Publication.positionList`) in the page view at given index.
    func paginationView(_ paginationView: PaginationView, positionCountAtIndex index: Int) -> Int
}

final class PaginationView: UIView, Loggable {
    
    weak var delegate: PaginationViewDelegate?

    /// Total number of page views to be paginated.
    private(set) var pageCount: Int = 0
    
    /// Index of the page currently being displayed.
    private(set) var currentIndex: Int = 0

    /// Direction for the reading progression.
    private(set) var readingProgression: ReadingProgression = .ltr
    
    /// Pre-loaded page views, indexed by their position.
    private(set) var loadedViews: [Int: (UIView & PageView)] = [:]
    
    // Pre-loaded page numbers, for non-consecutive chapters given an array of Links
    public var pageNumbers: [Int]?
    
    /// Number of positions (as in `Publication.positionList`) to preload before and after the
    /// current page.
    private let preloadPreviousPositionCount: Int
    private let preloadNextPositionCount: Int
    public var verticalScroll: Bool

    /// Queue of page index to be loaded next.
    private var loadingIndexQueue: [(index: Int, location: PageLocation)] = []
    
    /// Returns whether the page views are loaded.
    var isEmpty: Bool {
        return loadedViews.isEmpty
    }

    /// Return the currently presented page view from the Views array.
    var currentView: (UIView & PageView)? {
        return loadedViews[currentIndex]
    }
    
    var currentViewContentHeight: CGFloat? {
        guard let spreadView = currentView as? EPUBSpreadView else { return nil }
        return spreadView.webView.scrollView.contentSize.height
    }
    
    /// Loaded page views in reading order.
    private var orderedViews: [UIView & PageView] {
        var orderedViews = loadedViews
            .sorted { $0.key < $1.key }
            .map { $0.value }
        
        if readingProgression == .rtl {
            orderedViews.reverse()
        }
        
        return orderedViews
    }

    private let scrollView = UIScrollView()
    
    init(frame: CGRect, preloadPreviousPositionCount: Int, preloadNextPositionCount: Int,
            verticalScroll: Bool) {
        self.preloadPreviousPositionCount = preloadPreviousPositionCount
        self.preloadNextPositionCount = preloadNextPositionCount
        self.verticalScroll = verticalScroll
        
        super.init(frame: frame)
        
        scrollView.delegate = self
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.flexibleHeight, .flexibleWidth]
        scrollView.isPagingEnabled = true
        scrollView.bounces = false
        scrollView.showsHorizontalScrollIndicator = false
        addSubview(scrollView)
        
        // Adds an empty view before the scroll view to have a consistent behavior on all iOS
        // versions, regarding to the content inset adjustements. Even if
        // `automaticallyAdjustsScrollViewInsets` is not set to false on the navigator's parent
        // view controller, the scroll view insets won't be adjusted if the scroll view is not the
        // first child in the subviews hierarchy.
        insertSubview(UIView(frame: .zero), at: 0)
        if #available(iOS 11.0, *) {
            // Prevents the content from jumping down when the status bar is toggled
            scrollView.contentInsetAdjustmentBehavior = .never
        }
    }
    
    @available(*, unavailable)
    public required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func numberOfChapters() -> Int {
        let minPage = pageNumbers?.first ?? 0
        let maxPage = pageNumbers?.last ?? pageCount
        var totalPages = maxPage - minPage + 1
        if let pageNumbers = pageNumbers {
            totalPages = Array(Set(pageNumbers)).count
        }
        return totalPages
    }
    
    public override func layoutSubviews() {
        guard !loadedViews.isEmpty else {
            scrollView.contentSize = bounds.size
            return
        }
        
        let size = scrollView.bounds.size
        if self.verticalScroll {
            var totalHeight: CGFloat = 0
            let minPage = pageNumbers?.first ?? 0
            let maxPage = pageNumbers?.last ?? pageCount
            var totalPages = maxPage - minPage + 1
            if let pageNumbers = pageNumbers {
                totalPages = Array(Set(pageNumbers)).count
            }
            totalHeight = size.height * CGFloat(totalPages)
            scrollView.contentSize = CGSize(width: size.width, height: totalHeight)
            for (index, view) in loadedViews {
                view.frame = CGRect(origin: CGPoint(x: 0, y: yOffsetForIndex(indexForTrimmedPage(index, minPage: minPage))), size: size)
            }
            scrollView.contentOffset.y = yOffsetForIndex(indexForTrimmedPage(currentIndex, minPage: minPage))
        }
        else {
            scrollView.contentSize = CGSize(width: size.width * CGFloat(pageCount), height: size.height)
            for (index, view) in loadedViews {
                view.frame = CGRect(origin: CGPoint(x: xOffsetForIndex(index), y:  0), size: size)
            }
            scrollView.contentOffset.x = xOffsetForIndex(currentIndex)
        }
    }
    
    /// Returns the x offset to the page view with given index in the scroll view.
    private func xOffsetForIndex(_ index: Int) -> CGFloat {
        return (readingProgression == .rtl)
            ? scrollView.contentSize.width - (CGFloat(index + 1) * scrollView.bounds.width)
            : scrollView.bounds.width * CGFloat(index)
    }
    private func yOffsetForIndex(_ index: Int) -> CGFloat {
        return (readingProgression == .rtl)
            ? scrollView.contentSize.height - (CGFloat(index + 1) * scrollView.bounds.height)
            : scrollView.bounds.height * CGFloat(index)
    }
    
    // finds the index within pageNumbers where the spread's index occurs, adjusted for the minimum page number
    private func indexForTrimmedPage(_ index: Int, minPage: Int) -> Int {
        guard let pageNumbers = pageNumbers, let pageIndex = Array(Set(pageNumbers)).sorted().firstIndex(of: index) else {
            return index - minPage
        }
        return Int(pageIndex)
    }
    
    /// Reloads the pagination with the given total number of pages and current index.
    ///
    /// - Parameters:
    ///   - index: Index of the page to be displayed after reloading the pagination.
    ///   - location: Location to be displayed in the page.
    ///   - pageCount: Total number of pages in the pagination view.
    ///   - readingProgression: Direction of reading progression.
    ///   - completion: Closure called when the location is loaded.
    func reloadAtIndex(_ index: Int, location: PageLocation, pageCount: Int, readingProgression: ReadingProgression, completion: @escaping () -> Void) {
        precondition(pageCount >= 1)
        precondition(0..<pageCount ~= index)
        
        self.pageCount = pageCount
        self.readingProgression = readingProgression
        
        for (_, view) in loadedViews {
            view.removeFromSuperview()
        }
        loadedViews.removeAll()
        loadingIndexQueue.removeAll()
        
        setCurrentIndex(index, location: location, completion: completion)
    }

    /// Updates the current and pre-loaded views.
    private func setCurrentIndex(_ index: Int, location: PageLocation? = nil, completion: @escaping () -> Void = {}) {
        let minPage = pageNumbers?.sorted().first ?? 0
        let maxPage = pageNumbers?.sorted().last ?? pageCount
        guard isEmpty || index != currentIndex, pageNumbers?.contains(index) ?? true else {
            completion()
            return
        }
        
        // If no explicit location is given, we'll load either the beginning or the end of the
        // resource depending on the last index. This allows to navigate backward across resources,
        // starting from the end of each previous resource.
        let movingBackward = (currentIndex > index)
        let location = location ?? (movingBackward ? .end : .start)

        currentIndex = index
        
        // To make sure that the views the most likely to be visible are loaded first, we first load
        // the current one, then the next ones and to finish the previous ones.
        scheduleLoadPage(at: index, location: location)
        let lastIndex = scheduleLoadPages(from: index, upToPositionCount: preloadNextPositionCount, direction: .forward, location: .start)
        let firstIndex = scheduleLoadPages(from: index, upToPositionCount: preloadPreviousPositionCount, direction: .backward, location: .end)

        for (i, view) in loadedViews {
            // Flushes the views that are not needed anymore.
            guard firstIndex...lastIndex ~= i else {
                view.removeFromSuperview()
                loadedViews.removeValue(forKey: i)
                continue
            }
        }

        loadNextPage {
            self.delegate?.paginationViewDidUpdateViews(self)
            completion()
        }
    }

    private func loadNextPage(completion: @escaping () -> Void = {}) {
        guard let (index, location) = loadingIndexQueue.popFirst() else {
            completion()
            return
        }

        if
           loadedViews[index] == nil,
           let view = delegate?.paginationView(self, pageViewAtIndex: index)
        {
            loadedViews[index] = view
            if numberOfChapters() == 1 {
                addSubview(view)
            } else {
                scrollView.addSubview(view)
            }
            setNeedsLayout()
        }

        guard let view = loadedViews[index] else {
            completion()
            return
        }

        view.go(to: location) { [weak self] in
            completion()
            self?.loadNextPage()
        }
    }

    /// Queue views to be loaded until reaching the given number of pre-loaded positions.
    ///
    /// - Parameters:
    ///   - positionCount: Number of positions to pre-load before stopping.
    ///   - sourceIndex: Starting page index from which to pre-load the views.
    ///   - direction: The direction in which to load the views from the sourceIndex.
    /// - Returns: The last page index to be loaded after reaching the requested number of positions.
    private func scheduleLoadPages(from sourceIndex: Int, upToPositionCount positionCount: Int, direction: PageIndexDirection, location: PageLocation) -> Int {
        var index = sourceIndex + direction.rawValue
        if let pageNumbers = pageNumbers {
            let sortedArray = Array(Set(pageNumbers)).sorted()
            let condition: (Int) -> Bool = direction.rawValue < 0 ? { $0 > 0 } : { $0 < sortedArray.count - 1 }
            if let indexInArray = sortedArray.firstIndex(of: sourceIndex), condition(indexInArray) {
                index = sortedArray[indexInArray + direction.rawValue]
            }
        }
        guard
            positionCount > 0,
            scheduleLoadPage(at: index, location: location),
            let indexPositionCount = delegate?.paginationView(self, positionCountAtIndex: index)
        else {
            return sourceIndex
        }

        return scheduleLoadPages(
            from: index,
            upToPositionCount: positionCount - indexPositionCount,
            direction: direction,
            location: location
        )
    }

    /// Queue a page to be loaded at the given index, if it's not already loaded.
    ///
    /// - Returns: Whether page is or will be loaded.
    @discardableResult
    private func scheduleLoadPage(at index: Int, location: PageLocation) -> Bool {
        guard 0..<pageCount ~= index else {
            return false
        }
        
        if let _ = delegate?.paginationView(self, pageViewAtIndex: index) {
            loadingIndexQueue.removeAll { $0.index == index }
            loadingIndexQueue.append((index: index, location: location))
            return true
        } else {
            return false
        }
    }

    private enum PageIndexDirection: Int {
        case forward = 1
        case backward = -1
    }
    
    
    // MARK: - Navigation
    
    /// Go to the page view with given index.
    ///
    /// - Parameters:
    ///   - index: The index to move to.
    ///   - location: The location to move the future current page view to.
    /// - Returns: Whether the move is possible.
    func goToIndex(_ index: Int, location: PageLocation, animated: Bool = false, completion: @escaping () -> Void) -> Bool {
        guard 0..<pageCount ~= index else {
            return false
        }

        func fade(to alpha: CGFloat, completion: @escaping () -> ()) {
            if animated {
                UIView.animate(withDuration: 0.15, animations: {
                    self.alpha = alpha
                }) { _ in completion() }
            } else {
                self.alpha = alpha
                completion()
            }
        }
        
        if index == currentIndex, let view = currentView {
            view.go(to: location, completion: completion)
            return true
        }

        fade(to: 0) {
            self.scrollToView(at: index, location: location) {
                fade(to: 1, completion: completion)
            }
        }

        return true
    }

    private func scrollToView(at index: Int, location: PageLocation, completion: @escaping () -> Void) {
        guard currentIndex != index else {
            if let view = currentView {
                view.go(to: location, completion: completion)
            } else {
                completion()
            }
            return
        }

        scrollView.isScrollEnabled = true
        setCurrentIndex(index, location: location, completion: completion)
        let minPage = pageNumbers?.sorted().first ?? 0

        scrollView.scrollRectToVisible(CGRect(
            origin: CGPoint(
                x: self.verticalScroll ? scrollView.contentOffset.x : xOffsetForIndex(index),
                y: self.verticalScroll ? yOffsetForIndex(indexForTrimmedPage(index, minPage: minPage)) : scrollView.contentOffset.y
            ),
            size: scrollView.frame.size
        ), animated: false)
    }
    
}


extension PaginationView: UIScrollViewDelegate {
    
    /// We disable the scroll once the user releases the drag to prevent scrolling through more than 1 resource at a
    /// time. Otherwise, because the pagination view's scroll view would have the focus during the scroll gesture, the
    /// scrollable content of the resources would be skipped.
    /// Note: using this approach might provide a better experience:
    /// https://oleb.net/blog/2014/05/scrollviews-inside-scrollviews/
    
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        scrollView.isScrollEnabled = false
    }
    
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        scrollView.isScrollEnabled = true
    }
    
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            scrollView.isScrollEnabled = true
        }
    }
    
    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scrollView.isScrollEnabled = true
        let minPage = pageNumbers?.first ?? 0
        if self.verticalScroll {
            let currentOffset = (readingProgression == .rtl)
                ? scrollView.contentSize.height - (scrollView.contentOffset.y + scrollView.frame.height)
                : scrollView.contentOffset.y
            var newIndex = Int(round(currentOffset / scrollView.frame.height))
            if let pageNumbers = self.pageNumbers {
                let sortedPages = Array(Set(pageNumbers)).sorted()
                newIndex = sortedPages[newIndex]
            }
            setCurrentIndex(newIndex)
        }
        else {
            let currentOffset = (readingProgression == .rtl)
                ? scrollView.contentSize.width - (scrollView.contentOffset.x + scrollView.frame.width)
                : scrollView.contentOffset.x
            let newIndex = Int(round(currentOffset / scrollView.frame.width))

            setCurrentIndex(newIndex)
        }
    }
}
