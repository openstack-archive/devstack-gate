#!/bin/bash 

set -x
sudo cobbler sync
#sudo cobbler system edit --netboot-enabled=Y --name=baremetal6 
sudo cobbler system edit --netboot-enabled=Y --name=baremetal7 
sudo cobbler system edit --netboot-enabled=Y --name=baremetal8 
sudo cobbler system edit --netboot-enabled=Y --name=baremetal9 
#sudo cobbler system reboot --name=baremetal6 
sudo cobbler system reboot --name=baremetal7 
sudo cobbler system reboot --name=baremetal8 
sudo cobbler system reboot --name=baremetal9 
