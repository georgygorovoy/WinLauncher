# File picker compatibility

The pinned WineGDK runtime does not register the file picker classes used by
Minecraft Bedrock 1.26.52. Selecting a skin or importing a world can therefore
throw before a file dialog opens (GitHub issue #4 reports the skin crash).

This GPL-3.0-or-later bridge extends the project's October 10, 2026 local world
import/export implementation. It registers these small, explicit WinRT surfaces:

- `Microsoft.Windows.Storage.Pickers.FileOpenPicker`, constructor with window ID,
  caller-provided `FileTypeFilter`, and `PickFileResult.Path`.
- `Windows.Storage.Pickers.FileOpenPicker`, single-file selection returning
  `StorageFile` and `IStorageItem.Path`.
- `Windows.Storage.Pickers.FileSavePicker`, ordered caller-provided file choices,
  suggested name/default extension, and `IStorageItem.Path`.
- `Windows.Storage.StorageFile.GetFileFromPathAsync`, returning an existing file's
  path and metadata. Modern picker callers can convert their selected path using
  this static method.

The owned 1.26.52 binary contains complete modern open-picker and StorageFile
class names, but no standalone UWP open-picker class name. The UWP open class
shares the same dialog implementation and is covered by the contracts.

October 19 native testing on an M4 Pro passed opening/cancelling the skin dialog,
PNG import and rendering, including a Unicode filename. October 20 tracing found
that the game saves the PNGs, then clears them on startup, consistent with
Mojang's [MCPE-241720](https://bugs.mojang.com/browse/MCPE-241720). The reported
picker crash no longer reproduces locally; issue #4 remains open for reporter
verification. See the [native evidence and limits](../docs/TESTING.md#october-20-skin-persistence-diagnosis).

Open/Save dialogs use Wine's common-dialog APIs on the caller apartment. Open
filters come from extensions such as `.png` and `.mcworld`; there is no hardcoded
world-only filter or automatic extension on open. Save choices retain their
insertion order. The default save extension comes from `DefaultFileExtension`,
then the first selected choice's extension. Saving creates an empty file when
needed and never truncates an existing file. The game reads/writes the selection.
Cancellation completes with a null result; dialog/filesystem failures produce a
typed failed async operation. Completion callbacks run once and may reenter
results/close safely. The bridge never patches Minecraft or accesses accounts.

This is not complete Windows.Storage: multiple selection, storage streams,
continuation APIs, collection iteration/map views, and persistent picker state
are unsupported. Suggested start location and view mode are retained as API
properties; the common dialogs use Wine's default location/view. Unsupported
interfaces fail with `E_NOINTERFACE`; unsupported methods return `E_NOTIMPL`.

## Build and integration

Build only, without touching any prefix:

```sh
sh file-pickers/build.sh --wine-build "$PWD/build/standalone-wine" \
  --output "$PWD/build/file-pickers"
```

Outputs are `bedrock-pickers.dll`, `file-picker-contract.exe`, and a version-1
`build-manifest.json`. The receipt records the DLL's `files` SHA-256 value and
repository relative `source_sha256` values for its C, IDs, exports and build script.
`test_source_sha256` separately records the Windows check script, README and
contract test; those do not affect runtime compatibility. Compilation and hashes
use the same captured source files. `--stage-runtime /absolute/wine` explicitly
stages the DLL and receipt to an idle Wine runtime, preserving previous bytes and
refusing mapped or unrecognized files. Integration then
copies it atomically to the idle prefix's system32 directory. Registration and
setup signatures must bind the exact DLL bytes. A source rebuild and app package
must include the same verified component. No manual install script is provided.

Run the contract executable only through the project's guarded native QA workflow
in an isolated prefix. Set Windows environment variable `BEDROCK_PICKER_DLL` to
the Windows path of the exact built DLL. Without that variable the contract uses
`R:\build\file-pickers\bedrock-pickers.dll`.

Contracts mock visible dialogs and cover independent modern/UWP ABI slots, PNG
and mixed filters, rejected extension injection, selection/cancel/error, Unicode
paths, async ownership and callback reentry, filesystem errors, save creation and
preservation, and the separately loaded DLL's activation exports. They create
and remove only temporary files. They do not demonstrate in-game skin rendering.
Native QA must additionally select/cancel a valid PNG in Dressing Room, reject an
invalid image, restart to verify persistence, and regress world import/export.

On Windows, `file-pickers\check-windows.cmd` builds and runs the same contracts
from an x64 MSVC developer prompt with the Windows SDK. This checks real Windows
ABI behavior without building or running Wine, Minecraft, or a Wine prefix.

## ABI provenance

- Microsoft's [Windows App SDK picker IDL](https://github.com/microsoft/WindowsAppSDK/blob/main/dev/Interop/StoragePickers/Microsoft.Windows.Storage.Pickers.idl).
- Official NuGet `Microsoft.WindowsAppSDK.Foundation` 1.8.260803002,
  `metadata/Microsoft.Windows.Storage.Pickers.winmd`, for stable 1.8 GUIDs/order.
  Newer 2.0 properties belong to additional interfaces and are unsupported here.
- Microsoft's [Windows Rust picker projections](https://github.com/microsoft/windows-rs/blob/master/crates/libs/windows/src/Windows/Storage/Pickers/mod.rs)
  and the pinned Wine Windows.Storage declarations for UWP GUIDs and ABI order.
- WinRT parameterized-interface IDs in `ids.h` use Microsoft's UUID-v5 namespace
  and type signatures.

The implementation is original project source. The separately downloaded
BedrockOnLinux picker patches were inspected as behavior references; their
implementation was not copied or incorporated into this bridge.
