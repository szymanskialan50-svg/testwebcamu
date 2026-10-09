# USC-CAM - iPhone as a USB webcam (4K / 1440p)

iPhone app streams camera video over the USB cable; the Windows app turns it into a virtual webcam.

## Build
Push to GitHub -> Actions -> *Build USC-CAM* -> download `USC-CAM-Package` (contains `USC-CAM.ipa` and `USC-CAM.exe`).

## Install / use
1. iPhone: sideload `USC-CAM.ipa` (Sideloadly / AltStore - the ipa is unsigned). Open the app, allow the camera.
2. PC (one time): install **iTunes** or **Apple Devices** (USB driver) and **OBS Studio** (virtual camera driver).
3. Plug the iPhone in, tap *Trust*, keep USC-CAM open on the phone, run `USC-CAM.exe`.
4. In Zoom / Discord / Teams etc. pick **OBS Virtual Camera**.

Note: iOS pauses the camera when the app is in the background - keep it open (use *Dim screen* to save battery).
