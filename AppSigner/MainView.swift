//
//  ViewController.swift
//  AppSigner
//
//  Created by Daniel Radtke on 11/2/15.
//  Copyright © 2015 Daniel Radtke. All rights reserved.
//

import Cocoa

class MainView: NSView, URLSessionDataDelegate, URLSessionDelegate, URLSessionDownloadDelegate {
    
    //MARK: IBOutlets
    @IBOutlet var ProvisioningProfilesPopup: NSPopUpButton!
    @IBOutlet var CodesigningCertsPopup: NSPopUpButton!
    @IBOutlet var StatusLabel: NSTextField!
    @IBOutlet var InputFileText: NSTextField!
    @IBOutlet var BrowseButton: NSButton!
    @IBOutlet var StartButton: NSButton!
    @IBOutlet var NewApplicationIDTextField: NSTextField!
    @IBOutlet var downloadProgress: NSProgressIndicator!
    @IBOutlet var appDisplayName: NSTextField!
    @IBOutlet var appShortVersion: NSTextField!
    @IBOutlet var appVersion: NSTextField!
    
    //MARK: Variables
    var startSize: CGFloat?
    var NibLoaded = false
    
    //MARK: Constants
    let defaults = UserDefaults()
    let fileManager = FileManager.default
    
    //MARK: Drag / Drop
    var fileTypes: [String] = ["ipa","deb","app","xcarchive","mobileprovision"]
    var urlFileTypes: [String] = ["ipa","deb"]
    var fileTypeIsOk = false
    
    func fileDropped(_ filename: String){
        switch(filename.pathExtension.lowercased()){
        case "ipa", "deb", "app", "xcarchive":
            InputFileText.stringValue = filename
            break
            
        case "mobileprovision":
            ProvisioningProfilesPopup.selectItem(at: 1)
            checkProfileID(ProvisioningProfile(filename: filename))
            break
        default: break
            
        }
    }
    
    func urlDropped(_ url: NSURL){
        if let urlString = url.absoluteString {
            InputFileText.stringValue = urlString
        }
    }
    
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if checkExtension(sender) == true {
            self.fileTypeIsOk = true
            return .copy
        } else {
            self.fileTypeIsOk = false
            return NSDragOperation()
        }
    }
    
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if self.fileTypeIsOk {
            return .copy
        } else {
            return NSDragOperation()
        }
    }
    
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard()
        if let board = pasteboard.propertyList(forType: "NSFilenamesPboardType") as? NSArray {
            if let filePath = board[0] as? String {
                
                fileDropped(filePath)
                return true
            }
        }
        if let types = pasteboard.types {
            if types.contains(NSURLPboardType) {
                if let url = NSURL(from: pasteboard) {
                    urlDropped(url)
                }
            }
        }
        return false
    }
    
    func checkExtension(_ drag: NSDraggingInfo) -> Bool {
        if let board = drag.draggingPasteboard().propertyList(forType: "NSFilenamesPboardType") as? NSArray,
            let path = board[0] as? String {
                return self.fileTypes.contains(path.pathExtension.lowercased())
        }
        if let types = drag.draggingPasteboard().types {
            if types.contains(NSURLPboardType) {
                if let url = NSURL(from: drag.draggingPasteboard()),
                    let suffix = url.pathExtension {
                        return self.urlFileTypes.contains(suffix.lowercased())
                }
            }
        }
        return false
    }
    
    //MARK: Functions
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        register(forDraggedTypes: [NSFilenamesPboardType, NSURLPboardType])
        NotificationCenter.default.addObserver(self, selector: #selector(refreshStatus), name: NSNotification.Name(AppSigner.sharedInstance.refreshStatusNotification), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(cleanup), name: NSNotification.Name(AppSigner.sharedInstance.cleanupNotification), object: nil)
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        register(forDraggedTypes: [NSFilenamesPboardType, NSURLPboardType])
        NotificationCenter.default.addObserver(self, selector: #selector(refreshStatus), name: NSNotification.Name(AppSigner.sharedInstance.refreshStatusNotification), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(cleanup), name: NSNotification.Name(AppSigner.sharedInstance.cleanupNotification), object: nil)
    }
    override func awakeFromNib() {
        super.awakeFromNib()
        
        if NibLoaded == false {
            NibLoaded = true
            
            // Do any additional setup after loading the view.
            populateProvisioningProfiles()
            populateCodesigningCerts()
            if let defaultCert = defaults.string(forKey: "signingCertificate") {
                if AppSigner.sharedInstance.codesigningCerts.contains(defaultCert) {
                    Log.write("Loaded Codesigning Certificate from Defaults: \(defaultCert)")
                    CodesigningCertsPopup.selectItem(withTitle: defaultCert)
                }
            }
            AppSigner.setStatus("Ready")
            if AppSigner.checkXcodeCLI() == false {
                if #available(OSX 10.10, *) {
                    let _ = AppSigner.installXcodeCLI()
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Please install the Xcode command line tools and re-launch this application."
                    alert.runModal()
                }
                
                NSApplication.shared().terminate(self)
            }
            UpdatesController.checkForUpdate()
        }
    }
    
    func refreshStatus() {
        StatusLabel.stringValue = AppSigner.sharedInstance.status
    }
    
    func populateProvisioningProfiles(){
        let zeroWidthSpace = "​"
        AppSigner.sharedInstance.provisioningProfiles = ProvisioningProfile.getProfiles().sorted {
            ($0.name == $1.name && $0.created.timeIntervalSince1970 > $1.created.timeIntervalSince1970) || $0.name < $1.name
        }
        AppSigner.setStatus("Found \(AppSigner.sharedInstance.provisioningProfiles.count) Provisioning Profile\(AppSigner.sharedInstance.provisioningProfiles.count>1 || AppSigner.sharedInstance.provisioningProfiles.count<1 ? "s":"")")
        ProvisioningProfilesPopup.removeAllItems()
        ProvisioningProfilesPopup.addItems(withTitles: [
            "Re-Sign Only",
            "Choose Custom File",
            "––––––––––––––––––––––"
        ])
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        var newProfiles: [ProvisioningProfile] = []
        var zeroWidthPadding: String = ""
        for profile in AppSigner.sharedInstance.provisioningProfiles {
            zeroWidthPadding = "\(zeroWidthPadding)\(zeroWidthSpace)"
            if profile.expires.timeIntervalSince1970 > Date().timeIntervalSince1970 {
                newProfiles.append(profile)
                
                ProvisioningProfilesPopup.addItem(withTitle: "\(profile.name)\(zeroWidthPadding) (\(profile.teamID))")
                
                let toolTipItems = [
                    "\(profile.name)",
                    "",
                    "Team ID: \(profile.teamID)",
                    "Created: \(formatter.string(from: profile.created as Date))",
                    "Expires: \(formatter.string(from: profile.expires as Date))"
                ]
                ProvisioningProfilesPopup.lastItem!.toolTip = toolTipItems.joined(separator: "\n")
                AppSigner.setStatus("Added profile \(profile.appID), expires (\(formatter.string(from: profile.expires as Date)))")
            } else {
                AppSigner.setStatus("Skipped profile \(profile.appID), expired (\(formatter.string(from: profile.expires as Date)))")
            }
        }
        AppSigner.sharedInstance.provisioningProfiles = newProfiles
        chooseProvisioningProfile(ProvisioningProfilesPopup)
    }
    
    func showCodesignCertsErrorAlert(){
        let alert = NSAlert()
        alert.messageText = "No codesigning certificates found"
        alert.informativeText = "I can attempt to fix this automatically, would you like me to try?"
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        if alert.runModal() == NSAlertFirstButtonReturn {
            if let tempFolder = AppSigner.makeTempFolder() {
                iASShared.fixSigning(tempFolder)
                try? fileManager.removeItem(atPath: tempFolder)
                populateCodesigningCerts()
            }
        }
    }
    
    func populateCodesigningCerts() {
        CodesigningCertsPopup.removeAllItems()
        AppSigner.sharedInstance.codesigningCerts = AppSigner.getCodesigningCerts()
        
        AppSigner.setStatus("Found \(AppSigner.sharedInstance.codesigningCerts.count) Codesigning Certificate\(AppSigner.sharedInstance.codesigningCerts.count>1 || AppSigner.sharedInstance.codesigningCerts.count<1 ? "s":"")")
        if AppSigner.sharedInstance.codesigningCerts.count > 0 {
            for cert in AppSigner.sharedInstance.codesigningCerts {
                CodesigningCertsPopup.addItem(withTitle: cert)
                AppSigner.setStatus("Added signing certificate \"\(cert)\"")
            }
        } else {
            showCodesignCertsErrorAlert()
        }
        
    }
    
    func checkProfileID(_ profile: ProvisioningProfile?){
        if let profile = profile {
            AppSigner.sharedInstance.profileFilename = profile.filename
            AppSigner.setStatus("Selected provisioning profile \(profile.appID)")
            if profile.expires.timeIntervalSince1970 < Date().timeIntervalSince1970 {
                ProvisioningProfilesPopup.selectItem(at: 0)
                AppSigner.setStatus("Provisioning profile expired")
                chooseProvisioningProfile(ProvisioningProfilesPopup)
            }
            if profile.appID.characters.index(of: "*") == nil {
                // Not a wildcard profile
                NewApplicationIDTextField.stringValue = profile.appID
                NewApplicationIDTextField.isEnabled = false
            } else {
                // Wildcard profile
                if NewApplicationIDTextField.isEnabled == false {
                    NewApplicationIDTextField.stringValue = ""
                    NewApplicationIDTextField.isEnabled = true
                }
            }
        } else {
            ProvisioningProfilesPopup.selectItem(at: 0)
            AppSigner.setStatus("Invalid provisioning profile")
            chooseProvisioningProfile(ProvisioningProfilesPopup)
        }
    }
    
    func controlsEnabled(_ enabled: Bool){
        
        if (!Thread.isMainThread){
            DispatchQueue.main.sync{
                controlsEnabled(enabled)
            }
        }
        else{
            if(enabled){
                InputFileText.isEnabled = true
                BrowseButton.isEnabled = true
                ProvisioningProfilesPopup.isEnabled = true
                CodesigningCertsPopup.isEnabled = true
                NewApplicationIDTextField.isEnabled = AppSigner.sharedInstance.ReEnableNewApplicationID
                NewApplicationIDTextField.stringValue = AppSigner.sharedInstance.PreviousNewApplicationID
                StartButton.isEnabled = true
                appDisplayName.isEnabled = true
            } else {
                // Backup previous values
                AppSigner.sharedInstance.PreviousNewApplicationID = NewApplicationIDTextField.stringValue
                AppSigner.sharedInstance.ReEnableNewApplicationID = NewApplicationIDTextField.isEnabled
                
                InputFileText.isEnabled = false
                BrowseButton.isEnabled = false
                ProvisioningProfilesPopup.isEnabled = false
                CodesigningCertsPopup.isEnabled = false
                NewApplicationIDTextField.isEnabled = false
                StartButton.isEnabled = false
                appDisplayName.isEnabled = false
            }
        }
    }
    
    func cleanup() {
        controlsEnabled(true)
    }
    
    func bytesToSmallestSi(_ size: Double) -> String {
        let prefixes = ["","K","M","G","T","P","E","Z","Y"]
        for i in 1...6 {
            let nextUnit = pow(1024.00, Double(i+1))
            let unitMax = pow(1024.00, Double(i))
            if size < nextUnit {
                return "\(round((size / unitMax)*100)/100)\(prefixes[i])B"
            }
            
        }
        return "\(size)B"
    }
    
    //MARK: NSURL Delegate
    var downloading = false
    var downloadError: NSError?
    var downloadPath: String!
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        downloadError = downloadTask.error as NSError?
        if downloadError == nil {
            do {
                try fileManager.moveItem(at: location, to: URL(fileURLWithPath: downloadPath))
            } catch let error as NSError {
                AppSigner.setStatus("Unable to move downloaded file")
                Log.write(error.localizedDescription)
            }
        }
        downloading = false
        downloadProgress.doubleValue = 0.0
        downloadProgress.stopAnimation(nil)
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        
        //StatusLabel.stringValue = "Downloading file: \(bytesToSmallestSi(Double(totalBytesWritten))) / \(bytesToSmallestSi(Double(totalBytesExpectedToWrite)))"
        let percentDownloaded = (Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) * 100
        downloadProgress.doubleValue = percentDownloaded
    }
    
    func startSigning() {
        controlsEnabled(false)
        
        //MARK: Get output filename
        let saveDialog = NSSavePanel()
        saveDialog.allowedFileTypes = ["ipa"]
        saveDialog.nameFieldStringValue = InputFileText.stringValue.lastPathComponent.stringByDeletingPathExtension
        if saveDialog.runModal() == NSFileHandlingPanelOKButton {
            AppSigner.sharedInstance.outputFile = saveDialog.url!.path
            Thread.detachNewThreadSelector(#selector(self.signingThread), toTarget: self, with: nil)
        } else {
            AppSigner.sharedInstance.outputFile = nil
            controlsEnabled(true)
        }
    }
    
    func signingThread(){
        DispatchQueue.main.sync {
            AppSigner.sharedInstance.inputFile = self.InputFileText.stringValue
            AppSigner.sharedInstance.signingCertificate = self.CodesigningCertsPopup.selectedItem?.title
            AppSigner.sharedInstance.newApplicationID = self.NewApplicationIDTextField.stringValue.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            AppSigner.sharedInstance.newDisplayName = self.appDisplayName.stringValue.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            AppSigner.sharedInstance.newShortVersion = self.appShortVersion.stringValue.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            AppSigner.sharedInstance.newVersion = self.appVersion.stringValue.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        }

        let inputStartsWithHTTP = AppSigner.sharedInstance.inputFile.lowercased().substring(to: AppSigner.sharedInstance.inputFile.characters.index(AppSigner.sharedInstance.inputFile.startIndex, offsetBy: 4)) == "http"
        
        var continueSigning: Bool? = nil
        
        //MARK: Sanity checks
        
        // Check signing certificate selection
        if AppSigner.sharedInstance.signingCertificate == nil {
            AppSigner.setStatus("No signing certificate selected")
            return
        }
        
        // Check if input file exists
        var inputIsDirectory: ObjCBool = false
        if !inputStartsWithHTTP && !fileManager.fileExists(atPath: AppSigner.sharedInstance.inputFile, isDirectory: &inputIsDirectory){
            DispatchQueue.main.async(execute: {
                let alert = NSAlert()
                alert.messageText = "Input file not found"
                alert.addButton(withTitle: "OK")
                alert.informativeText = "The file \(AppSigner.sharedInstance.inputFile) could not be found"
                alert.runModal()
                self.controlsEnabled(true)
            })
            return
        }
        
        //MARK: Create working temp folder
        var tempFolder: String! = nil
        if let tmpFolder = AppSigner.makeTempFolder() {
            tempFolder = tmpFolder
        } else {
            AppSigner.setStatus("Error creating temp folder")
            return
        }
        Log.write("Temp folder: \(tempFolder)")
        
        //MARK: Codesign Test
        
        DispatchQueue.main.async(execute: {
            if let codesignResult = AppSigner.testSigning(AppSigner.sharedInstance.signingCertificate!, tempFolder: tempFolder) {
                if codesignResult == false {
                    let alert = NSAlert()
                    alert.messageText = "Codesigning error"
                    alert.addButton(withTitle: "Yes")
                    alert.addButton(withTitle: "No")
                    alert.informativeText = "You appear to have a error with your codesigning certificate, do you want me to try and fix the problem?"
                    let response = alert.runModal()
                    if response == NSAlertFirstButtonReturn {
                        iASShared.fixSigning(tempFolder)
                        if AppSigner.testSigning(AppSigner.sharedInstance.signingCertificate!, tempFolder: tempFolder) == false {
                            let errorAlert = NSAlert()
                            errorAlert.messageText = "Unable to Fix"
                            errorAlert.addButton(withTitle: "OK")
                            errorAlert.informativeText = "I was unable to automatically resolve your codesigning issue ☹\n\nIf you have previously trusted your certificate using Keychain, please set the Trust setting back to the system default."
                            errorAlert.runModal()
                            continueSigning = false
                            return
                        }
                    } else {
                        continueSigning = false
                        return
                    }
                }
            }
            continueSigning = true
        })
        
        
        while true {
            if continueSigning != nil {
                if continueSigning! == false {
                    continueSigning = nil
                    AppSigner.cleanup(tempFolder); return
                }
                break
            }
            usleep(100)
        }
        
        AppSigner.createEggTempDir()
        
        //MARK: Download file
        downloading = false
        downloadError = nil
        downloadPath = tempFolder.stringByAppendingPathComponent("download.\(AppSigner.sharedInstance.inputFile.pathExtension)")
        
        if inputStartsWithHTTP {
            let defaultConfigObject = URLSessionConfiguration.default
            let defaultSession = Foundation.URLSession(configuration: defaultConfigObject, delegate: self, delegateQueue: OperationQueue.main)
            if let url = URL(string: AppSigner.sharedInstance.inputFile) {
                downloading = true
                
                let downloadTask = defaultSession.downloadTask(with: url)
                AppSigner.setStatus("Downloading file")
                downloadProgress.startAnimation(nil)
                downloadTask.resume()
                defaultSession.finishTasksAndInvalidate()
            }
            
            while downloading {
                usleep(100000)
            }
            if downloadError != nil {
                AppSigner.setStatus("Error downloading file, \(downloadError!.localizedDescription.lowercased())")
                AppSigner.cleanup(tempFolder); return
            } else {
                AppSigner.sharedInstance.inputFile = downloadPath
            }
        }
        
        AppSigner.processInputFile()
        AppSigner.codesign()
    }

    
    //MARK: IBActions
    @IBAction func chooseProvisioningProfile(_ sender: NSPopUpButton) {
        
        switch(sender.indexOfSelectedItem){
        case 0:
            AppSigner.sharedInstance.profileFilename = nil
            if NewApplicationIDTextField.isEnabled == false {
                NewApplicationIDTextField.isEnabled = true
                NewApplicationIDTextField.stringValue = ""
            }
            break
            
        case 1:
            let openDialog = NSOpenPanel()
            openDialog.canChooseFiles = true
            openDialog.canChooseDirectories = false
            openDialog.allowsMultipleSelection = false
            openDialog.allowsOtherFileTypes = false
            openDialog.allowedFileTypes = ["mobileprovision"]
            openDialog.runModal()
            if let filename = openDialog.urls.first {
                checkProfileID(ProvisioningProfile(filename: filename.path))
            } else {
                sender.selectItem(at: 0)
                chooseProvisioningProfile(sender)
            }
            break
            
        case 2:
            sender.selectItem(at: 0)
            chooseProvisioningProfile(sender)
            break
            
        default:
            let profile = AppSigner.sharedInstance.provisioningProfiles[sender.indexOfSelectedItem - 3]
            checkProfileID(profile)
            break
        }
        
    }
    @IBAction func doBrowse(_ sender: AnyObject) {
        let openDialog = NSOpenPanel()
        openDialog.canChooseFiles = true
        openDialog.canChooseDirectories = false
        openDialog.allowsMultipleSelection = false
        openDialog.allowsOtherFileTypes = false
        openDialog.allowedFileTypes = ["ipa","IPA","deb","DEB","app","APP","xcarchive","XCARCHIVE"]
        openDialog.runModal()
        if let filename = openDialog.urls.first {
            InputFileText.stringValue = filename.path
        }
    }
    @IBAction func chooseSigningCertificate(_ sender: NSPopUpButton) {
        Log.write("Set Codesigning Certificate Default to: \(sender.stringValue)")
        defaults.setValue(sender.selectedItem?.title, forKey: "signingCertificate")
    }
    
    @IBAction func doSign(_ sender: NSButton) {
        switch(true){
            case (AppSigner.sharedInstance.codesigningCerts.count == 0):
                showCodesignCertsErrorAlert()
                break
            
            default:
                NSApplication.shared().windows[0].makeFirstResponder(self)
                startSigning()
        }
    }
    
    @IBAction func statusLabelClick(_ sender: NSButton) {
        if let outputFile = AppSigner.sharedInstance.outputFile {
            if fileManager.fileExists(atPath: outputFile) {
                NSWorkspace.shared().activateFileViewerSelecting([URL(fileURLWithPath: outputFile)])
            }
        }
    }
    
}

