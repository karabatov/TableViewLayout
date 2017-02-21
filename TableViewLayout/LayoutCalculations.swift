//
//  LayoutCalculations.swift
//

import Foundation
import UIKit

struct LayoutCalculations{
    /// A simplified function to return target cell width immediately.
    static func cellWidthOnCurrentDevice() -> CGFloat {
        return cellWidthForView(nil)
    }

    static func cellWidthForView(_ view: UIView?) -> CGFloat {
        let traitCollection = view?.traitCollection ?? UIScreen.main.traitCollection
        let bounds = view?.bounds ?? UIScreen.main.bounds

        if traitCollection.horizontalSizeClass == .compact {
            return bounds.width
        } else {
            return Constants.tableViewCellWidthForRegularSizeClass
        }
    }
}
