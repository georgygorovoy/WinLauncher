# Store and Profile

Store is WinLauncher's default screen. It combines public game results from
Steam's storefront `api/storesearch` and `api/featuredcategories` endpoints
and its free search page with GOG's `catalog/v1/catalog` endpoint. The home
screen takes approximately equal numbers of Steam and GOG results and highlights
free Steam picks. A title is marked free only when Steam explicitly labels it
Free or a store sends a zero price; missing price means unknown. Search waits
briefly after typing. Results can be filtered by store and shown A–Z (default),
free only, low price paid, high price, or popular. Popular uses the storefronts'
own result ranking. Price order compares displayed numbers without currency
conversion. A Steam result can ask the
installed Steam client to install via `steam://install/<appid>` when a native
Mac version is offered or the user has enabled Windows downloads. Steam
handles ownership and the actual download. Other results open official product
pages for sign-in and installation. WinLauncher does not download paid or
account-bound game files itself.

Epic Games Store and Ubisoft Store have official-site buttons. Their game
results are not mixed into the list because no stable public catalog interface
has been verified for this integration. Both storefront endpoints currently
used for the combined list are public website interfaces, so their schemas can
change; WinLauncher keeps the results from the other store when one fails.

Android has its own tab with the F-Droid installer. Profile lists installed
launchers, WinLauncher library apps, detected Windows Steam games, and launch
history recorded by WinLauncher. Native Steam launches made outside WinLauncher
are not recorded in that history.
