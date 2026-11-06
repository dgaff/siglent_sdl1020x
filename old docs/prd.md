# Siglent DC Load Mac App

## Intro

The purpose of this project is to create a Mac app that mirrors (and hopefully expands) the functionality available in the "EasySDL" Windows app from Siglent. This app is for use with the SDL1000X series DC load systems. There's no Mac app available, but there's a full SCPI interface to the device.

## Requirements

There are 6 screens in the EasySDL app, captured in the screen shots included in this project. The Mac app should mimic the functionality of those screens, although I'm open to other design choices if a better UX is possible.

Additionally, the app provides auto-discovery of devices on the network and the ability to manually input a device's IC address. The app does not need serial interface support at this time.

I'm especially interested in time recordings of load, since I intend to use this device for battery characterization. So if there's the ability to enhance that functionality, I'd like to explore that.

The SCPI programming guide and the user manual are included in this folder for reference.

## Claude Instructions

Please review the documentation and the screen shots from the EasySDL windows application. Please then build an implementation plan to create the Mac app. Ask any clarifying questions at the beginning to establish the architecture and initial UX decisions.

A real SDL1020X device is connected to 192.168.1.10, and SCPI drivers are already installed on this Mac, as I have other scripts in place for different devices. I can supply power to the SDL1020X for testing if required. Please specify your testing needs in the implementation plan, so I know which parts can be implemented by you unassisted and which parts will need me at the computer.
