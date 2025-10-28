#!/bin/sh

curl -o /opt/etc/init.d/S99update_list https://raw.githubusercontent.com/Funnnik/scripts/refs/heads/main/S99update_list
curl -o /opt/bin/update_list.sh https://raw.githubusercontent.com/Funnnik/scripts/refs/heads/main/update_list.sh
chmod +x /opt/etc/init.d/S99update_list
chmod +x /opt/bin/update_list.sh
