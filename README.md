# iOS App Signer
This is an app for OS X that can (re)sign apps and bundle them into ipa files that are ready to be installed on an iOS device.

Supported input types are: ipa, deb, app, xcarchive

Usage
------
This app requires Xcode to be installed, it has only been successfully tested on OS X 10.11 at this time.

You need a provisioning profile and signing certificate, you can get these from Xcode by creating a new project.

You can then open up iOS App Signer and select your input file, signing certificate, provisioning file, and optionally specify a new application ID and/or application display name.

<a href="https://paypal.me/DanTheMan827" class="donate"><img src="http://dantheman827.github.io/images/donate-button.svg" height="44" alt="Donate"></a>

Thanks To
------
[maciekish / iReSign](https://github.com/maciekish/iReSign): The basic process was gleaned from the source code of this project.


# iOS App Signer CLI

Usage
-----

```
./iOSAppSignerCLI -i ipa_file -o output_ipa_file -c certificate_name [-p provisioning_profile] [-b bundle_id] [-d display_name] [-v version_num] [-s short_version_num]
```

Example
------
```
./iOSAppSignerCLI -i /Users/xiemotongye/Desktop/org.ipa -o /Users/xiemotongye/Desktop/new.ipa  -c "iPhone Developer: Yimin Huang (5VET999CZ9)" -p /Users/xiemotongye/Desktop/aaa.mobileprovision -v 5.24
```
