//
//  AppSigner.swift
//  iOS App Signer
//
//  Created by huangyimin on 2019/2/12.
//  Copyright © 2019 Daniel Radtke. All rights reserved.
//

import Foundation

class AppSigner: NSObject {
    //MARK: Variables
    var provisioningProfiles:[ProvisioningProfile] = []
    var codesigningCerts: [String] = []
    var profileFilename: String?
    var ReEnableNewApplicationID = false
    var PreviousNewApplicationID = ""
    var outputFile: String?
    var status = ""
    var tempFolder: String!
    var workingDirectory: String = ""
    var eggDirectory: String = ""
    var payloadDirectory: String = ""
    var entitlementsPlist: String = ""
    
    var inputFile : String = "" {
        didSet {
            AppSigner.sharedInstance.fileManager.fileExists(atPath: AppSigner.sharedInstance.inputFile, isDirectory: &AppSigner.sharedInstance.inputIsDirectory)
        }
    }
    var signingCertificate : String?
    var newApplicationID : String = ""
    var newDisplayName : String = ""
    var newShortVersion : String = ""
    var newVersion : String = ""
    var inputIsDirectory: ObjCBool = false
    
    //MARK: Constants
    let arPath = "/usr/bin/ar"
    let mktempPath = "/usr/bin/mktemp"
    let tarPath = "/usr/bin/tar"
    let unzipPath = "/usr/bin/unzip"
    let zipPath = "/usr/bin/zip"
    let defaultsPath = "/usr/bin/defaults"
    let codesignPath = "/usr/bin/codesign"
    let securityPath = "/usr/bin/security"
    let chmodPath = "/bin/chmod"
    let fileManager = FileManager.default
    let bundleID = Bundle.main.bundleIdentifier
    let refreshStatusNotification = "refreshStatusNotification"
    let cleanupNotification = "cleanupNotification"
    
    static let sharedInstance = AppSigner()
    
    override init() {
        super.init()
    }
    
    static func installXcodeCLI() -> AppSignerTaskOutput {
        return Process().execute("/usr/bin/xcode-select", workingDirectory: nil, arguments: ["--install"])
    }
    
    static func checkXcodeCLI() -> Bool {
        if #available(OSX 10.10, *) {
            if Process().execute("/usr/bin/xcode-select", workingDirectory: nil, arguments: ["-p"]).status   != 0 {
                return false
            }
        } else {
            if Process().execute("/usr/sbin/pkgutil", workingDirectory: nil, arguments: ["--pkg-info=com.apple.pkg.DeveloperToolsCLI"]).status != 0 {
                // Command line tools not available
                return false
            }
        }
        
        return true
    }
    
    static func setStatus(_ status: String){
        Log.write(status)
        if (!Thread.isMainThread){
            DispatchQueue.main.sync{
                setStatus(status)
            }
        }
        else{
            sharedInstance.status = status
            NotificationCenter.default.post(name: NSNotification.Name(sharedInstance.refreshStatusNotification), object: nil)
        }
    }
    
    static func makeTempFolder()->String?{
        let tempTask = Process().execute(sharedInstance.mktempPath, workingDirectory: nil, arguments: ["-d","-t",sharedInstance.bundleID!])
        if tempTask.status != 0 {
            return nil
        }
        sharedInstance.tempFolder = tempTask.output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        sharedInstance.workingDirectory = sharedInstance.tempFolder.stringByAppendingPathComponent("out")
        sharedInstance.eggDirectory = sharedInstance.tempFolder.stringByAppendingPathComponent("eggs")
        sharedInstance.payloadDirectory = sharedInstance.workingDirectory.stringByAppendingPathComponent("Payload/")
        sharedInstance.entitlementsPlist = sharedInstance.tempFolder.stringByAppendingPathComponent("entitlements.plist")
        
        return sharedInstance.tempFolder
    }
    
    static func cleanup(_ tempFolder: String){
        do {
            Log.write("Deleting: \(tempFolder)")
            try sharedInstance.fileManager.removeItem(atPath: tempFolder)
        } catch let error as NSError {
            AppSigner.setStatus("Unable to delete temp folder")
            Log.write(error.localizedDescription)
        }
        NotificationCenter.default.post(name: NSNotification.Name(sharedInstance.cleanupNotification), object: nil)
    }
    
    static func getCodesigningCerts() -> [String] {
        var output: [String] = []
        let securityResult = Process().execute(sharedInstance.securityPath, workingDirectory: nil, arguments: ["find-identity","-v","-p","codesigning"])
        if securityResult.output.characters.count < 1 {
            return output
        }
        let rawResult = securityResult.output.components(separatedBy: "\"")
        
        var index: Int
        
        for index in stride(from: 0, through: rawResult.count - 2, by: 2) {
            if !(rawResult.count - 1 < index + 1) {
                output.append(rawResult[index+1])
            }
        }
        return output
    }
    
    static func recursiveDirectorySearch(_ path: String, extensions: [String], found: ((_ file: String) -> Void)){
        
        if let files = try? sharedInstance.fileManager.contentsOfDirectory(atPath: path) {
            var isDirectory: ObjCBool = true
            
            for file in files {
                let currentFile = path.stringByAppendingPathComponent(file)
                sharedInstance.fileManager.fileExists(atPath: currentFile, isDirectory: &isDirectory)
                if isDirectory.boolValue {
                    recursiveDirectorySearch(currentFile, extensions: extensions, found: found)
                }
                if extensions.contains(file.pathExtension) {
                    found(currentFile)
                }
                
            }
        }
    }
    
    static func unzip(_ inputFile: String, outputPath: String)->AppSignerTaskOutput {
        return Process().execute(sharedInstance.unzipPath, workingDirectory: nil, arguments: ["-q",inputFile,"-d",outputPath])
    }
    
    static func zip(_ inputPath: String, outputFile: String)->AppSignerTaskOutput {
        return Process().execute(sharedInstance.zipPath, workingDirectory: inputPath, arguments: ["-qry", outputFile, "."])
    }
    
    static func getPlistKey(_ plist: String, keyName: String)->String? {
        let currTask = Process().execute(sharedInstance.defaultsPath, workingDirectory: nil, arguments: ["read", plist, keyName])
        if currTask.status == 0 {
            return String(currTask.output.characters.dropLast())
        } else {
            return nil
        }
    }
    
    static func setPlistKey(_ plist: String, keyName: String, value: String)->AppSignerTaskOutput {
        return Process().execute(sharedInstance.defaultsPath, workingDirectory: nil, arguments: ["write", plist, keyName, value])
    }
    
    //MARK: Codesigning
    static func codeSign(_ file: String, certificate: String, entitlements: String?,before:((_ file: String, _ certificate: String, _ entitlements: String?)->Void)?, after: ((_ file: String, _ certificate: String, _ entitlements: String?, _ codesignTask: AppSignerTaskOutput)->Void)?)->AppSignerTaskOutput{
        
        let useEntitlements: Bool = ({
            if entitlements == nil {
                return false
            } else {
                if sharedInstance.fileManager.fileExists(atPath: entitlements!) {
                    return true
                } else {
                    return false
                }
            }
        })()
        
        if let beforeFunc = before {
            beforeFunc(file, certificate, entitlements)
        }
        var arguments = ["-vvv","-fs",certificate,"--no-strict"]
        if useEntitlements {
            arguments.append("--entitlements=\(entitlements!)")
        }
        arguments.append(file)
        let codesignTask = Process().execute(sharedInstance.codesignPath, workingDirectory: nil, arguments: arguments)
        if let afterFunc = after {
            afterFunc(file, certificate, entitlements, codesignTask)
        }
        return codesignTask
    }
    
    static func testSigning(_ certificate: String, tempFolder: String )->Bool? {
        let codesignTempFile = tempFolder.stringByAppendingPathComponent("test-sign")
        
        // Copy our binary to the temp folder to use for testing.
        let path = ProcessInfo.processInfo.arguments[0]
        if (try? sharedInstance.fileManager.copyItem(atPath: path, toPath: codesignTempFile)) != nil {
            codeSign(codesignTempFile, certificate: certificate, entitlements: nil, before: nil, after: nil)
            
            let verificationTask = Process().execute(sharedInstance.codesignPath, workingDirectory: nil, arguments: ["-v",codesignTempFile])
            try? sharedInstance.fileManager.removeItem(atPath: codesignTempFile)
            if verificationTask.status == 0 {
                return true
            } else {
                return false
            }
        } else {
            setStatus("Error testing codesign")
        }
        return nil
    }
    
    static func createEggTempDir() {
        //MARK: Create Egg Temp Directory
        do {
            try sharedInstance.fileManager.createDirectory(atPath: sharedInstance.eggDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch let error as NSError {
            AppSigner.setStatus("Error creating egg temp directory")
            Log.write(error.localizedDescription)
            AppSigner.cleanup(sharedInstance.tempFolder); return
        }
    }
    
    static func processInputFile() {
        //MARK: Process input file
        switch(sharedInstance.inputFile.pathExtension.lowercased()){
        case "deb":
            //MARK: --Unpack deb
            let debPath = sharedInstance.tempFolder.stringByAppendingPathComponent("deb")
            do {
                
                try sharedInstance.fileManager.createDirectory(atPath: debPath, withIntermediateDirectories: true, attributes: nil)
                try sharedInstance.fileManager.createDirectory(atPath: sharedInstance.workingDirectory, withIntermediateDirectories: true, attributes: nil)
                AppSigner.setStatus("Extracting deb file")
                let debTask = Process().execute(sharedInstance.arPath, workingDirectory: debPath, arguments: ["-x", sharedInstance.inputFile])
                Log.write(debTask.output)
                if debTask.status != 0 {
                    AppSigner.setStatus("Error processing deb file")
                    AppSigner.cleanup(sharedInstance.tempFolder); return
                }
                
                var tarUnpacked = false
                for tarFormat in ["tar","tar.gz","tar.bz2","tar.lzma","tar.xz"]{
                    let dataPath = debPath.stringByAppendingPathComponent("data.\(tarFormat)")
                    if sharedInstance.fileManager.fileExists(atPath: dataPath){
                        
                        AppSigner.setStatus("Unpacking data.\(tarFormat)")
                        let tarTask = Process().execute(
                            sharedInstance.tarPath, workingDirectory: debPath, arguments: ["-xf",dataPath])
                        Log.write(tarTask.output)
                        if tarTask.status == 0 {
                            tarUnpacked = true
                        }
                        break
                    }
                }
                if !tarUnpacked {
                    AppSigner.setStatus("Error unpacking data.tar")
                    AppSigner.cleanup(sharedInstance.tempFolder); return
                }
                
                var sourcePath = debPath.stringByAppendingPathComponent("Applications")
                if sharedInstance.fileManager.fileExists(atPath: debPath.stringByAppendingPathComponent("var/mobile/Applications")){
                    sourcePath = debPath.stringByAppendingPathComponent("var/mobile/Applications")
                }
                
                try sharedInstance.fileManager.moveItem(atPath: sourcePath, toPath: sharedInstance.payloadDirectory)
                
            } catch {
                AppSigner.setStatus("Error processing deb file")
                AppSigner.cleanup(sharedInstance.tempFolder); return
            }
            break
            
        case "ipa":
            //MARK: --Unzip ipa
            do {
                try sharedInstance.fileManager.createDirectory(atPath: sharedInstance.workingDirectory, withIntermediateDirectories: true, attributes: nil)
                AppSigner.setStatus("Extracting ipa file")
                
                let unzipTask = AppSigner.unzip(sharedInstance.inputFile, outputPath: sharedInstance.workingDirectory)
                if unzipTask.status != 0 {
                    AppSigner.setStatus("Error extracting ipa file")
                    AppSigner.cleanup(sharedInstance.tempFolder); return
                }
            } catch {
                AppSigner.setStatus("Error extracting ipa file")
                AppSigner.cleanup(sharedInstance.tempFolder); return
            }
            break
            
        case "app":
            //MARK: --Copy app bundle
            if !sharedInstance.inputIsDirectory.boolValue {
                AppSigner.setStatus("Unsupported input file")
                AppSigner.cleanup(sharedInstance.tempFolder); return
            }
            do {
                try sharedInstance.fileManager.createDirectory(atPath: sharedInstance.payloadDirectory, withIntermediateDirectories: true, attributes: nil)
                AppSigner.setStatus("Copying app to payload directory")
                try sharedInstance.fileManager.copyItem(atPath: sharedInstance.inputFile, toPath: sharedInstance.payloadDirectory.stringByAppendingPathComponent(sharedInstance.inputFile.lastPathComponent))
            } catch {
                AppSigner.setStatus("Error copying app to payload directory")
                AppSigner.cleanup(sharedInstance.tempFolder); return
            }
            break
            
        case "xcarchive":
            //MARK: --Copy app bundle from xcarchive
            if !sharedInstance.inputIsDirectory.boolValue {
                AppSigner.setStatus("Unsupported input file")
                AppSigner.cleanup(sharedInstance.tempFolder); return
            }
            do {
                try sharedInstance.fileManager.createDirectory(atPath: sharedInstance.workingDirectory, withIntermediateDirectories: true, attributes: nil)
                AppSigner.setStatus("Copying app to payload directory")
                try sharedInstance.fileManager.copyItem(atPath: sharedInstance.inputFile.stringByAppendingPathComponent("Products/Applications/"), toPath: sharedInstance.payloadDirectory)
            } catch {
                AppSigner.setStatus("Error copying app to payload directory")
                AppSigner.cleanup(sharedInstance.tempFolder); return
            }
            break
            
        default:
            AppSigner.setStatus("Unsupported input file")
            AppSigner.cleanup(sharedInstance.tempFolder); return
        }
        
        if !sharedInstance.fileManager.fileExists(atPath: sharedInstance.payloadDirectory){
            AppSigner.setStatus("Payload directory doesn't exist")
            AppSigner.cleanup(sharedInstance.tempFolder); return
        }
        
    }
    
    static func codesign() {
        var provisioningFile = AppSigner.sharedInstance.profileFilename
        var warnings = 0
        var eggCount: Int = 0
        
        // Loop through app bundles in payload directory
        do {
            let files = try sharedInstance.fileManager.contentsOfDirectory(atPath: sharedInstance.payloadDirectory)
            var isDirectory: ObjCBool = true
            
            for file in files {
                
                sharedInstance.fileManager.fileExists(atPath: sharedInstance.payloadDirectory.stringByAppendingPathComponent(file), isDirectory: &isDirectory)
                if !isDirectory.boolValue { continue }
                
                //MARK: Bundle variables setup
                let appBundlePath = sharedInstance.payloadDirectory.stringByAppendingPathComponent(file)
                let appBundleInfoPlist = appBundlePath.stringByAppendingPathComponent("Info.plist")
                let appBundleProvisioningFilePath = appBundlePath.stringByAppendingPathComponent("embedded.mobileprovision")
                let useAppBundleProfile = (provisioningFile == nil && sharedInstance.fileManager.fileExists(atPath: appBundleProvisioningFilePath))
                
                //MARK: Delete CFBundleResourceSpecification from Info.plist
                Log.write(Process().execute(AppSigner.sharedInstance.defaultsPath, workingDirectory: nil, arguments: ["delete",appBundleInfoPlist,"CFBundleResourceSpecification"]).output)
                
                //MARK: Copy Provisioning Profile
                if provisioningFile != nil {
                    if sharedInstance.fileManager.fileExists(atPath: appBundleProvisioningFilePath) {
                        AppSigner.setStatus("Deleting embedded.mobileprovision")
                        do {
                            try sharedInstance.fileManager.removeItem(atPath: appBundleProvisioningFilePath)
                        } catch let error as NSError {
                            AppSigner.setStatus("Error deleting embedded.mobileprovision")
                            Log.write(error.localizedDescription)
                            AppSigner.cleanup(sharedInstance.tempFolder); return
                        }
                    }
                    AppSigner.setStatus("Copying provisioning profile to app bundle")
                    do {
                        try sharedInstance.fileManager.copyItem(atPath: provisioningFile!, toPath: appBundleProvisioningFilePath)
                    } catch let error as NSError {
                        AppSigner.setStatus("Error copying provisioning profile")
                        Log.write(error.localizedDescription)
                        AppSigner.cleanup(sharedInstance.tempFolder); return
                    }
                }
                
                //MARK: Generate entitlements.plist
                if provisioningFile != nil || useAppBundleProfile {
                    AppSigner.setStatus("Parsing entitlements")
                    
                    if let profile = ProvisioningProfile(filename: useAppBundleProfile ? appBundleProvisioningFilePath : provisioningFile!){
                        if let entitlements = profile.getEntitlementsPlist(sharedInstance.tempFolder) {
                            Log.write("–––––––––––––––––––––––\n\(entitlements)")
                            Log.write("–––––––––––––––––––––––")
                            do {
                                try entitlements.write(toFile: sharedInstance.entitlementsPlist, atomically: false, encoding: String.Encoding.utf8.rawValue)
                                AppSigner.setStatus("Saved entitlements to \(sharedInstance.entitlementsPlist)")
                            } catch let error as NSError {
                                AppSigner.setStatus("Error writing entitlements.plist, \(error.localizedDescription)")
                            }
                        } else {
                            AppSigner.setStatus("Unable to read entitlements from provisioning profile")
                            warnings += 1
                        }
                        if profile.appID != "*" && (AppSigner.sharedInstance.newApplicationID != "" && AppSigner.sharedInstance.newApplicationID != profile.appID) {
                            AppSigner.setStatus("Unable to change App ID to \(AppSigner.sharedInstance.newApplicationID), provisioning profile won't allow it")
                            AppSigner.cleanup(sharedInstance.tempFolder); return
                        }
                    } else {
                        AppSigner.setStatus("Unable to parse provisioning profile, it may be corrupt")
                        warnings += 1
                    }
                    
                }
                
                //MARK: Make sure that the executable is well... executable.
                if let bundleExecutable = AppSigner.getPlistKey(appBundleInfoPlist, keyName: "CFBundleExecutable"){
                    Process().execute(AppSigner.sharedInstance.chmodPath, workingDirectory: nil, arguments: ["755", appBundlePath.stringByAppendingPathComponent(bundleExecutable)])
                }
                
                //MARK: Change Application ID
                if AppSigner.sharedInstance.newApplicationID != "" {
                    
                    if let oldAppID = AppSigner.getPlistKey(appBundleInfoPlist, keyName: "CFBundleIdentifier") {
                        func changeAppexID(_ appexFile: String){
                            let appexPlist = appexFile.stringByAppendingPathComponent("Info.plist")
                            if let appexBundleID = AppSigner.getPlistKey(appexPlist, keyName: "CFBundleIdentifier"){
                                let newAppexID = "\(AppSigner.sharedInstance.newApplicationID)\(appexBundleID.substring(from: oldAppID.endIndex))"
                                AppSigner.setStatus("Changing \(appexFile) id to \(newAppexID)")
                                AppSigner.setPlistKey(appexPlist, keyName: "CFBundleIdentifier", value: newAppexID)
                            }
                            if Process().execute(AppSigner.sharedInstance.defaultsPath, workingDirectory: nil, arguments: ["read", appexPlist,"WKCompanionAppBundleIdentifier"]).status == 0 {
                                AppSigner.setPlistKey(appexPlist, keyName: "WKCompanionAppBundleIdentifier", value: AppSigner.sharedInstance.newApplicationID)
                            }
                            AppSigner.recursiveDirectorySearch(appexFile, extensions: ["app"], found: changeAppexID)
                        }
                        AppSigner.recursiveDirectorySearch(appBundlePath, extensions: ["appex"], found: changeAppexID)
                    }
                    
                    AppSigner.setStatus("Changing App ID to \(AppSigner.sharedInstance.newApplicationID)")
                    let IDChangeTask = AppSigner.setPlistKey(appBundleInfoPlist, keyName: "CFBundleIdentifier", value: AppSigner.sharedInstance.newApplicationID)
                    if IDChangeTask.status != 0 {
                        AppSigner.setStatus("Error changing App ID")
                        Log.write(IDChangeTask.output)
                        AppSigner.cleanup(sharedInstance.tempFolder); return
                    }
                    
                    
                }
                
                //MARK: Change Display Name
                if AppSigner.sharedInstance.newDisplayName != "" {
                    AppSigner.setStatus("Changing Display Name to \(AppSigner.sharedInstance.newDisplayName))")
                    let displayNameChangeTask = Process().execute(AppSigner.sharedInstance.defaultsPath, workingDirectory: nil, arguments: ["write",appBundleInfoPlist,"CFBundleDisplayName", AppSigner.sharedInstance.newDisplayName])
                    if displayNameChangeTask.status != 0 {
                        AppSigner.setStatus("Error changing display name")
                        Log.write(displayNameChangeTask.output)
                        AppSigner.cleanup(sharedInstance.tempFolder); return
                    }
                }
                
                //MARK: Change Version
                if AppSigner.sharedInstance.newVersion != "" {
                    AppSigner.setStatus("Changing Version to \(AppSigner.sharedInstance.newVersion)")
                    let versionChangeTask = Process().execute(AppSigner.sharedInstance.defaultsPath, workingDirectory: nil, arguments: ["write",appBundleInfoPlist,"CFBundleVersion", AppSigner.sharedInstance.newVersion])
                    if versionChangeTask.status != 0 {
                        AppSigner.setStatus("Error changing version")
                        Log.write(versionChangeTask.output)
                        AppSigner.cleanup(sharedInstance.tempFolder); return
                    }
                }
                
                //MARK: Change Short Version
                if AppSigner.sharedInstance.newShortVersion != "" {
                    AppSigner.setStatus("Changing Short Version to \(AppSigner.sharedInstance.newShortVersion)")
                    let shortVersionChangeTask = Process().execute(AppSigner.sharedInstance.defaultsPath, workingDirectory: nil, arguments: ["write",appBundleInfoPlist,"CFBundleShortVersionString", AppSigner.sharedInstance.newShortVersion])
                    if shortVersionChangeTask.status != 0 {
                        AppSigner.setStatus("Error changing short version")
                        Log.write(shortVersionChangeTask.output)
                        AppSigner.cleanup(sharedInstance.tempFolder); return
                    }
                }
                
                
                func generateFileSignFunc(_ payloadDirectory:String, entitlementsPath: String, signingCertificate: String)->((_ file:String)->Void){
                    
                    
                    let useEntitlements: Bool = ({
                        if sharedInstance.fileManager.fileExists(atPath: entitlementsPath) {
                            return true
                        }
                        return false
                    })()
                    
                    func shortName(_ file: String, payloadDirectory: String)->String{
                        return file.substring(from: payloadDirectory.endIndex)
                    }
                    
                    func beforeFunc(_ file: String, certificate: String, entitlements: String?){
                        AppSigner.setStatus("Codesigning \(shortName(file, payloadDirectory: payloadDirectory))\(useEntitlements ? " with entitlements":"")")
                    }
                    
                    func afterFunc(_ file: String, certificate: String, entitlements: String?, codesignOutput: AppSignerTaskOutput){
                        if codesignOutput.status != 0 {
                            AppSigner.setStatus("Error codesigning \(shortName(file, payloadDirectory: payloadDirectory))")
                            Log.write(codesignOutput.output)
                            warnings += 1
                        }
                    }
                    
                    func output(_ file:String){
                        AppSigner.codeSign(file, certificate: signingCertificate, entitlements: entitlementsPath, before: beforeFunc, after: afterFunc)
                    }
                    return output
                }
                
                //MARK: Codesigning - General
                let signableExtensions = ["dylib","so","0","vis","pvr","framework","appex","app"]
                
                //MARK: Codesigning - Eggs
                let eggSigningFunction = generateFileSignFunc(sharedInstance.eggDirectory, entitlementsPath: sharedInstance.entitlementsPlist, signingCertificate: AppSigner.sharedInstance.signingCertificate!)
                func signEgg(_ eggFile: String){
                    eggCount += 1
                    
                    let currentEggPath = sharedInstance.eggDirectory.stringByAppendingPathComponent("egg\(eggCount)")
                    let shortName = eggFile.substring(from: sharedInstance.payloadDirectory.endIndex)
                    AppSigner.setStatus("Extracting \(shortName)")
                    if AppSigner.unzip(eggFile, outputPath: currentEggPath).status != 0 {
                        Log.write("Error extracting \(shortName)")
                        return
                    }
                    AppSigner.recursiveDirectorySearch(currentEggPath, extensions: ["egg"], found: signEgg)
                    AppSigner.recursiveDirectorySearch(currentEggPath, extensions: signableExtensions, found: eggSigningFunction)
                    AppSigner.setStatus("Compressing \(shortName)")
                    AppSigner.zip(currentEggPath, outputFile: eggFile)
                }
                
                AppSigner.recursiveDirectorySearch(appBundlePath, extensions: ["egg"], found: signEgg)
                
                //MARK: Codesigning - App
                let signingFunction = generateFileSignFunc(sharedInstance.payloadDirectory, entitlementsPath: sharedInstance.entitlementsPlist, signingCertificate: AppSigner.sharedInstance.signingCertificate!)
                
                
                AppSigner.recursiveDirectorySearch(appBundlePath, extensions: signableExtensions, found: signingFunction)
                signingFunction(appBundlePath)
                
                //MARK: Codesigning - Verification
                let verificationTask = Process().execute(AppSigner.sharedInstance.codesignPath, workingDirectory: nil, arguments: ["-v",appBundlePath])
                if verificationTask.status != 0 {
                    DispatchQueue.main.async(execute: {
                        let alert = NSAlert()
                        alert.addButton(withTitle: "OK")
                        alert.messageText = "Error verifying code signature!"
                        alert.informativeText = verificationTask.output
                        alert.alertStyle = .critical
                        alert.runModal()
                        AppSigner.setStatus("Error verifying code signature")
                        Log.write(verificationTask.output)
                        AppSigner.cleanup(sharedInstance.tempFolder); return
                    })
                }
            }
        } catch let error as NSError {
            AppSigner.setStatus("Error listing files in payload directory")
            Log.write(error.localizedDescription)
            AppSigner.cleanup(sharedInstance.tempFolder); return
        }
        
        //MARK: Packaging
        //Check if output already exists and delete if so
        if sharedInstance.fileManager.fileExists(atPath: AppSigner.sharedInstance.outputFile!) {
            do {
                try sharedInstance.fileManager.removeItem(atPath: AppSigner.sharedInstance.outputFile!)
            } catch let error as NSError {
                AppSigner.setStatus("Error deleting output file")
                Log.write(error.localizedDescription)
                AppSigner.cleanup(sharedInstance.tempFolder); return
            }
        }
        AppSigner.setStatus("Packaging IPA")
        let zipTask = AppSigner.zip(sharedInstance.workingDirectory, outputFile: AppSigner.sharedInstance.outputFile!)
        if zipTask.status != 0 {
            AppSigner.setStatus("Error packaging IPA")
        }
        //MARK: Cleanup
        AppSigner.cleanup(sharedInstance.tempFolder)
        AppSigner.setStatus("Done, output at \(AppSigner.sharedInstance.outputFile!)")
    }
}
