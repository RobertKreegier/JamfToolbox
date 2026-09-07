#!/usr/bin/env bash

strIconName="JamfToolbox"
strScriptFilename="jamf_toolbox_2.3.1_Opus.py"

pyinstaller -w "$strScriptFilename" -i Media/"$strIconName".icns


#pyinstaller --onefile --windowed --icon=Media/JamfToolbox.icns jamf_toolbox_2.3.1_Opus.py