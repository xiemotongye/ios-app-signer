//
//  AppSigner.swift
//  iOS App Signer
//
//  Created by huangyimin on 2019/2/12.
//  Copyright © 2019 Daniel Radtke. All rights reserved.
//

import Foundation

class AppSigner {
    //MARK: Variables
    var provisioningProfiles:[ProvisioningProfile] = []
    var codesigningCerts: [String] = []
    var profileFilename: String?
    var ReEnableNewApplicationID = false
    var PreviousNewApplicationID = ""
    var outputFile: String?
    var status = ""
    
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
            NotificationCenter.default.post(name: NSNotification.Name(AppSigner.sharedInstance.refreshStatusNotification), object: nil)
        }
    }
    
    static func makeTempFolder()->String?{
        let tempTask = Process().execute(sharedInstance.mktempPath, workingDirectory: nil, arguments: ["-d","-t",sharedInstance.bundleID!])
        if tempTask.status != 0 {
            return nil
        }
        return tempTask.output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }
    
    static func cleanup(_ tempFolder: String){
        do {
            Log.write("Deleting: \(tempFolder)")
            try AppSigner.sharedInstance.fileManager.removeItem(atPath: tempFolder)
        } catch let error as NSError {
            AppSigner.setStatus("Unable to delete temp folder")
            Log.write(error.localizedDescription)
        }
        NotificationCenter.default.post(name: NSNotification.Name(AppSigner.sharedInstance.cleanupNotification), object: nil)
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
}
