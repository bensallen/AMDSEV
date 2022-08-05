#!/bin/bash

#
# user changeable parameters
#
BASEDIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
HDA_FILE=""
GUEST_SIZE_IN_MB="4096"
SEV_GUEST="1"
SMP_NCPUS="4"
CONSOLE="serial"
QEMU_BIN=qemu-system-x86_64
UEFI_BIOS_CODE="/usr/share/qemu/ovmf-x86_64-suse-4m-code.bin"
UEFI_BIOS_VARS="/usr/share/qemu/ovmf-x86_64-suse-4m-vars.bin"
#VNC_PORT=""
USE_VIRTIO="1"

declare -a QEMU_CMDLINE

usage() {
	echo "$0 [options]"
	echo "Available <commands>:"
  echo " -dir          base directory for VM"
	echo " -hda          hard disk ($HDA_FILE)"
	echo " -nosev        disable sev support"
	echo " -mem          guest memory"
	echo " -smp          number of cpus"
	echo " -console      display console to use (serial or gxl)"
	echo " -vnc          VNC port to use"
	echo " -bios         bios to use (default $UEFI_BIOS_CODE)"
	echo " -kernel       kernel to use"
	echo " -initrd       initrd to use"
	echo " -cdrom        CDROM image"
	echo " -virtio       use virtio devices"
	exit 1
}

add_opts() {
  QEMU_CMDLINE+=( "$@" )
}

run_cmd () {
	if "$@"; then
		echo "command $* failed"
		exit 1
	fi
}

while [[ $1 != "" ]]; do
	case "$1" in
    -dir) 		BASEDIR="$(realpath -f -- "${2}")"
				shift
				;;
		-hda) 		HDA_FILE="${2}"
				shift
				;;
		-nosev) 	SEV_GUEST="0"
				;;
		-mem)  		GUEST_SIZE_IN_MB=${2}
				shift
				;;
		-console)	CONSOLE=${2}
				shift
				;;
		-smp)		SMP_NCPUS=$2
				shift
				;;
		-vnc)		VNC_PORT=$2
				shift
				if [ "${VNC_PORT}" = "" ]; then
					usage
				fi
				;;
    -bios)		UEFI_BIOS_CODE="$(readlink -f "${2}")"
				shift
				;;
		-initrd)	INITRD_FILE=$2
				shift
				;;
		-kernel)	KERNEL_FILE=$2
				shift
				;;
		-cdrom)		CDROM_FILE=$2
				shift
				;;
		-virtio)  USE_VIRTIO="1"
				;;
		*) 		usage;;
	esac
	shift
done

# Basic virtual machine property
add_opts "-enable-kvm" "-cpu" "EPYC,ibpb=on,virt-ssbd=on,monitor=off,x2apic=on,hypervisor=on,svm=off,topoext=on" "-machine" "q35"

# add number of VCPUs
[ -n "${SMP_NCPUS}" ] && add_opts "-smp" "${SMP_NCPUS},maxcpus=64"

# define guest memory
add_opts "-m" "${GUEST_SIZE_IN_MB}M,slots=5,maxmem=30G"

# The OVMF binary, including the non-volatile variable store, appears as a
# "normal" qemu drive on the host side, and it is exposed to the guest as a
# persistent flash device.
if [ -w "${BASEDIR}/OVMF_VARS.fd" ]; then
  cp "${UEFI_BIOS_VARS}" "${BASEDIR}/OVMF_VARS.fd"
fi

add_opts "-drive" "if=pflash,format=raw,unit=0,file=${UEFI_BIOS_CODE},readonly"
add_opts "-drive" "if=pflash,format=raw,unit=1,file=${BASEDIR}/OVMF_VARS.fd"

# add CDROM if specified
[ -n "${CDROM_FILE}" ] && add_opts "-drive" "file=${CDROM_FILE},media=cdrom" "-boot" "d"

if [ "$USE_VIRTIO" = "1" ]; then
  add_opts "-netdev" "user,id=vmnic" "-device" "virtio-net-pci,netdev=vmnic,disable-legacy=on,iommu_platform=true"
else
  add_opts "-netdev user,id=vmnic" "-device" "e1000,netdev=vmnic,romfile="
fi

# If harddisk file is specified then add the HDD drive
if [ -n "${HDA_FILE}" ]; then
	if [ "$USE_VIRTIO" = "1" ]; then
		if [[ ${HDA_FILE} = *"qcow2" ]]; then
      add_opts "-drive" "file=${HDA_FILE},if=none,id=disk0,format=qcow2"
		else
      add_opts "-drive" "file=${HDA_FILE},if=none,id=disk0,format=raw"
		fi
    add_opts "-device" "virtio-scsi-pci,id=scsi,disable-legacy=on,iommu_platform=true"
    add_opts "-device" "scsi-hd,drive=disk0"
	else
		if [[ ${HDA_FILE} = *"qcow2" ]]; then
      add_opts "-drive" "file=${HDA_FILE},format=qcow2"
		else
      add_opts "-drive" "file=${HDA_FILE},format=raw"
		fi
	fi
fi

# If this is SEV guest then add the encryption device objects to enable support
if [ ${SEV_GUEST} = "1" ]; then
  add_opts "-object" "sev-guest,id=sev0,cbitpos=47,reduced-phys-bits=1"
  add_opts "-machine" "memory-encryption=sev0"
fi

# if console is serial then disable graphical interface
if [ "${CONSOLE}" = "serial" ]; then
  add_opts "-nographic" "-serial" "mon:stdio"
else
  add_opts "-vga ${CONSOLE}"
fi

# if -kernel arg is specified then use the kernel provided in command line for boot
if [ "${KERNEL_FILE}" != "" ]; then
  add_opts "-kernel" "$KERNEL_FILE"
  add_opts "-append" "console=ttyS0 earlyprintk=serial"
  [ -n "${INITRD_FILE}" ] && add_opts "-initrd" "${INITRD_FILE}"
fi

# start vnc server
[ -n "${VNC_PORT}" ] && add_opts "-vnc" ":${VNC_PORT}" && echo "Starting VNC on port ${VNC_PORT}"

# start monitor on pty
add_opts "-monitor" "pty"

# log the console  output in stdout.log
QEMU_CONSOLE_LOG="${BASEDIR}/stdout.log"

# save the command line args into log file
echo "${QEMU_BIN}" "${QEMU_CMDLINE[@]}" | tee -a "${QEMU_CONSOLE_LOG}"
echo | tee -a "${QEMU_CONSOLE_LOG}"

echo "Launching VM ..."
"${QEMU_BIN}" "${QEMU_CMDLINE[@]}" 2>&1 | tee -a "${QEMU_CONSOLE_LOG}"
