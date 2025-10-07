# Archetype 

## What ?
Archetype is a digital system based on:
- a personal computer, where you have your general purpose software
- a digital hub that will host some services like NAS for backup redundancy, based on raspberry pi, for example
- some software that will integrate your smartphone and tablets to your Archetype system
- one or more nodes (even in cloud) to add redundancy to your ecosystem

## Motivation
Digital freedom: everything is a service, nowadays. We pay for services that rely (mostly) on open source software and our data are on someone else hardware or, even worse, feed algoritms to provide advertising.
As we can replace those services with something we own, let's try it ;) 

## Software architecture
Linux is the OS running PC, hub and nodes: it's the same OS driving almost everything, it's FREE (as in beer) and you can check what software does and counsciously decide where your data should stay.
I based Archetype on Arch Linux: why Arch ? For the hype, of course :D kidding...it's because Arch is a rolling distribution so your OS will continously upgrade to latest versions available of your software.

### PC
PC will run a full fledged desktop system with a polished desktop environment: Gnome

1. Base system: Arch linux base system with:
    - NetworkManager
    - sshd
    - avahi-daemon
    - bluetooth 

## Installation

```
# Download Arch linux for your PC, first
wget https://mirrors.kernel.org/archlinux/iso/latest/archlinux-x86_64.iso
# Boot your PC and in arch live:
# Find your drive with 
lsblk
# in my case is sda




# Obiettivo

Unica ISO, per digital hub e/o PC e/o nodo