<?xml version="1.0" encoding="UTF-8"?>
<domain type='kvm'>
  <name>__NAME__</name>
  <memory>2097152</memory>
  <vcpu>2</vcpu>
  <cpu mode='host-passthrough'/>
  <os>
    <type arch='x86_64'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
    <pae/>
  </features>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>restart</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='__DISK__'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='file' device='cdrom'>
      <source file='__ISO__'/>
      <target dev='hdc' bus='ide'/>
      <readonly/>
    </disk>
    <interface type='network'>
      <source network='opn_wan'/>
      <model type='virtio'/>
    </interface>
    <serial type='pty'/>
    <console type='pty'/>
    <graphics type='vnc' listen='127.0.0.1' autoport='yes'/>
  </devices>
</domain>
