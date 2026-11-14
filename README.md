# Ecovacs Deebot with Home Assistant, without the Ecovacs cloud
Control an Ecovacs cleaning bot with Home Assistant (HA) through a self-hosted [Bumper](https://github.com/bmartin5692/bumper)
server. The bot connects to a Wi-Fi hotspot on your computer that has no internet access, so nothing reaches Ecovacs.

Tested with a Deebot T9.

### Prerequisites
- Linux with NetworkManager (`nmcli` and the NetworkManager dispatcher)
- `dnsmasq` installed: NetworkManager needs the binary for the hotspot, the `dnsmasq` service doesn't have to run
- `nftables`, `curl`, Docker with Docker Compose
- a Wi-Fi card that can run the hotspot; while it does, it can't connect to another Wi-Fi

### Home Assistant
The content of `homeassistant/docker-compose.yaml` is taken from https://www.home-assistant.io/installation/linux#docker-compose.
Replace `/PATH_TO_YOUR_CONFIG` with the directory where HA should keep its configuration.
You may want to adjust `TZ` to your actual timezone, otherwise you can already start HA with
```bash
docker compose up
```
from within `homeassistant` and set it up, the web UI will be at http://127.0.0.1:8123.
You can of course start it with `docker compose up -d` but until everything is running it might be better to actually
watch the logs.

### Bumper
The contents of the folder `bumper` are taken from https://github.com/bmartin5692/bumper/tree/master/example/docker-compose
You **must** set `BUMPER_ANNOUNCE_IP` in `bumper/docker-compose.yaml` to your hotspot's IP after it's set up.
You may also want to adjust `TZ` there to your actual timezone.

### Variables
Here we define variables for values we use later on that will or might differ for each setup.
To find your `WIFI_DEVICE` you can use `nmcli -f DEVICE,TYPE device` and take the name where TYPE=wifi

```bash
WIFI_DEVICE='wlan0' # must be your actual wifi device
HOTSPOT_SSID='IoT-Hotspot' # the SSID for the hotspot, just choose a name that isn't already taken near you (nmcli device wifi list)
HOTSPOT_PASSWORD='<a secure password for the hotspot>'
HOTSPOT_NAME='' # optional, defaults to 'Hotspot' if not given. used to start/stop the hotspot
HOTSPOT_NAME="${HOTSPOT_NAME:-Hotspot}"
```

### Hotspot
Here we create the Hotspot and get its IP

Create the Hotspot, forcing it to 2.4 GHz with `band bg` (the bot can't use 5 GHz)
```bash
nmcli device wifi hotspot ifname "$WIFI_DEVICE" ssid "$HOTSPOT_SSID" password "$HOTSPOT_PASSWORD" con-name "$HOTSPOT_NAME" band bg
```

While it's running, get its IP
```bash
HOTSPOT_IP=$(nmcli -g IP4.ADDRESS connection show "$HOTSPOT_NAME"); HOTSPOT_IP=${HOTSPOT_IP%%/*}
echo "$HOTSPOT_IP"
```
--> e. g. `10.42.0.1`

Then stop it with
```bash
nmcli connection down "$HOTSPOT_NAME"
```

### Prepare the bot
Here we set up our cleaning bot so it can connect to HA via bumper:

#### Get the bot's serial number
Now you need the serial number of your bot and set it as variable here.
To find it open the top latch, there are 2 ways to obtain it:
- scan the QR code for the App, the serial number is in the URL as parameter 'sn', e. g. http://appintl.ecovacs.com/download/ecovacshome/AppDownload.htm?mid=yxz&from=robot&sn=ABC123
- or remove the dustbin, under it is a sticker with a barcode the serial number is its value when scanned and also written below it

```bash
SERIAL_NUMBER='ABC123'
```

#### Connect to the bot's WiFi


With the latch still open, press the WiFi button. The bot should say something like "Ready for network setup".
Scan your surrounding WiFis e. g. with
```bash
nmcli device wifi list --rescan yes
```
and look for one with an SSID starting with `ECOVACS_`. Connect to it e. g. with
```bash
BOT_WIFI='ECOVACS_1234'
nmcli device wifi connect "$BOT_WIFI"
```

Get the bot's IP
```bash
BOT_IP=$(nmcli -g IP4.GATEWAY connection show $BOT_WIFI); echo "$BOT_IP"
```
--> e. g. '192.168.0.1'

#### Send the hotspot's SSID and password to the bot
This needs also its serial number, otherwise the bot drops the Wi-Fi connection a few seconds after joining the hotspot later.
I got the command from https://github.com/kushagharahi/ecovacs-privacy-control but the point with the serial number is
not mentioned there. In that request there's just a hard-coded value and it took me some time to figure out that I had
to replace it with my bot's serial number.
```bash
# Variables
PAYLOAD="{\"td\":\"SetApConfig\",\"s\":\"$HOTSPOT_SSID\",\"p\":\"$HOTSPOT_PASSWORD\",\"u\":\"$SERIAL_NUMBER\",\"sc\":\"b0\"}"
BOT_ADDRESS="http://$BOT_IP:8888/rcp.do"

# Constants
USER_AGENT='Dalvik/2.1.0 (Linux; U; Android 14; Android SDK built for arm64 Build/UE1A.230829.036.A1)'
HEADER='Content-Type: application/json'

# Request
curl -sS -X POST "$BOT_ADDRESS" -H "$HEADER" -A "$USER_AGENT" -d "$PAYLOAD"
```
The response should be `{"ret":"ok"}`
Now turn off the bot.


### Guard our Privacy
We don't want to give anyone our data. These Ecovacs bots are quite chatty and we don't want our floor plans being sent
to China and whatnot. So we keep every request inside our own network we fully control.

#### Set DNS entries for known Ecovacs domains
Bumper should be reachable at `HOTSPOT_IP` from the hotspot later.
Add the DNS overrides to NetworkManager’s shared-hotspot DNS config so all the robot's requests get sent to bumper instead
of Ecovacs

Create the folder `dnsmasq-shared.d` in `/etc/NetworkManager` if it doesn't exist
```bash
sudo install -d /etc/NetworkManager/dnsmasq-shared.d
```

Write `bumper.conf`
```bash
sudo tee /etc/NetworkManager/dnsmasq-shared.d/bumper.conf >/dev/null << EOF
address=/ecouser.net/$HOTSPOT_IP
address=/ecovacs.com/$HOTSPOT_IP
address=/ecovacs.net/$HOTSPOT_IP
EOF
```

#### Make the bot accept its IP address
Without these two options the bot ignores the address the hotspot's DHCP server offers it: `no-ping` sends the offer
right away instead of after a 3-second check, `dhcp-broadcast` sends it as broadcast.
```bash
printf 'no-ping\ndhcp-broadcast\n' | sudo tee /etc/NetworkManager/dnsmasq-shared.d/iot-dhcp.conf
```

#### Block direct requests to IP addresses
In case the bot tries to reach a server through its IP address, our DNS overrides wouldn't help much.
Installing `hotspot-offline.sh` blocks all internet access from the hotspot and redirects DNS and Bumper's ports
(443, 5223, 8007, 8883) coming from the hotspot to this machine

```bash
sudo install -m 755 -o root -g root hotspot-offline.sh /etc/NetworkManager/dispatcher.d/90-hotspot-offline
```
Do that command from the root of this repo or replace `hotspot-offline.sh` with its absolute path.
In case you want to uninstall it at some point e. g. because you want a hotspot that can reach the internet,
just remove it with `sudo rm /etc/NetworkManager/dispatcher.d/90-hotspot-offline`

The script's drop rule logs every dropped packet to the kernel log. Especially in the beginning it could be useful to
see if something gets dropped, watch live with
```bash
journalctl -k -f --grep iot-drop
```

#### Optional: check the Guard
You can also check if the internet blocker works:
1. start the hotspot with `nmcli connection up $HOTSPOT_NAME`
2. watch dropped connections with `journalctl -k -f --grep iot-drop`
3. connect another device with the hotspot
4. try to reach a website e. g. `https://github.com` or `http://1.1.1.1` from that device

Expected outcome:
you can't reach any website from the other device and the terminal running `journalctl -k -f --grep iot-drop` shows the dropped connections.

### Set up local services
Now we make everything ready so we can control the bot with HA

#### Start the hotspot
```bash
nmcli connection up $HOTSPOT_NAME
```

#### Start bumper and HA
1. Open `bumper/docker-compose.yaml` and for `BUMPER_ANNOUNCE_IP` replace XXX with your hotspot's IP as stored in `HOTSPOT_IP`
2. start with `docker compose up` from within the folder `bumper`
3. if it's not already running, also start HA with `docker compose up` from within `homeassistant` in a separate terminal

#### Turn on the Bot
Turning on the bot, you should see it connecting to bumper in bumper's container logs

#### Install the Ecovacs Integration in HA
1. go to HA's web UI at http://127.0.0.1:8123
2. under _Settings -> Devices & Services_ press the button "Add Integration"
3. type "ecovacs" in the search field and select Ecovacs
4. As Mode select Self-Hosted - Cloud would defeat the purpose of this whole project and wouldn't work anyway ;)
   - **Username** needs to be an e-mail address (syntactically, doesn't have to exist), will be displayed as the integration's name but you can rename it
   - **Password** any non-empty value (you won't need it but it might be worth writing down somewhere just in case)
   - **REST URL** the output of `echo "http://$HOTSPOT_IP:8007"`
   - **MQTT URL** the output of `echo "mqtt://$HOTSPOT_IP:8883"`
   - **Verify MQTT SSL certificate** should be disabled but it doesn't show in the popup before the first attempt failed. So fill one field wrong like a Username without an @, press "Submit" and then uncheck `Verify MQTT SSL certificate` that's now visible


That's it, the rest should be easy enough for you to figure out.

### Gotchas

#### The bot connects to the hotspot but gets no IP address
If your computer's firewall blocks incoming traffic, it also blocks the bot's DHCP requests. Allow incoming traffic on
`WIFI_DEVICE` for:
- UDP destination port 67 (the bot's first DHCP request goes to `255.255.255.255`, so match the interface, not an IP)
- destination IP `HOTSPOT_IP` (DHCP renewal, DNS, Bumper); this address only exists while the hotspot runs, so the rule
  doesn't open anything on other Wi-Fi networks

### License
MIT, see `LICENSE`. The files in `bumper/` are taken from [Bumper](https://github.com/bmartin5692/bumper) and are
licensed under GPL-3.0, see `bumper/LICENSE.txt`.
