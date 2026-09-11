
<p align="center">
  <img src="./banner.png" alt="Manifest — CC:Tweaked chest manager" width="100%">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/lua-CC%3ATweaked-2c2d72.svg" alt="CC:Tweaked">
  <img src="https://img.shields.io/badge/game-Minecraft-62b47a.svg" alt="Minecraft">
  <img src="https://img.shields.io/badge/web%20bridge-optional-lightgrey.svg" alt="Optional web bridge">
</p>

# Manifest

Manifest is my 4th stardance project and also a CC:Tweaked program that indexes every chest on a wired modem network so
you can search it and pull items from a monitor

# FOR THE STARDANCE REVIEWER
THIS IS NOT A MINECRAFT MOD, THIS IS A SCRIPT FOR THE MOD CC: TWEAKED

## Usage

```
wget run https://raw.githubusercontent.com/tomTTFB/manifest/master/server/install.lua

config    # pick the inventory items get sent to
reboot    # Manifest is startup.lua, so it runs on boot
```

Everything after that happens on the monitor. Re-run `config` whenever you change your storage setup
changes also the same picker is in the Settings tab.

## Tabs

| Tab | What it covers |
| --- | --- |
| `Manifest` | Search, the item list, and a request bar for picking an item and pulling it |
| `Spatial` | AE2 spatial IO, load and unload cells, format a spare one |
| `Settings` | Output inventory, text scale, scan interval, bridge address |

## What is scanned

Every inventory peripheral on the network except the output and the cell barrel. Inventories touching the computer wont work if they arent connected to the network/have a connected modem

Search matches the item id as well as the display name, so typing `minecraft:` or a mod
prefix narrows the list down to one mod's items.

## Web bridge

`server/bridge.py` is a web interface that lets you request items from there,
handy when there's nobody stood at the monitor to press pull. it requires Flask and runs on port 8081.

Manifest asks for its address on the first boot and writes the answer to `manifest.cfg`.
Skipping the prompt will turn it off but you can blanking the `bridge=` line by hand to get asked again in the setup

## Disclaimer

This has only been run against one world on one pack. Nothing it does is destructive, but it
does move items around on your behalf, so point it at a storage system you are willing to
watch for a bit before trusting it with a wall of chests.

## License

MIT
