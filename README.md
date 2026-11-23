# Wayback Folder Downloader

A macOS app that downloads a GitHub folder or repository from a dated Wayback Machine capture. It saves the recovered files in a local folder and preserves the directory structure.

## Build and open

Requires macOS 14 or later and Xcode or the Xcode Command Line Tools with Swift 6.

```sh
git clone https://github.com/JacobisGreat/wayback-folder-downloader.git
cd wayback-folder-downloader
./build.sh
open "$HOME/Applications/Wayback Folder Downloader.app"
```

Run `./build.sh /path/to/destination` to install the app in a different directory.

## Recover a folder

1. Open a dated Wayback Machine capture of a GitHub repository or a GitHub `/tree/` folder page.
2. Copy the capture URL from the address bar and paste it into the app.
3. Click **Download Folder**. The app saves to **Downloads** by default. Click **Choose…** to change the destination.
4. Click **Show in Finder** to open the saved folder or **Details** to see which files were recovered.

When the capture identifies a commit that GitHub can still serve, the app verifies file contents against that commit’s Git blob hashes. Otherwise, it looks for archived copies and may recover a partial folder or use file captures from other dates. The **Details** panel lists known gaps and date differences.
