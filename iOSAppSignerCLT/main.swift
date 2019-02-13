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
    
    struct Arguments {
        let ipaFile: String?
        let signingCertificate: String?
        let provisioningProfile: String?
        let applicationID: String?
        let appDisplayName: String?
        let appVersion: String?
        let appShortVersion: String?
        
        init() {
            signingCertificate = nil
            provisioningProfile = nil
            applicationID = nil
            appDisplayName = nil
            appVersion = nil
            appShortVersion = nil
            ipaFile = nil
        }
        
    }
    
    let arguments: Arguments
    
    private static func printUsage() {
        let usage = [
            "Usage: \(CommandLine.arguments[0]) ipa_file certificate [-p provisioning_profile] [-b bundle_id] [-d display_name] [-v version_num] [-s short_version_num]",
        ]
        
        print(usage.joined(separator: "\n") + "\n")
    }
    
    init() {
        var argc = CommandLine.argc
        
        if argc < 4 {
            arguments = Arguments()
            CommandlineParser.printUsage()
            return
        }
        arguments = Arguments()
        var args = CommandLine.arguments
    }

}



let commandlineParser = CommandlineParser()
