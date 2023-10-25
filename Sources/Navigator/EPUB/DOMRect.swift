//
//  DOMRect.swift
//  R2Navigator
//
//  Created by Calvin Collins on 8/3/22.
//

import Foundation

public struct DOMRect: Equatable, Hashable {
    public var x: Double
    public var y: Double
    public var height: Double
    public var width: Double
    public var innerHTML: String
    public var intersectionRatio: Double
    
    public init?(jsonDictionary: [String: Any]) {
        if let x = jsonDictionary["x"] as? Double,
            let y = jsonDictionary["y"] as? Double,
            let height = jsonDictionary["height"] as? Double,
            let width = jsonDictionary["width"] as? Double,
            let innerHTML = jsonDictionary["innerHTML"] as? String,
            let intersectionRatio = jsonDictionary["intersectionRatio"] as? Double {
            
            self.x = x
            self.y = y
            self.height = height
            self.width = width
            self.innerHTML = innerHTML
            self.intersectionRatio = intersectionRatio
        } else {
            return nil
        }
    }
    
    public func toRect() -> CGRect {
        return CGRect(x: x, y: y, width: width, height: height)
    }
    
    public static func ==(lhs: DOMRect, rhs: DOMRect) -> Bool {
        return lhs.innerHTML == rhs.innerHTML
    }
}
