//
//  main.swift
//  iOSAppSignerCLT
//
//  Created by huangyimin on 2019/2/11.
//  Copyright © 2019 Daniel Radtke. All rights reserved.
//

import Foundation
import Cocoa


class CommandlineParser {
    // Common options:
    static let ParamInputFile = "-i"
    static let ParamOutputFile = "-o"
    static let ParamCertificate = "-c"
    static let ParamProvisioningProfile = "-p"
    static let ParamBundleID = "-b"
    static let ParamDisplayName = "-d"
    static let ParamVersionNum = "-v"
    static let ParamShortVersionNum = "-s"
    
    // option values
    var inputFile: String = ""
    var signingCertificate: String = ""
    var profileFilename: String = ""
    var newApplicationID: String = ""
    var newDisplayName: String = ""
    var newVersion: String = ""
    var newShortVersion: String = ""
    var outputFile: String = ""
    
    private static func printUsage() {
        let usage = [
            "Usage: \(CommandLine.arguments[0]) -i ipa_file -o output_ipa_file -c certificate_name [-p provisioning_profile] [-b bundle_id] [-d display_name] [-v version_num] [-s short_version_num]",
        ]
        
        print(usage.joined(separator: "\n") + "\n")
    }
    
    init() {
        let argc = CommandLine.argc
        
        if argc < 7 {
            CommandlineParser.printUsage()
            return
        }
        
        let args = CommandLine.arguments
        var i = 1
        while i + 1 < args.count {
            let arg = args[i]
            switch arg {
            case CommandlineParser.ParamInputFile:
                inputFile = args[i + 1]
            case CommandlineParser.ParamOutputFile:
                outputFile = args[i + 1]
            case CommandlineParser.ParamCertificate:
                signingCertificate = args[i + 1]
            case CommandlineParser.ParamProvisioningProfile:
                profileFilename = args[i + 1]
            case CommandlineParser.ParamBundleID:
                newApplicationID = args[i + 1]
            case CommandlineParser.ParamDisplayName:
                newDisplayName = args[i + 1]
            case CommandlineParser.ParamVersionNum:
                newVersion = args[i + 1]
            case CommandlineParser.ParamShortVersionNum:
                newShortVersion = args[i + 1]
            default:
                CommandlineParser.printUsage()
                return
            }
            i += 2
        }
        
        if inputFile.count == 0 || outputFile.count == 0 || signingCertificate.count == 0 {
            CommandlineParser.printUsage()
        }
    }
    
    func checkParams() -> Bool {
        // check input file
        // a path which does not start with "/" means it is a relative path
        if !inputFile.hasPrefix("/") {
            inputFile = Process().currentDirectoryPath + "/" + inputFile
        }
        if !AppSigner.sharedInstance.fileManager.fileExists(atPath: inputFile) {
            print("Input file doesn't exist!")
            return false
        }
        AppSigner.sharedInstance.inputFile = inputFile
        
        
        // check output file
        var outputIsDirectory: ObjCBool = false
        if !outputFile.hasSuffix(".ipa") {
            print("Output file's name must end with \".ipa\".")
            return false
        }
        // a path which does not start with "/" means it is a relative path
        if !outputFile.hasPrefix("/") {
            outputFile = Process().currentDirectoryPath + "/" + outputFile
        }
        if AppSigner.sharedInstance.fileManager.fileExists(atPath: outputFile.stringByDeletingLastPathComponent, isDirectory:&outputIsDirectory) {
            if outputIsDirectory.boolValue {
                AppSigner.sharedInstance.outputFile = outputFile
            } else {
                print("Output file's path is not correct.")
                return false
            }
        } else {
            print("Output file's path is not correct.")
            return false
        }
        
        
        // check certificates
        AppSigner.sharedInstance.codesigningCerts = AppSigner.getCodesigningCerts()
        if !AppSigner.sharedInstance.codesigningCerts.contains(signingCertificate) {
            print("The code signing certificates doesn't exist. Please run \"security find-identity -v -p codesigning\" to find the currect certificates.")
        }
        AppSigner.sharedInstance.signingCertificate = signingCertificate
        
        
        if newApplicationID.count > 0 {
            AppSigner.sharedInstance.newApplicationID = newApplicationID
        }
        if newDisplayName.count > 0 {
            AppSigner.sharedInstance.newDisplayName = newDisplayName
        }
        if newVersion.count > 0 {
            AppSigner.sharedInstance.newVersion = newVersion
        }
        if newShortVersion.count > 0 {
            AppSigner.sharedInstance.newShortVersion = newShortVersion
        }
        
        
        // check provisioning profiles
        // provisioning profiles may fix application ID, so it has to be the last step.
        if profileFilename.count > 0 {
            if !profileFilename.hasSuffix(".mobileprovision") {
                print("Provisioning profile's name must end with \".mobileprovision\".")
                return false
            }
            if !AppSigner.sharedInstance.fileManager.fileExists(atPath: profileFilename) {
                print("Provisioning profile doesn't exist!")
                return false
            }
            
            // a path which does not start with "/" means it is a relative path
            if !profileFilename.hasPrefix("/") {
                profileFilename = Process().currentDirectoryPath + "/" + profileFilename
            }
            
            if let profile = ProvisioningProfile(filename: profileFilename) {
                if profile.expires.timeIntervalSince1970 < Date().timeIntervalSince1970 {
                    print("Provisioning profile expired")
                    return false
                }
                if profile.appID.characters.index(of: "*") == nil {
                    // Not a wildcard profile
                    AppSigner.sharedInstance.newApplicationID = profile.appID
                }
                AppSigner.sharedInstance.profileFilename = profile.filename
            } else {
                print("Provisoning profile loading failed.")
                return false
            }
        }
        return true
    }
}

let commandlineParser = CommandlineParser()
if commandlineParser.checkParams() {
    AppSigner.sharedInstance.bundleID = "AppSignerCLI"
    Log.bundleID = "AppSignerCLI"
    AppSigner.makeTempFolder()
    AppSigner.createEggTempDir()
    AppSigner.processInputFile()
    AppSigner.codesign()
}
