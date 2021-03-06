//
//  InterfaceController.swift
//  scoutwatch WatchKit Extension
//
//  Created by Dirk Hermanns on 20.11.15.
//  Copyright © 2015 private. All rights reserved.
//

import WatchKit
import Foundation
import WatchConnectivity
import SpriteKit

@available(watchOSApplicationExtension 3.0, *)
class InterfaceController: WKInterfaceController, WKCrownDelegate {

    @IBOutlet var bgLabel: WKInterfaceLabel!
    @IBOutlet var deltaLabel: WKInterfaceLabel!
    @IBOutlet var deltaArrowLabel: WKInterfaceLabel!
    @IBOutlet var timeLabel: WKInterfaceLabel!
    @IBOutlet var batteryLabel: WKInterfaceLabel!
    @IBOutlet var spriteKitView: WKInterfaceSKScene!
    @IBOutlet var iobLabel: WKInterfaceLabel!
    @IBOutlet var errorLabel: WKInterfaceLabel!
    @IBOutlet var errorGroup: WKInterfaceGroup!
    @IBOutlet var activityIndicatorImage: WKInterfaceImage!
    
    @IBOutlet var rawbgLabel: WKInterfaceLabel!
    @IBOutlet var noiseLabel: WKInterfaceLabel!
    @IBOutlet var rawValuesGroup: WKInterfaceGroup!
    
    // set by AppMessageService when receiving data from phone app and charts should be repainted
    var shouldRepaintChartsOnActivation = false
    
    fileprivate var chartScene : ChartScene = ChartScene(size: CGSize(width: 320, height: 280), newCanvasWidth: 1024)
    
    // timer to check continuously for new bgValues
    fileprivate var timer = Timer()
    // check every 30 Seconds whether new bgvalues should be retrieved
    fileprivate let timeInterval : TimeInterval = 30.0
    
    fileprivate var zoomingIsActive : Bool = false
    fileprivate var nrOfCrownRotations : Int = 0
    
    // Old values that have been read before
    fileprivate var cachedTodaysBgValues : [BloodSugar] = []
    fileprivate var cachedYesterdaysBgValues : [BloodSugar] = []
    
    fileprivate var isActive: Bool = false
    fileprivate var isFirstActivation: Bool = true
    fileprivate var isRawValuesGroupHidden: Bool = false
    
    override func awake(withContext context: Any?) {
        super.awake(withContext: context)
        
        // Initialize the ChartScene
        let bounds = WKInterfaceDevice.current().screenBounds
        let chartSceneHeight = determineSceneHeightFromCurrentWatchType(interfaceBounds: bounds)
        chartScene = ChartScene(size: CGSize(width: bounds.width, height: chartSceneHeight), newCanvasWidth: bounds.width * 6)
        spriteKitView.presentScene(chartScene)
        
        activityIndicatorImage.setImageNamed("Activity")
        errorGroup.setHidden(true)
        
        createMenuItems()
        
        BackgroundRefreshLogger.info("InterfaceController is awake!")
    }
    
    fileprivate func determineSceneHeightFromCurrentWatchType(interfaceBounds : CGRect) -> CGFloat {
        
        if (interfaceBounds.height == 195.0) {
            // Apple Watch 42mm
            return 145.0
        }
        
        // interfaceBounds.height == 170.0
        // Apple Watch 38mm
        return 125.0
    }
    
    override func willActivate() {
        super.willActivate()
        
        guard WKExtension.shared().applicationState == .active else {
            return
        }
        
        isActive = true
        spriteKitView.isPaused = false
        
        // Start the timer to retrieve new bgValues and update the ui periodically
        // if the user keeps the display active for a longer time
        createNewTimerSingleton()
        
        // manually refresh the gui by fireing the timer
        updateNightscoutData(forceRefresh: isFirstActivation, forceRepaintCharts: shouldRepaintChartsOnActivation)
                
        // Ask to get 8 minutes of cpu runtime to get the next values if
        // the app stays in frontmost state
        if #available(watchOSApplicationExtension 4.0, *) {
            WKExtension.shared().isFrontmostTimeoutExtended = true
        }
        
        crownSequencer.focus()
        crownSequencer.delegate = self
        
        paintChartData(todaysData: cachedTodaysBgValues, yesterdaysData: cachedYesterdaysBgValues, moveToLatestValue: false)
        
        // reset the first activation flag!
        isFirstActivation = false
        // ... and the "should repaint charts" flag
        shouldRepaintChartsOnActivation = false
    }
    
    override func didAppear() {
        super.didAppear()
        
        spriteKitView.isPaused = false
        
        crownSequencer.focus()
        crownSequencer.delegate = self
    }
    
    override func willDisappear() {
        super.willDisappear()
        
        spriteKitView.isPaused = true
    }
    
    override func didDeactivate() {
        // This method is called when watch view controller is no longer visible
        super.didDeactivate()
        
        isActive = false
        timer.invalidate()
        spriteKitView.isPaused = true
    }
    
    // called when the crown rotates, rotationalDelta is the change since the last call (sign indicates direction).
    func crownDidRotate(_ crownSequencer: WKCrownSequencer?, rotationalDelta: Double) {
        
        if zoomingIsActive {
            nrOfCrownRotations += 1
            // only recognize every third rotation => Otherwise the watch will crash
            // because of too many calls a second
            if nrOfCrownRotations % 5 == 0 && abs(rotationalDelta) > 0.01 {
                chartScene.scale(1 + CGFloat(rotationalDelta), keepScale: true, infoLabelText: determineInfoLabel())
            }
        } else {
            chartScene.moveChart(rotationalDelta * 200)
        }
    }
    
    @objc func doInfoMenuAction() {
        self.presentController(withName: "InfoInterfaceController", context: nil)
    }
    
    @objc func doSnoozeMenuAction() {
        self.presentController(withName: "SnoozeInterfaceController", context: nil)
        loadAndPaintChartData(forceRepaint : true)
    }
    
    @objc func doRefreshMenuAction() {
        NightscoutCacheService.singleton.resetCache()
        
        loadAndPaintCurrentBgData()
        loadAndPaintChartData(forceRepaint: true)
    }
    
    @objc func doToogleZoomScrollAction() {
        zoomingIsActive = !zoomingIsActive
        createMenuItems()
    }
    
    @objc func doCloseMenuAction() {
        // nothing to do - closes automatically
    }
    
    fileprivate func createNewTimerSingleton() {
        if !timer.isValid {
            timer = Timer.scheduledTimer(timeInterval: timeInterval,
                                         target: self,
                                         selector: #selector(InterfaceController.timerDidEnd(_:)),
                                         userInfo: nil,
                                         repeats: true)
            // allow WatchOs to call this timer 30 seconds later as requested
            timer.tolerance = timeInterval
        }
    }
    
    fileprivate func updateNightscoutData(forceRefresh: Bool, forceRepaintCharts: Bool) {
        assureThatBaseUriIsExisting()
        assureThatDisplayUnitsIsDefined()
        
        let currentNightscoutData = NightscoutCacheService.singleton.getCurrentNightscoutData()
        if forceRefresh || currentNightscoutData.isOlderThan5Minutes() {
            
            // load current bg data, we probably have old data...
            loadAndPaintCurrentBgData()
        } else {
            
            // otwherwise just update the gui with current data (will update the time, etc., but will not display the activity indicator & error panel)
            updateInterface(withNightscoutData: currentNightscoutData, error: nil)
            playAlarm(currentNightscoutData: currentNightscoutData)
        }
        
        loadAndPaintChartData(forceRepaint: forceRepaintCharts)
        AlarmRule.alertIfAboveValue = UserDefaultsRepository.readUpperLowerBounds().upperBound
        AlarmRule.alertIfBelowValue = UserDefaultsRepository.readUpperLowerBounds().lowerBound
    }
        
    // check whether new Values should be retrieved
    @objc func timerDidEnd(_ timer:Timer){
        updateNightscoutData(forceRefresh: false, forceRepaintCharts: false)
    }
    
    @IBAction func onLabelsGroupDoubleTapped(_ sender: Any) {
        updateNightscoutData(forceRefresh: true, forceRepaintCharts: false)
    }
    
    @IBAction func onSpriteKitViewDoubleTapped(_ sender: Any) {
        updateNightscoutData(forceRefresh: true, forceRepaintCharts: false)
    }
    
    // this has to be created programmatically, since only this way
    // the item Zoom/Scroll can be toggled
    fileprivate func createMenuItems() {
        
        self.clearAllMenuItems()
        self.addMenuItem(with: WKMenuItemIcon.info, title: "Info", action: #selector(InterfaceController.doInfoMenuAction))
        self.addMenuItem(with: WKMenuItemIcon.resume, title: "Refresh", action: #selector(InterfaceController.doRefreshMenuAction))
        self.addMenuItem(with: WKMenuItemIcon.block, title: "Snooze", action: #selector(InterfaceController.doSnoozeMenuAction))
        self.addMenuItem(with: WKMenuItemIcon.more, title: zoomingIsActive ? "Scroll" : "Zoom", action: #selector(InterfaceController.doToogleZoomScrollAction))
    }
    
    fileprivate func assureThatBaseUriIsExisting() {
        
        if UserDefaultsRepository.readBaseUri().isEmpty {
            AppMessageService.singleton.requestBaseUri()
        }
    }
    
    fileprivate func assureThatDisplayUnitsIsDefined() {
        
        if !UserDefaultsRepository.areUnitsDefined() {
            // try to determine whether the user wishes to see value in mmol or mg/dL
            NightscoutService.singleton.readStatus { (units) in
                UserDefaultsRepository.saveUnits(units)
            }
        }
    }
    
    // Returns true, if the size of one array changed
    fileprivate func valuesChanged(newCachedTodaysBgValues : [BloodSugar], newCachedYesterdaysBgValues : [BloodSugar]) -> Bool {
        
        return newCachedTodaysBgValues.count != cachedTodaysBgValues.count ||
                newCachedYesterdaysBgValues.count != cachedYesterdaysBgValues.count
    }
    
    func updateInterface(withNightscoutData nightscoutData: NightscoutData?, error: Error?) {
        
        // stop & hide the activity indicator
        self.activityIndicatorImage.stopAnimating()
        self.activityIndicatorImage.setHidden(true)
        
        if let error = error {
            
            // show errors ONLY when the interface is active (connection errors can be received while it is inactive... don't know for the moment why)
            // NOTE: actually, the whole UI should be updated only when the interface is active...
            if self.isActive {
                self.errorLabel.setText("❌ \(error.localizedDescription)")
                self.errorGroup.setHidden(false)
            } else {
                self.errorGroup.setHidden(true)
            }
        } else if let nightscoutData = nightscoutData {
            self.errorGroup.setHidden(true)
            self.paintCurrentBgData(currentNightscoutData: nightscoutData)
        }
    }
    
    fileprivate func loadAndPaintCurrentBgData() {
        
        let currentNightscoutData = NightscoutCacheService.singleton.loadCurrentNightscoutData({(newNightscoutData, error) -> Void in
            
            DispatchQueue.main.async { [unowned self] in
                self.updateInterface(withNightscoutData: newNightscoutData, error: error)
                if let newNightscoutData = newNightscoutData {
                    self.updateComplication()
                    self.playAlarm(currentNightscoutData: newNightscoutData)
                }
            }
        })
        
        paintCurrentBgData(currentNightscoutData: currentNightscoutData)
        self.playAlarm(currentNightscoutData: currentNightscoutData)
        
        // show the activity indicator (hide the iob & arrow overlapping views); also hide the errors
        self.errorGroup.setHidden(true)
        self.iobLabel.setText(nil)
        self.deltaArrowLabel.setText(nil)
        
        self.activityIndicatorImage.setHidden(false)
        self.activityIndicatorImage.startAnimatingWithImages(in: NSRange(1...15), duration: 1.0, repeatCount: 0)
    }
    
    fileprivate func playAlarm(currentNightscoutData : NightscoutData) {
        
        let newCachedTodaysBgValues = NightscoutCacheService.singleton.loadTodaysData({ ([BloodSugar]) -> Void in })
        if AlarmRule.isAlarmActivated(currentNightscoutData, bloodValues: newCachedTodaysBgValues) {
            WKInterfaceDevice.current().play(.notification)
        }
    }
    
    fileprivate func updateComplication() {
        let complicationServer = CLKComplicationServer.sharedInstance()
        for complication in complicationServer.activeComplications! {
            complicationServer.reloadTimeline(for: complication)
        }
    }
    
    fileprivate func paintCurrentBgData(currentNightscoutData : NightscoutData) {
        
        self.bgLabel.setText(currentNightscoutData.sgv)
        self.bgLabel.setTextColor(UIColorChanger.getBgColor(currentNightscoutData.sgv))
        
        self.deltaLabel.setText(currentNightscoutData.bgdeltaString.cleanFloatValue)
        self.deltaArrowLabel.setText(currentNightscoutData.bgdeltaArrow)
        self.deltaLabel.setTextColor(UIColorChanger.getDeltaLabelColor(NSNumber(value : currentNightscoutData.bgdelta)))
        
        self.timeLabel.setText(currentNightscoutData.timeString)
        self.timeLabel.setTextColor(UIColorChanger.getTimeLabelColor(currentNightscoutData.time))
        
        self.batteryLabel.setText(currentNightscoutData.battery)
        self.iobLabel.setText(currentNightscoutData.iob)
        
        // show raw values panel ONLY if configured so and we have a valid rawbg value!
        let isValidRawBGValue = UnitsConverter.toMgdl(currentNightscoutData.rawbg) > 0
        self.rawValuesGroup.setHidden(!UserDefaultsRepository.readShowRawBG() || !isValidRawBGValue)
        self.rawbgLabel.setText(currentNightscoutData.rawbg)
        self.noiseLabel.setText(currentNightscoutData.noise)
    }
    
    func loadAndPaintChartData(forceRepaint : Bool) {
        
        let newCachedTodaysBgValues = NightscoutCacheService.singleton.loadTodaysData({(newTodaysData) -> Void in
            
            DispatchQueue.main.async {
                self.cachedTodaysBgValues = newTodaysData
                self.paintChartData(todaysData: newTodaysData, yesterdaysData: self.cachedYesterdaysBgValues, moveToLatestValue: true)
            }
        })
        let newCachedYesterdaysBgValues = NightscoutCacheService.singleton.loadYesterdaysData({(newYesterdaysData) -> Void in
            
            DispatchQueue.main.async {
                self.cachedYesterdaysBgValues = newYesterdaysData
                self.paintChartData(todaysData: self.cachedTodaysBgValues, yesterdaysData: newYesterdaysData, moveToLatestValue: false)
            }
        })
        
        // this does a fast paint of eventually cached data
        if forceRepaint ||
            valuesChanged(newCachedTodaysBgValues: newCachedTodaysBgValues, newCachedYesterdaysBgValues: newCachedYesterdaysBgValues) {
            
            cachedTodaysBgValues = newCachedTodaysBgValues
            cachedYesterdaysBgValues = newCachedYesterdaysBgValues
            paintChartData(todaysData: cachedTodaysBgValues, yesterdaysData: cachedYesterdaysBgValues, moveToLatestValue: false)
        }
    }
    
    fileprivate func paintChartData(todaysData : [BloodSugar], yesterdaysData : [BloodSugar], moveToLatestValue : Bool) {
        
        let bounds = WKInterfaceDevice.current().screenBounds
        self.chartScene.paintChart(
            [todaysData, yesterdaysData],
            newCanvasWidth: bounds.width * 6,
            maxYDisplayValue: CGFloat(UserDefaultsRepository.readMaximumBloodGlucoseDisplayed()),
            moveToLatestValue: moveToLatestValue,
            displayDaysLegend: false,
            infoLabel: determineInfoLabel())
    }
    
    func determineInfoLabel() -> String {
        
        if !AlarmRule.isSnoozed() {
            return ""
        }
        
        return "Snoozed " + String(AlarmRule.getRemainingSnoozeMinutes()) + "min"
    }

}
