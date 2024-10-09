# Daisy Chain VPN

## Motivation

So I have two problems:

1. The VPN provider I use only allows 5 concurrent sessions, and I easily max that out often.
My phone uses at least 3 of them alone since I use [GrapheneOS](https://grapheneos.org/) with multiple profiles.
2. I want to be able to access my files and services from outside my home, but I don't really want to expose 20+ ports on my home network to the internet.

To fix this, I created a double-chain vpn set up, such that I can connect my devices to my server,
and my server will tunnel that traffic through my VPN, and also allow connecting to my LAN.
This kills two birds with one stone.

I didn't want to use Cloudflared, Tailscale, and other similar services since I wanted to self-host.
Instead, my VPN provides external port forwarding (I can open a port on the VPN exit node),
and I set up a Dynamic DNS to connect to my server over through the VPN.

## Black and Yellow Concept

Some of my devices won't need access to my media server or home devices over the VPN,
since it may be used only for Youtube or something.
These devices don't need access to my LAN or to other devices on the VPN, so they'll use a separate, more isolated VPN.
Each VPN gets its own subnet of 256 addresses

The Yellow VPN allows access to:

- My home network (usually on `192.168.0.0/16` somewhere)
- Other devices on the Yellow VPN (we pick something like `10.0.0.0/24`)
- All the services I'm hosting on the server (refer to my homelab repository)
- The VPN I use to access the internet

The Black VPN, on the otherhand, only allows access to:

- The VPN I use to access the internet
- Our self-hosted ad-blocking recursive DNS server
    - This is a Pi-Hole using the oisd blacklist, with Unbound as an upstream recursive DNS resolver
    - This will already be accessible on port 53 on this server/gateway
    - This is the only local service devices on the Black VPN it will be able to access

# Installation

## Initial Set Up

We'll be needing UFW, Wireguard as well as the included `wg-quick` tools:

```bash
sudo apt install wireguard ufw
```

First, we'll configure UFW with some sensible defaults.
We want to allow outgoing traffic and deny incoming traffic by default,
then make exceptions for individual services we want to expose on the machine:

```bash
sudo ufw default allow outgoing
sudo ufw default deny incoming
```

Then we can add some rules, such as allowing SSH access only from local devices:

```bash
sudo ufw allow proto tcp from 192.168.0.0/16 to any port 22
sudo ufw allow proto tcp from 172.16.0.0/12 to any port 22
sudo ufw allow proto tcp from 10.0.0.0/8 to any port 22
sudo ufw allow proto tcp from fc00::/7 to any port 22
sudo ufw allow proto tcp from fe80::/10 to any port 22
```

We'll also need to enable IP forwarding on the server.
To make the changes permanent, you'll need to edit `/etc/sysctl.conf` instead of just using `sysctl`.
Uncomment the following lines in `/etc/sysctl.conf`:

```
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
```

## Configuration Files

First we pick an IPv4 and IPv6 subnet for our VPN, such as `10.0.0.0/24` and `2001:db8::/32`
Be sure to pick a sensible subnet reserved for local networks, large enough for all your devices but not too greedy.
We'll give the server/gateway the 2nd address (such as `10.0.0.1` and `2001:db8::1`),
and each device after some consecutive address (such as `10.0.0.2` and `2001:db8::2`, `10.0.0.3` and `2001:db8::3`,...)

Then you'll need to fill out the configuration files with some freshly generated keys.
The server and every client will need their own public and private keys, and to share a preshared key.
The preshared key adds a level of symmetric encryption for a little post-quantum resiliency.

```bash
wg genkey | tee private.key
wg genkey < private.key | tee public.key
wg genpsk | tee preshared.key
```

While this stuff can all be done automatically with things such as wg-easy, I needed very granular control.
A lot of tinkering was required to get this working as intended.

The config file for the server will look like:

```
[Interface]
Address = <YOUR-GATEWAY-IPV4>
Address = <YOUR-GATEWAY-IPV6>
ListenPort = <YOUR-GATEWAY-WIREGUARD-PORT>
PrivateKey = <YOUR-GATEWAY-PRIVATE-KEY>

# We'll discuss these in a moment
PostUp=...
...
PreDown=...
...

# First peer example, duplicate and generate fresh keys for each peer
[Peer]
PublicKey = <YOUR-PEER'S-PUBLIC-KEY>
PresharedKey = <YOUR-PEER'S-PRESHARED-KEY>
AllowedIPs = <YOUR-PEER'S-IPV4>, <YOUR-PEER'S-IPV4>
```

The config file for each of the clients will look like:

```
[Interface]
PrivateKey = <YOUR-PEER'S-PRIVATE-KEY>
Address = <YOUR-PEER'S-IPV4>, <YOUR-PEER'S-IPV4>
DNS = <YOUR-GATEWAY-IPV4>, <YOUR-GATEWAY-IPV6>
MTU = 1320

[Peer]
PublicKey = <YOUR-GATEWAY-PUBLIC-KEY>
PresharedKey = <YOUR-PEER'S-PRESHARED-KEY>
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 15
Endpoint = <YOUR-GATEWAY-DNS-NAME>:<YOUR-GATEWAY-WIREGUARD-PORT>
```

The `AllowedIPs` parameter means something different depending on the context.
When used in the server configuration, it decides the VPN address the client will be reachable at.
When used in the client configuration, it decides what outgoing IP addresses will be tunnelled.
`0.0.0.0/0` and `::0/0` means that all traffic, including LAN and internet, will be tunnelled by the client.
We don't implement the Black/Yellow isolation here as this is out of the server's control.

## Black and Yellow Implementation

To segregate the clients on Black and Yellow, we'll do the above twice to create two VPNs,
each on their own port with their own DDNS domains.
Then, we can customise the access by running firewall commands on the gateway with the `PostUp` and `PreDown` hooks.

Rather than copying the full script here, I'll just explain some of the key snippets.
See [the black server configuration](black/server-black/wg-black.conf) and
[the yellow server configuration](yellow/server-yellow/wg-yellow.conf) for the full example.
There will be similar versions of these commands for both IPv4 and IPv6:

1.  This opens the port that is externally port forwarded to allow connections to this VPN.
    You can do this for your LAN interface too to allow LAN devices to use the VPN without tunnelling out of the LAN first.

    ```bash
    ufw allow in on <YOUR-INTERNET-VPN-INTERFACE> to any port <YOUR-GATEWAY-WIREGUARD-PORT> proto udp
    ```
2.  This allows devices that are connected to forward their traffic through our VPN out to our internet VPN.
    To allow access to the LAN, just do the same with your LAN interface as well.

    ```bash
    ufw route allow in on %i out on <YOUR-INTERNET-VPN-INTERFACE>
    ```

3.  This enabled forwarding the traffic (see above) by allowing NAT using IP masquerading.
    Same as above, copy for your LAN interface if you want.

    ```bash
    iptables -t nat -A POSTROUTING -o <YOUR-INTERNET-VPN-INTERFACE> -j MASQUERADE
    ```

4.  This disables access to other devices on the VPN except for the gateway's DNS server.
    The `prepend` makes it override all your other rules, and the bottom `allow` rule will override the top `deny` rule.
    
    ```bash
    ufw prepend deny from <YOUR-CHOSEN-VPN-SUBNET> to any
    ufw prepend allow from <YOUR-CHOSEN-VPN-SUBNET> to any port 53
    ```

# Enabling Everything

Once you've finished your server configuration files, you can copy or symlink them to your `/etc/wireguard/' directory.
This is where wireguard looks for configuration files when you try to enable an interface.

Then, to enable it just once, you can run:

```bash
sudo wg-quick up wg-black.conf
sudo wg-quick up wg-yellow.conf
```

Or alternatively, to have them automatically start on every boot, you can do:

```bash
sudo systemctl enable wg-quick@wg-black
sudo systemctl enable wg-quick@wg-yellow
```

If you're using DuckDNS for dynamic DNS, you can use the script I created to automatically update your IP address.
You'll first need to open the script and add your own token and domain name:

```bash
#!/bin/bash
set -e

# DuckDNS variables
DOMAIN=
TOKEN=
LOG_FILE=/var/log/duckdns.log

IPv6=$(curl -s https://api6.ipify.org)
IPv4=$(curl -s https://api.ipify.org)

SITE="https://www.duckdns.org/update?domains=${DOMAIN}&token=${TOKEN}&ip=${IPv4}&ipv6=${IPv6}&verbose=true"

curl -s $SITE -o $LOG_FILE
```

Then the following to your crontab with `sudo crontab -e`, altering the path to the script and update frequency to your preferences:

```cron
*/5 * * * * /path/to/duckdns.sh >/dev/null 2>&1
```

# Future TODOs

1. Since Wireguard alone doesn't provide much obfuscation again deep packet inspection (see the official [known limitations](https://www.wireguard.com/known-limitations/)),
this guide may be updated to add support for [AmneziaWG](https://docs.amnezia.org/documentation/amnezia-wg/).
2. This (relatively) simple setup also doesn't make full use of Linux's ability to further isolate network interfaces with [Network Namespaces](https://www.wireguard.com/netns/).
This may also be added in the future.