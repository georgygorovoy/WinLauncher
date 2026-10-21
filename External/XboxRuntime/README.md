# Xbox Games player runtime

WinLauncher packages this runtime as a separate component and starts it as an
external process. It is based on Bedrock for Mac commit
`4b42c46131fd5b53cae7588773cac2d601471c2f`, WineGDK commit
`b5d23b074cfd5e28e79acceaaefaf41a26ce6272`, and DXMT commit
`589adb780354b461645b29999cefaf533594ee99` (v0.80).

The generated `bin/` directory is intentionally excluded from Git. Build it
from the pinned source and scripts, then package the binary runtime in the DMG.
Minecraft itself, Microsoft credentials, content keys, and proprietary game
files are never included.

The separately executed worker and its scripts remain GPLv3. Wine/WineGDK
remain LGPL-2.1-or-later. DXMT and embedded dependencies retain the notices in
`Source/LICENSES`. WinLauncher's Swift application is not linked with these
components.
