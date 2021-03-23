/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import UIKit
import SnapKit
import Foundation

struct EmptyPrivateTabsViewUX {
    static let TitleFont = UIFont.systemFont(ofSize: 22, weight: UIFont.Weight.medium)
    static let DescriptionFont = UIFont.systemFont(ofSize: 17)
    static let TextMargin: CGFloat = 18
    static let MaxDescriptionWidth: CGFloat = 250
    static let MinBottomMargin: CGFloat = 10
}

// View we display when there are no private tabs created
class EmptyPrivateTabsView: UIView {
    lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.textColor = UIColor.Photon.White100
        label.font = EmptyPrivateTabsViewUX.TitleFont
        label.textAlignment = .center
        return label
    }()

    var descriptionLabel: UILabel = {
        let label = UILabel()
        label.textColor = UIColor.Photon.White100
        label.font = EmptyPrivateTabsViewUX.DescriptionFont
        label.textAlignment = .center
        label.numberOfLines = 0
        label.preferredMaxLayoutWidth = EmptyPrivateTabsViewUX.MaxDescriptionWidth
        return label
    }()

    fileprivate var iconImageView: UIImageView = {
        let imageView = UIImageView(image: UIImage.templateImageNamed("largePrivateMask"))
        imageView.tintColor = UIColor.Photon.Grey60
        return imageView
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)

        titleLabel.text =  .PrivateBrowsingTitle
        descriptionLabel.text = .TabTrayPrivateBrowsingDescription

        addSubview(titleLabel)
        addSubview(descriptionLabel)
        addSubview(iconImageView)

        titleLabel.snp.makeConstraints { make in
            make.center.equalTo(self)
        }

        iconImageView.snp.makeConstraints { make in
            make.bottom.equalTo(titleLabel.snp.top)
            make.height.width.equalTo(120)
            make.centerX.equalTo(self)
        }

        descriptionLabel.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(EmptyPrivateTabsViewUX.TextMargin)
            make.centerX.equalTo(self)
        }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
