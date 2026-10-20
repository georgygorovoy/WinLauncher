# Third-party runtime

WinLauncher can download WineForge 0.6.0.5 from the project's
[published release](https://github.com/Alien4042x/WineForge/releases/tag/0.6.0.5).
The disk image is installed separately in the user's Application Support folder
and is verified against its published SHA-256 digest before it is mounted read-only.

The runtime contains Wine, DXMT and other components under their respective
open-source licenses. License files shipped with the runtime are retained beside
the installed engine. Its source provenance and exact build commit are listed in
the linked release. WinLauncher does not download or activate Apple's D3DMetal payload.

For managed .NET applications, WinLauncher can separately download the official
[Wine Mono 11.3.0 x86 MSI](https://dl.winehq.org/wine/wine-mono/11.3.0/).
It is verified against SHA-256
`df2dfc1665c2511882e7cabd56eafd0c0a3d94e5a7e86f969277f6c189d418d3`
before installation. Wine Mono source and license information are published by
the [WineHQ Wine Mono project](https://gitlab.winehq.org/mono/wine-mono).
