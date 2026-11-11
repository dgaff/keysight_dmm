# Keysight DMM MacOS

My Keysight 344470A Benchtop Digital Multiple Meter doesn't have a good Mac App. There's a Windows app from Keysight, and while it works, it's pretty clunky. The purpose of this project is to build a modern-looking, Mac OS app in Swift that I can control over the network. I want to expose all of the DMM's functionality, and I'd like to expand upon the capabilities of the Windows app.

# Reference Material

You have access to the following information to help formulate a plan and implementation. I'd like you to delegate development to sub-agents whenever possible, ideally using less-costly models whenever possible.

* sample_screens folder shows screen captures from the Windows app.
* KeysightDMM.pdf is the manual for the meter. It includes an SCPI programming reference.

# Requirements

* Provide auto-discovery of the meter on the network.
* Use the screens from the Windows app as inspiration, but apply Mac-centric design sensibility and suggest improvements to UX in the plan.
* Build the app in Swift with a light background design, as opposed to the dark background in the Window's app.
* Leverage the built-in data logging functionality of the meter for the data logging screens. The goal is to be able to run tests on the device. It's fine to also supply app-side real time recording, but first build the on-meter logging.
* Make sure there's a focus on helping the user understand how to control the meter. The Windows app does a good job of this by expose settings that are available on the meter's front panel soft buttons.
* Gracefully exit the app and shut down the remote connection. The Windows app isn't good with this.
* Ensure there is good export support, both of on-meter recordings and and on-laptop recordings.
* Play close attention to units and unit prefixes. These can sometimes cause problems with SCPI implementations.
* If you find any undocumented SCPI commands, I'd love to include those as experimental.

# Implementation and Testing

* Please suggest a plan in phases. As always, ask any clarifying questions. NOTE: if you have network issues, PAUSE and alert me. It's almost certain that I have to unblock your app in LittleSnitch. Don't assume the network issues are your fault.
* Please keep track of your work so that restoring context is easier when I come back to the project to fix bugs or implement new features.
* I have a Waveform generator and DC power supply on the bench that are also on the network. For the testing phases, prompt me to hook up your desired test infrastructure before running the tests.
