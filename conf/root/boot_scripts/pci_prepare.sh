#!/bin/sh

virsh nodedev-detach pci_0000_26_00_0  # This will remove sda/sdb which is 2TB HDD and 1 TB samsung SSD drives
# virsh nodedev-detach pci_0000_2c_00_0  # This will remove sdc which is boot pool
midclt call disk.sync_all
