# Publish WinLauncher 1.2.0 on GitHub

## 1. Build the release

Install the full Xcode application in `/Applications`, then run:

```sh
cd /Users/alexgorovoy/ProjectsG/WinLauncher
./Tools/build-xcode-dmg.sh
```

The release file will be created at `dist/WinLauncher-1.2.0.dmg`.

## 2. Create the GitHub repository

Install and authenticate GitHub CLI:

```sh
brew install gh
gh auth login
```

From the project directory:

```sh
git init
git branch -M main
git add .
git commit -m "Release WinLauncher 1.2.0"
gh repo create WinLauncher --public --source=. --remote=origin --push
```

The GitHub repository should be created without a generated README, license or
`.gitignore`, because this project already contains those files.

## 3. Publish version 1.2.0

```sh
git tag -a v1.2.0 -m "WinLauncher 1.2.0"
git push origin v1.2.0
gh release create v1.2.0 \
  dist/WinLauncher-1.2.0.dmg \
  --title "WinLauncher 1.2.0" \
  --notes-file RELEASE_NOTES.md \
  --verify-tag
```

Open the finished release:

```sh
gh release view v1.2.0 --web
```

For a public release without Gatekeeper warnings, sign the application with an
Apple Developer ID certificate and notarize the DMG before uploading it.
