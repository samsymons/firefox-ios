/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import UIKit
import Account
import Shared
import SnapKit
import Storage
import Sync
import XCGLogger

// TODO: same comment as for SyncAuthState.swift!
private let log = XCGLogger.defaultInstance()


private struct RemoteTabsPanelUX {
    static let HeaderHeight: CGFloat = SiteTableViewControllerUX.RowHeight // Not HeaderHeight!
    static let RowHeight: CGFloat = SiteTableViewControllerUX.RowHeight
    static let HeaderBackgroundColor = UIColor(rgb: 0xf8f8f8)

    static let EmptyStateTitleFont = UIFont.systemFontOfSize(15, weight: UIFontWeightMedium)
    static let EmptyStateTitleTextColor = UIColor.darkGrayColor()
    static let EmptyStateInstructionsFont = UIFont.systemFontOfSize(14, weight: UIFontWeightLight)
    static let EmptyStateInstructionsTextColor = UIColor.grayColor()
    static let EmptyStateInstructionsWidth = 226
    static let EmptyStateTopPaddingInBetweenItems: CGFloat = 10 // UX TODO I set this to 8 so that it all fits on landscape
    static let EmptyStateSignInButtonColor = UIColor(red:0.3, green:0.62, blue:1, alpha:1)
    static let EmptyStateSignInButtonTitleFont = UIFont.systemFontOfSize(16)
    static let EmptyStateSignInButtonTitleColor = UIColor.whiteColor()
    static let EmptyStateSignInButtonCornerRadius: CGFloat = 4
    static let EmptyStateSignInButtonHeight = 44
    static let EmptyStateSignInButtonWidth = 200
    static let EmptyStateCreateAccountButtonFont = UIFont.systemFontOfSize(12)
}

private let RemoteClientIdentifier = "RemoteClient"
private let RemoteTabIdentifier = "RemoteTab"

class RemoteTabsPanel: UITableViewController, HomePanel {
    weak var homePanelDelegate: HomePanelDelegate? = nil
    var profile: Profile!

    init() {
        super.init(nibName: nil, bundle: nil)
        NSNotificationCenter.defaultCenter().addObserver(self, selector: "notificationReceived:", name: NotificationFirefoxAccountChanged, object: nil)
        NSNotificationCenter.defaultCenter().addObserver(self, selector: "notificationReceived:", name: NotificationPrivateDataCleared, object: nil)
    }

    required init!(coder aDecoder: NSCoder!) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        tableView.registerClass(TwoLineHeaderFooterView.self, forHeaderFooterViewReuseIdentifier: RemoteClientIdentifier)
        tableView.registerClass(TwoLineTableViewCell.self, forCellReuseIdentifier: RemoteTabIdentifier)

        tableView.rowHeight = RemoteTabsPanelUX.RowHeight
        tableView.separatorInset = UIEdgeInsetsZero

        tableView.delegate = nil
        tableView.dataSource = nil

        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: "SELrefresh", forControlEvents: UIControlEvents.ValueChanged)

        view.backgroundColor = UIConstants.PanelBackgroundColor
    }

    deinit {
        NSNotificationCenter.defaultCenter().removeObserver(self, name: NotificationFirefoxAccountChanged, object: nil)
        NSNotificationCenter.defaultCenter().removeObserver(self, name: NotificationPrivateDataCleared, object: nil)
    }

    override func viewWillAppear(animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
    }

    func notificationReceived(notification: NSNotification) {
        switch notification.name {
        case NotificationFirefoxAccountChanged, NotificationPrivateDataCleared:
            refresh()
            break
        default:
            // no need to do anything at all
            log.warning("Received unexpected notification \(notification.name)")
            break
        }
    }

    var tableViewDelegate: RemoteTabsPanelDataSource? {
        didSet {
            self.tableView.delegate = tableViewDelegate
            self.tableView.dataSource = tableViewDelegate
        }
    }

    func refresh() {
        tableView.scrollEnabled = false
        tableView.allowsSelection = false
        tableView.tableFooterView = UIView(frame: CGRectZero)

        // Short circuit if the user is not logged in
        if profile.getAccount() == nil {
            self.tableViewDelegate = RemoteTabsPanelErrorDataSource(homePanel: self, error: .NotLoggedIn)
            self.tableView.reloadData()
            return
        }

        self.profile.getCachedClientsAndTabs().uponQueue(dispatch_get_main_queue()) { result in
            if let clientAndTabs = result.successValue {
                self.updateDelegateClientAndTabData(clientAndTabs)
            }

            // Otherwise, fetch the tabs cloud if its been more than 1 minute since last sync
            let lastSyncTime = self.profile.prefs.timestampForKey(PrefsKeys.KeyLastRemoteTabSyncTime)
            if NSDate.now() - (lastSyncTime ?? 0) > OneMinuteInMilliseconds {
                self.profile.getClientsAndTabs().uponQueue(dispatch_get_main_queue()) { result in
                    if let clientAndTabs = result.successValue {
                        self.profile.prefs.setTimestamp(NSDate.now(), forKey: PrefsKeys.KeyLastRemoteTabSyncTime)
                        self.updateDelegateClientAndTabData(clientAndTabs)
                    }
                    self.endRefreshing()
                }
            } else {
                // If we failed before and didn't sync, show the failure delegate
                if let failed = result.failureValue {
                    self.tableViewDelegate = RemoteTabsPanelErrorDataSource(homePanel: self, error: .FailedToSync)
                }

                self.endRefreshing()
            }
        }
    }

    func endRefreshing() {
        self.refreshControl?.endRefreshing()
        self.tableView.scrollEnabled = true
        self.tableView.reloadData()
    }

    func updateDelegateClientAndTabData(clientAndTabs: [ClientAndTabs]) {
        if clientAndTabs.count == 0 {
            self.tableViewDelegate = RemoteTabsPanelErrorDataSource(homePanel: self, error: .NoClients)
        } else {
            let nonEmptyClientAndTabs = clientAndTabs.filter { $0.tabs.count > 0 }
            if nonEmptyClientAndTabs.count == 0 {
                self.tableViewDelegate = RemoteTabsPanelErrorDataSource(homePanel: self, error: .NoTabs)
            } else {
                self.tableViewDelegate = RemoteTabsPanelClientAndTabsDataSource(homePanel: self, clientAndTabs: nonEmptyClientAndTabs)
                self.tableView.allowsSelection = true
            }
        }
    }

    @objc private func SELrefresh() {
        self.refreshControl?.beginRefreshing()
        refresh()
    }

}

enum RemoteTabsError {
    case NotLoggedIn
    case NoClients
    case NoTabs
    case FailedToSync

    func localizedString() -> String {
        switch self {
        case NotLoggedIn:
            return "" // This does not have a localized string because we have a whole specific screen for it.
        case NoClients:
            return NSLocalizedString("You don't have any other devices connected to this Firefox Account available to sync.", comment: "Error message in the remote tabs panel")
        case NoTabs:
            return NSLocalizedString("You don't have any tabs open in Firefox on your other devices.", comment: "Error message in the remote tabs panel")
        case FailedToSync:
            return NSLocalizedString("There was a problem accessing tabs from your other devices. Try again in a few moments.", comment: "Error message in the remote tabs panel")
        }
    }
}

protocol RemoteTabsPanelDataSource: UITableViewDataSource, UITableViewDelegate {
}

class RemoteTabsPanelClientAndTabsDataSource: NSObject, RemoteTabsPanelDataSource {
    weak var homePanel: HomePanel?
    private var clientAndTabs: [ClientAndTabs]

    init(homePanel: HomePanel, clientAndTabs: [ClientAndTabs]) {
        self.homePanel = homePanel
        self.clientAndTabs = clientAndTabs
    }

    func numberOfSectionsInTableView(tableView: UITableView) -> Int {
        return self.clientAndTabs.count
    }

    func tableView(tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.clientAndTabs[section].tabs.count
    }

    func tableView(tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return RemoteTabsPanelUX.HeaderHeight
    }

    func tableView(tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let clientTabs = self.clientAndTabs[section]
        let client = clientTabs.client
        let view = tableView.dequeueReusableHeaderFooterViewWithIdentifier(RemoteClientIdentifier) as! TwoLineHeaderFooterView
        view.frame = CGRect(x: 0, y: 0, width: tableView.frame.width, height: RemoteTabsPanelUX.HeaderHeight)
        view.textLabel.text = client.name
        view.contentView.backgroundColor = RemoteTabsPanelUX.HeaderBackgroundColor

        /*
        * A note on timestamps.
        * We have access to two timestamps here: the timestamp of the remote client record,
        * and the set of timestamps of the client's tabs.
        * Neither is "last synced". The client record timestamp changes whenever the remote
        * client uploads its record (i.e., infrequently), but also whenever another device
        * sends a command to that client -- which can be much later than when that client
        * last synced.
        * The client's tabs haven't necessarily changed, but it can still have synced.
        * Ideally, we should save and use the modified time of the tabs record itself.
        * This will be the real time that the other client uploaded tabs.
        */

        let timestamp = clientTabs.approximateLastSyncTime()
        let label = NSLocalizedString("Last synced: %@", comment: "Remote tabs last synced time. Argument is the relative date string.")
        view.detailTextLabel.text = String(format: label, NSDate.fromTimestamp(timestamp).toRelativeTimeString())

        let image: UIImage?
        if client.type == "desktop" {
            image = UIImage(named: "deviceTypeDesktop")
            image?.accessibilityLabel = NSLocalizedString("computer", comment: "Accessibility label for Desktop Computer (PC) image in remote tabs list")
        } else {
            image = UIImage(named: "deviceTypeMobile")
            image?.accessibilityLabel = NSLocalizedString("mobile device", comment: "Accessibility label for Mobile Device image in remote tabs list")
        }
        view.imageView.image = image

        view.mergeAccessibilityLabels()
        return view
    }

    private func tabAtIndexPath(indexPath: NSIndexPath) -> RemoteTab {
        return clientAndTabs[indexPath.section].tabs[indexPath.item]
    }

    func tableView(tableView: UITableView, cellForRowAtIndexPath indexPath: NSIndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCellWithIdentifier(RemoteTabIdentifier, forIndexPath: indexPath) as! TwoLineTableViewCell
        let tab = tabAtIndexPath(indexPath)
        cell.setLines(tab.title, detailText: tab.URL.absoluteString)
        // TODO: Bug 1144765 - Populate image with cached favicons.
        return cell
    }

    func tableView(tableView: UITableView, didSelectRowAtIndexPath indexPath: NSIndexPath) {
        tableView.deselectRowAtIndexPath(indexPath, animated: false)
        let tab = tabAtIndexPath(indexPath)
        if let homePanel = self.homePanel {
            // It's not a bookmark, so let's call it Typed (which means History, too).
            homePanel.homePanelDelegate?.homePanel(homePanel, didSelectURL: tab.URL, visitType: VisitType.Typed)
        }
    }
}

// MARK: -

class RemoteTabsPanelErrorDataSource: NSObject, RemoteTabsPanelDataSource {
    weak var homePanel: HomePanel?
    var error: RemoteTabsError

    init(homePanel: HomePanel, error: RemoteTabsError) {
        self.homePanel = homePanel
        self.error = error
    }

    func numberOfSectionsInTableView(tableView: UITableView) -> Int {
        return 1
    }

    func tableView(tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return 1
    }

    func tableView(tableView: UITableView, heightForRowAtIndexPath indexPath: NSIndexPath) -> CGFloat {
        return tableView.bounds.height
    }

    func tableView(tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        // Making the footer height as small as possible because it will disable button tappability if too high.
        return 1
    }

    func tableView(tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        return UIView()
    }

    func tableView(tableView: UITableView, cellForRowAtIndexPath indexPath: NSIndexPath) -> UITableViewCell {
        switch error {
        case .NotLoggedIn:
            let cell = RemoteTabsNotLoggedInCell(homePanel: homePanel)
            return cell
        default:
            let cell = RemoteTabsErrorCell(error: self.error)
            return cell
        }
    }
}

// MARK: -

class RemoteTabsErrorCell: UITableViewCell {
    static let Identifier = "RemoteTabsErrorCell"

    init(error: RemoteTabsError) {
        super.init(style: .Default, reuseIdentifier: RemoteTabsErrorCell.Identifier)

        separatorInset = UIEdgeInsetsMake(0, 1000, 0, 0)

        let containerView = UIView()
        contentView.addSubview(containerView)

        let imageView = UIImageView()
        imageView.image = UIImage(named: "emptySync")
        containerView.addSubview(imageView)
        imageView.snp_makeConstraints { (make) -> Void in
            make.top.equalTo(containerView)
            make.centerX.equalTo(containerView)
        }

        let instructionsLabel = UILabel()
        instructionsLabel.font = RemoteTabsPanelUX.EmptyStateInstructionsFont
        instructionsLabel.text = error.localizedString()
        instructionsLabel.textAlignment = NSTextAlignment.Center
        instructionsLabel.textColor = RemoteTabsPanelUX.EmptyStateInstructionsTextColor
        instructionsLabel.numberOfLines = 0
        containerView.addSubview(instructionsLabel)
        instructionsLabel.snp_makeConstraints({ (make) -> Void in
            make.top.equalTo(imageView.snp_bottom).offset(RemoteTabsPanelUX.EmptyStateTopPaddingInBetweenItems)
            make.centerX.equalTo(containerView)
            make.width.equalTo(RemoteTabsPanelUX.EmptyStateInstructionsWidth)
        })

        containerView.snp_makeConstraints({ (make) -> Void in
            // Let the container wrap around the content
            make.top.equalTo(imageView.snp_top)
            make.left.bottom.right.equalTo(instructionsLabel)
            // And then center it in the overlay view that sits on top of the UITableView
            make.center.equalTo(contentView)
        })
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: -

class RemoteTabsNotLoggedInCell: UITableViewCell {
    static let Identifier = "RemoteTabsNotLoggedInCell"
    var homePanel: HomePanel?

    init(homePanel: HomePanel?) {
        super.init(style: .Default, reuseIdentifier: RemoteTabsErrorCell.Identifier)

        self.homePanel = homePanel

        let containerView = UIView()
        contentView.addSubview(containerView)

        let imageView = UIImageView()
        imageView.image = UIImage(named: "emptySync")
        containerView.addSubview(imageView)
        imageView.snp_makeConstraints { (make) -> Void in
            make.top.equalTo(containerView)
            make.centerX.equalTo(containerView)
        }

        let titleLabel = UILabel()
        titleLabel.font = RemoteTabsPanelUX.EmptyStateTitleFont
        titleLabel.text = NSLocalizedString("Welcome to Sync", comment: "See http://mzl.la/1Qtkf0j")
        titleLabel.textAlignment = NSTextAlignment.Center
        titleLabel.textColor = RemoteTabsPanelUX.EmptyStateTitleTextColor
        containerView.addSubview(titleLabel)
        titleLabel.snp_makeConstraints({ (make) -> Void in
            make.top.equalTo(imageView.snp_bottom).offset(RemoteTabsPanelUX.EmptyStateTopPaddingInBetweenItems)
            make.centerX.equalTo(containerView)
        })

        let instructionsLabel = UILabel()
        instructionsLabel.font = RemoteTabsPanelUX.EmptyStateInstructionsFont
        instructionsLabel.text = NSLocalizedString("Sync your tabs, bookmarks, passwords and more.", comment: "See http://mzl.la/1Qtkf0j")
        instructionsLabel.textAlignment = NSTextAlignment.Center
        instructionsLabel.textColor = RemoteTabsPanelUX.EmptyStateInstructionsTextColor
        instructionsLabel.numberOfLines = 0
        containerView.addSubview(instructionsLabel)
        instructionsLabel.snp_makeConstraints({ (make) -> Void in
            make.top.equalTo(titleLabel.snp_bottom).offset(RemoteTabsPanelUX.EmptyStateTopPaddingInBetweenItems)
            make.centerX.equalTo(containerView)
            make.width.equalTo(RemoteTabsPanelUX.EmptyStateInstructionsWidth)
        })

        let signInButton = UIButton()
        signInButton.backgroundColor = RemoteTabsPanelUX.EmptyStateSignInButtonColor
        signInButton.setTitle(NSLocalizedString("Sign in", comment: "See http://mzl.la/1Qtkf0j"), forState: .Normal)
        signInButton.setTitleColor(RemoteTabsPanelUX.EmptyStateSignInButtonTitleColor, forState: .Normal)
        signInButton.titleLabel?.font = RemoteTabsPanelUX.EmptyStateSignInButtonTitleFont
        signInButton.layer.cornerRadius = RemoteTabsPanelUX.EmptyStateSignInButtonCornerRadius
        signInButton.clipsToBounds = true
        signInButton.addTarget(self, action: "SELsignIn", forControlEvents: UIControlEvents.TouchUpInside)
        containerView.addSubview(signInButton)
        signInButton.snp_makeConstraints { (make) -> Void in
            make.centerX.equalTo(containerView)
            make.top.equalTo(instructionsLabel.snp_bottom).offset(RemoteTabsPanelUX.EmptyStateTopPaddingInBetweenItems)
            make.height.equalTo(RemoteTabsPanelUX.EmptyStateSignInButtonHeight)
            make.width.equalTo(RemoteTabsPanelUX.EmptyStateSignInButtonWidth)
        }

        let createAnAccountButton = UIButton.buttonWithType(UIButtonType.System) as! UIButton
        createAnAccountButton.setTitle(NSLocalizedString("Create an account", comment: "See http://mzl.la/1Qtkf0j"), forState: .Normal)
        createAnAccountButton.titleLabel?.font = RemoteTabsPanelUX.EmptyStateCreateAccountButtonFont
        createAnAccountButton.addTarget(self, action: "SELcreateAnAccount", forControlEvents: UIControlEvents.TouchUpInside)
        containerView.addSubview(createAnAccountButton)
        createAnAccountButton.snp_makeConstraints({ (make) -> Void in
            make.centerX.equalTo(containerView)
            make.top.equalTo(signInButton.snp_bottom).offset(RemoteTabsPanelUX.EmptyStateTopPaddingInBetweenItems)
        })

        containerView.snp_makeConstraints({ (make) -> Void in
            // Let the container wrap around the content
            make.top.equalTo(contentView.snp_top).offset(20)
            make.bottom.equalTo(createAnAccountButton)
            make.left.equalTo(signInButton)
            make.right.equalTo(signInButton)
            // And then center it in the overlay view that sits on top of the UITableView
            make.centerX.equalTo(contentView)
        })
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func SELsignIn() {
        if let homePanel = self.homePanel {
            homePanel.homePanelDelegate?.homePanelDidRequestToSignIn(homePanel)
        }
    }

    @objc private func SELcreateAnAccount() {
        if let homePanel = self.homePanel {
            homePanel.homePanelDelegate?.homePanelDidRequestToCreateAccount(homePanel)
        }
    }
}
