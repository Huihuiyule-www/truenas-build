#!/bin/sh

# Source helper functions
. scripts/functions.sh

TMPFS="./tmp/tmpfs"
CHROOT_BASEDIR="${TMPFS}/chroot"
CHROOT_OVERLAY="${TMPFS}/chroot-overlay"
DPKG_OVERLAY="./tmp/dpkg-overlay"
WORKDIR_OVERLAY="${TMPFS}/workdir-overlay"
CACHE_DIR="./tmp/cache"
PKG_DIR="./tmp/pkgdir"
RELEASE_DIR="./tmp/release"
CD_DIR="./tmp/cdrom"
LOG_DIR="./logs"
HASH_DIR="./tmp/pkghashes"
MANIFEST="./conf/build.manifest"
SOURCES="./sources"

# Makes some perl scripts happy during package builds
export LC_ALL="C"
export LANG="C"

exit_clean() {
	del_overlayfs
	del_bootstrapdir
	exit_err "$1"
}

cleanup() {
	del_overlayfs
	del_bootstrapdir
	rm -rf tmp
	rm -rf ${SOURCES}
}

preflight_check() {
	# Check for deps
	DEPS="debootstrap jq git xorriso grub-mkrescue mformat"
	for i in $DEPS
	do
		which $i >/dev/null 2>/dev/null
		if [ $? -ne 0 ] ; then
			exit_err "Failed preflight check. Please install: $i"
		fi
	done

	if [ ! -d tmp/ ] ; then mkdir tmp ; fi
	if [ ! -d ${PKG_DIR} ] ; then mkdir ${PKG_DIR} ; fi
	if [ ! -d ${HASH_DIR} ] ; then mkdir -p ${HASH_DIR} ; fi
	if [ -d ${LOG_DIR} ] ; then
		rm -rf ${LOG_DIR}
	fi
	mkdir -p ${LOG_DIR}

	# Validate MANIFEST
	jq -r '.' ${MANIFEST} >/dev/null 2>/dev/null || exit_err "Invalid $MANIFEST"
}

make_bootstrapdir() {
	del_overlayfs
	del_bootstrapdir

	if [ -n "$1" ] ; then
		CDBUILD=1
		DEOPTS="--components=main,contrib,nonfree --variant=minbase --include=systemd-sysv,gnupg,grub-pc,grub-efi-amd64-signed"
		CACHENAME="cdrom"
	else
		DEOPTS=""
		CACHENAME="package"
		unset CDBUILD
	fi

	# Setup our ramdisk, up to 4G should suffice
	mkdir -p ${TMPFS}
	mount -t tmpfs -o size=4G tmpfs ${TMPFS}

	# Check if there is a cache we can restore
	if [ -e "${CACHE_DIR}/basechroot-${CACHENAME}.squashfs" ]; then
		restore_build_cache "${CACHENAME}"
		return 0
	fi

	# Bootstrap the debian base system
	apt-key --keyring /etc/apt/trusted.gpg.d/debian-archive-truenas-automatic.gpg add keys/truenas.gpg 2>/dev/null >/dev/null || exit_err "Failed adding truenas.gpg apt-key"
	aptrepo=$(jq -r '."apt-repos"."url"' $MANIFEST)
	aptdist=$(jq -r '."apt-repos"."distribution"' $MANIFEST)
	aptcomp=$(jq -r '."apt-repos"."components"' $MANIFEST)
	debootstrap ${DEOPTS} --keyring /etc/apt/trusted.gpg.d/debian-archive-truenas-automatic.gpg \
		bullseye ${CHROOT_BASEDIR} $aptrepo \
		|| exit_err "Failed debootstrap"
	mount proc ${CHROOT_BASEDIR}/proc -t proc
	mount sysfs ${CHROOT_BASEDIR}/sys -t sysfs

	if [ -z "$CDBUILD" ] ; then
		# Add extra packages for builds
		chroot ${CHROOT_BASEDIR} apt install -y build-essential \
			dh-make devscripts fakeroot \
			|| exit_err "Failed chroot setup"
	fi

	# Save the correct repo in sources.list
	echo "deb $aptrepo $aptdist $aptcomp" > ${CHROOT_BASEDIR}/etc/apt/sources.list

	# Add additional repos
	for k in $(jq -r '."apt-repos"."additional" | keys[]' ${MANIFEST} 2>/dev/null | tr -s '\n' ' ')
	do
		apturl=$(jq -r '."apt-repos"."additional"['$k']."url"' $MANIFEST)
		aptdist=$(jq -r '."apt-repos"."additional"['$k']."distribution"' $MANIFEST)
		aptcomp=$(jq -r '."apt-repos"."additional"['$k']."component"' $MANIFEST)
		aptkey=$(jq -r '."apt-repos"."additional"['$k']."key"' $MANIFEST)
		echo "Adding additional repo: $apturl"
		cp $aptkey ${CHROOT_BASEDIR}/apt.key || exit_err "Failed copying repo apt key"
		chroot ${CHROOT_BASEDIR} apt-key add /apt.key || exit_err "Failed adding apt-key"
		rm ${CHROOT_BASEDIR}/apt.key
		echo "deb $apturl $aptdist $aptcomp" >> ${CHROOT_BASEDIR}/etc/apt/sources.list

	done

	# If not building a cd environment
	if [ -z "$CDBUILD" ] ; then
		check_basechroot_changed
	fi

	# Update apt
	chroot ${CHROOT_BASEDIR} apt update || exit_err "Failed apt update"

	# Put our local package up at the top of the foodchain
	mv ${CHROOT_BASEDIR}/etc/apt/sources.list ${CHROOT_BASEDIR}/etc/apt/sources.list.prev || exit_err "mv"
	echo "deb [trusted=yes] file:/packages /" > ${CHROOT_BASEDIR}/etc/apt/sources.list || exit_err "Failed local deb repo"
	cat ${CHROOT_BASEDIR}/etc/apt/sources.list.prev >> ${CHROOT_BASEDIR}/etc/apt/sources.list || exit_err "cat"
	rm ${CHROOT_BASEDIR}/etc/apt/sources.list.prev


	umount -f ${CHROOT_BASEDIR}/proc
	umount -f ${CHROOT_BASEDIR}/sys

	save_build_cache "${CACHENAME}"

	return 0
}

restore_build_cache() {
	if [ ! -d "${CHROOT_BASEDIR}" ] ; then
		mkdir -p ${CHROOT_BASEDIR}
	fi
	echo "Restoring CHROOT_BASEDIR for runs..."
	unsquashfs -f -d ${CHROOT_BASEDIR} ${CACHE_DIR}/basechroot-${1}.squashfs || exit_err "Failed unsquashfs"
}

save_build_cache() {
	if [ ! -d "${CACHE_DIR}" ] ; then
		mkdir -p ${CACHE_DIR}
	fi
	echo "Caching CHROOT_BASEDIR for future runs..."
	mksquashfs ${CHROOT_BASEDIR} ${CACHE_DIR}/basechroot-${1}.squashfs || exit_err "Failed squashfs"
}

check_basechroot_changed() {
	BASEHASH=$(chroot ${CHROOT_BASEDIR} apt list --installed 2>/dev/null | sha256sum | awk '{print $1}')
	if [ -e "${HASH_DIR}/.basechroot.hash" ] ; then
		if [ "$(cat ${HASH_DIR}/.basechroot.hash)" != "$BASEHASH" ] ; then
			echo "Upstream repository changes detected. Rebuilding all packages..."
			rm ${HASH_DIR}/*.hash
			rm ${PKG_DIR}/*.deb 2>/dev/null
			rm ${PKG_DIR}/*.udeb 2>/dev/null
		fi
	fi
	echo "$BASEHASH" > ${HASH_DIR}/.basechroot.hash
}

del_bootstrapdir() {
	echo "Removing package build chroot"
	umount -f ${CHROOT_BASEDIR}/proc 2>/dev/null
	umount -f ${CHROOT_BASEDIR}/sys 2>/dev/null
	umount -f ${CHROOT_BASEDIR} 2>/dev/null
	umount -Rf ${CHROOT_BASEDIR} 2>/dev/null
	rmdir ${CHROOT_BASEDIR} 2>/dev/null
	umount -Rf ${TMPFS} 2>/dev/null
	rmdir ${TMPFS} 2>/dev/null
}

del_overlayfs() {

	umount -f ${DPKG_OVERLAY}/packages 2>/dev/null
	umount -f ${DPKG_OVERLAY}/proc 2>/dev/null
	umount -f ${DPKG_OVERLAY}/sys 2>/dev/null
	umount -f ${DPKG_OVERLAY} 2>/dev/null
	umount -Rf ${DPKG_OVERLAY} 2>/dev/null
	rm -rf ${DPKG_OVERLAY} 2>/dev/null
	rm -rf ${CHROOT_OVERLAY} 2>/dev/null
	rm -rf ${WORKDIR_OVERLAY} 2>/dev/null
}

mk_overlayfs() {

	# Create a new overlay directory
	mkdir -p ${CHROOT_OVERLAY}
	mkdir -p ${DPKG_OVERLAY}
	mkdir -p ${WORKDIR_OVERLAY}
	mount -t overlay -o lowerdir=${CHROOT_BASEDIR},upperdir=${CHROOT_OVERLAY},workdir=${WORKDIR_OVERLAY} none ${DPKG_OVERLAY}/ || exit_err "Failed overlayfs"
	mount proc ${DPKG_OVERLAY}/proc -t proc || exit_err "Failed mount proc"
	mount sysfs ${DPKG_OVERLAY}/sys -t sysfs || exit_err "Failed mount sysfs"
	mkdir -p ${DPKG_OVERLAY}/packages || exit_err "Failed mkdir /packages"
	mount --bind ${PKG_DIR} ${DPKG_OVERLAY}/packages || exit_err "Failed mount --bind /packages"
}

build_deb_packages() {
	echo "`date`: Creating debian bootstrap directory: (${LOG_DIR}/bootstrap_chroot.log)"
	make_bootstrapdir >${LOG_DIR}/bootstrap_chroot.log 2>&1
	if [ ! -d "${LOG_DIR}/packages" ] ; then
		mkdir -p ${LOG_DIR}/packages
	fi


	for k in $(jq -r '."sources" | keys[]' ${MANIFEST} 2>/dev/null | tr -s '\n' ' ')
	do
		del_overlayfs
		mk_overlayfs

		NAME=$(jq -r '."sources"['$k']."name"' ${MANIFEST})
		PREBUILD=$(jq -r '."sources"['$k']."prebuildcmd"' ${MANIFEST})
		if [ ! -d "${SOURCES}/${NAME}" ] ; then
			exit_err "Missing sources for ${NAME}, did you forget to run 'make checkout'?"
		fi
		if [ "$PREBUILD" = "null" ] ; then
			unset PREBUILD
		fi

		# Check if we need to rebuild this package
		SOURCEHASH=$(cd ${SOURCES}/${NAME} && git rev-parse --verify HEAD)
		if [ -e "${HASH_DIR}/${NAME}.hash" ] ; then
			if [ "$(cat ${HASH_DIR}/${NAME}.hash)" = "$SOURCEHASH" ] ; then
				if [ $(cd ${SOURCES}/${NAME} >/dev/null && git diff-files --quiet --ignore-submodules >/dev/null ; echo $?) -eq 0 ] ; then
					echo "Skipping [$NAME] - No changes detected"
					continue
				fi
			fi
		fi

		# Do the build now
		echo "`date`: Building package [$NAME] (${LOG_DIR}/packages/${NAME}.log)"
		build_dpkg "$NAME" "$PREBUILD" >${LOG_DIR}/packages/${NAME}.log 2>&1

		# Save the build hash
		echo "$SOURCEHASH" > ${HASH_DIR}/${NAME}.hash

		del_overlayfs
	done

	# Before we wipe the bootstrap directory, lets build fresh ZFS kernel modules
	ls ${PKG_DIR}/zfs-modules-*.deb >/dev/null 2>/dev/null
	if [ $? -ne 0 ] ; then
		mk_overlayfs
		echo "`date`: Building package [zfs-modules] (${LOG_DIR}/packages/zfs-modules.log)"
		build_zfs_modules >${LOG_DIR}/packages/zfs-modules.log 2>&1
		del_overlayfs
	else
		echo "Skipping [zfs-modules] - No changes detected"
	fi

	del_bootstrapdir
	return 0
}

build_dpkg() {
	if [ -d "${DPKG_OVERLAY}/packages/Packages.gz" ] ; then
		chroot ${DPKG_OVERLAY} apt update || exit_err "Failed apt update"
	fi
	deflags="-us -uc -b"
	cp -r ${SOURCES}/${1} ${DPKG_OVERLAY}/dpkg-src || exit_err "Failed to copy sources"
	if [ -e "${DPKG_OVERLAY}/dpkg-src/debian/control" ] ; then
		subdir="/dpkg-src"
		pkgdir="/"
	elif [ -e "${DPKG_OVERLAY}/dpkg-src/debian/debian/control" ] ; then
		subdir="/dpkg-src/debian"
		pkgdir="/dpkg-src"
	else
		exit_err "Missing debian/control file for $1"
	fi

	chroot ${DPKG_OVERLAY} /bin/bash -c "cd $subdir && mk-build-deps --build-dep" || exit_err "Failed mk-build-deps"
	chroot ${DPKG_OVERLAY} /bin/bash -c "cd $subdir && apt install -y ./*.deb" || exit_err "Failed install build deps"
	# Check for a prebuild command
	if [ -n "$2" ] ; then
		chroot ${DPKG_OVERLAY} /bin/bash -c "cd $subdir && $2" || exit_err "Failed to prebuild"
	fi
	chroot ${DPKG_OVERLAY} /bin/bash -c "cd $subdir && debuild $deflags" || exit_err "Failed to build package"

	# Move out the resulting packages
	echo "Copying finished packages"

	mv ${DPKG_OVERLAY}${pkgdir}/*.deb ${PKG_DIR}/ 2>/dev/null
	mv ${DPKG_OVERLAY}${pkgdir}/*.udeb ${PKG_DIR}/ 2>/dev/null

	# Update the local APT repo
	echo "Building local APT repo Packages.gz..."
	chroot ${DPKG_OVERLAY} /bin/bash -c 'cd /packages && dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz'
}

build_zfs_modules() {

	chroot ${DPKG_OVERLAY} apt install -y locales || exit_err "Failed apt install locales"
	chroot ${DPKG_OVERLAY} apt install -y linux-image-amd64 || exit_err "Failed apt install linux-image-amd64"
	chroot ${DPKG_OVERLAY} apt install -y debhelper || exit_err "Failed apt install debhelper"

	# Build the .deb package now
	cp scripts/mk-zfs-modules ${DPKG_OVERLAY}/build.sh
	chroot ${DPKG_OVERLAY} sh /build.sh || exit_err "Failed building zfs-modules"

	mv ${DPKG_OVERLAY}/*.deb ${PKG_DIR}/ 2>/dev/null
	mv ${DPKG_OVERLAY}/*.udeb ${PKG_DIR}/ 2>/dev/null
}

checkout_sources() {
	if [ ! -d "$SOURCES" ] ; then
		mkdir -p ${SOURCES}
	fi

	for k in $(jq -r '."sources" | keys[]' ${MANIFEST} 2>/dev/null | tr -s '\n' ' ')
	do
		#eval "CHECK=\$$k"
		NAME=$(jq -r '."sources"['$k']."name"' ${MANIFEST})
		REPO=$(jq -r '."sources"['$k']."repo"' ${MANIFEST})
		BRANCH=$(jq -r '."sources"['$k']."branch"' ${MANIFEST})
		if [ -z "$NAME" ] ; then exit_err "Invalid NAME: $NAME" ; fi
		if [ -z "$REPO" ] ; then exit_err "Invalid REPO: $REPO" ; fi
		if [ -z "$BRANCH" ] ; then exit_err "Invalid BRANCH: $BRANCH" ; fi

		if [ -d ${SOURCES}/${NAME} ] ; then
			rm -r ${SOURCES}/${NAME}
		fi
		git clone --depth=1 -b ${BRANCH} ${REPO} ${SOURCES}/${NAME}
																done
}

install_iso_packages() {
	mount proc ${CHROOT_BASEDIR}/proc -t proc
	mount sysfs ${CHROOT_BASEDIR}/sys -t sysfs
	mkdir -p ${CHROOT_BASEDIR}/packages
	echo "/dev/disk/by-label/TRUENAS / iso9660 loop 0 0" > ${CHROOT_BASEDIR}/etc/fstab

	mount --bind ${PKG_DIR} ${CHROOT_BASEDIR}/packages || exit_err "Failed mount --bind /packages"
	chroot ${CHROOT_BASEDIR} apt update || exit_err "Failed apt update"

	for package in $(jq -r '."iso-packages" | values[]' $MANIFEST | tr -s '\n' ' ')
	do
		chroot ${CHROOT_BASEDIR} apt install -y $package || exit_err "Failed apt install $package"
	done

	#chroot ${CHROOT_BASEDIR} /bin/bash
	mkdir -p ${CHROOT_BASEDIR}/boot/grub
	cp scripts/grub.cfg ${CHROOT_BASEDIR}/boot/grub/grub.cfg || exit_err "Failed copying grub.cfg"
	umount -f ${CHROOT_BASEDIR}/packages
	umount -f ${CHROOT_BASEDIR}/proc
	umount -f ${CHROOT_BASEDIR}/sys
}

make_iso_file() {
	if [ -d "${RELEASE_DIR}/release" ] ; then
		rm -rf ${RELEASE_DIR}
	fi

	# Set default PW to root
	chroot ${CHROOT_BASEDIR} /bin/bash -c 'echo -e "root\nroot" | passwd root'

	# Copy the CD files
	cp conf/cd-files/getty@.service ${CHROOT_BASEDIR}/lib/systemd/system/ || exit_err "Failed copy of getty@"
	cp conf/cd-files/bash_profile ${CHROOT_BASEDIR}/root/.bash_profile || exit_err "Failed copy of bash_profile"

	# Drop to shell for debugging
	#chroot ${CHROOT_BASEDIR} /bin/bash

	# Create the CD assembly dir
	rm -rf ${CD_DIR}
	mkdir -p ${CD_DIR}

	# Prune away the fat
	prune_cd_basedir

	# Lets make squashfs now
	mksquashfs ${CHROOT_BASEDIR} ./tmp/truenas.squashfs
	mkdir -p ${CD_DIR}/live
	mv ./tmp/truenas.squashfs ${CD_DIR}/live/filesystem.squashfs

	# Copy over boot and kernel before rolling CD
	cp -r ${CHROOT_BASEDIR}/boot ${CD_DIR}/boot
	cp -r ${CHROOT_BASEDIR}/init* ${CD_DIR}/
	cp -r ${CHROOT_BASEDIR}/vmlinuz* ${CD_DIR}/

	mkdir -p ${RELEASE_DIR}
	grub-mkrescue -o ${RELEASE_DIR}/TrueNAS-SCALE.iso ${CD_DIR} \
		|| exit_err "Failed grub-mkrescue"
	sha256sum ${RELEASE_DIR}/TrueNAS-SCALE.iso > ${RELEASE_DIR}/TrueNAS-SCALE.iso.sha256 || exit_err "Failed sha256"
}

prune_cd_basedir() {
	rm -rf ${CHROOT_BASEDIR}/var/cache/apt
}

make_iso() {
	echo "`date`: Bootstrapping CD chroot [ISO] (${LOG_DIR}/cdrom-bootstrap.log)"
	make_bootstrapdir "CD" >${LOG_DIR}/cdrom-bootstrap.log 2>&1
	echo "`date`: Installing packages [ISO] (${LOG_DIR}/cdrom-packages.log)"
	install_iso_packages >${LOG_DIR}/cdrom-packages.log 2>&1
	echo "`date`: Creating ISO file [ISO] (${LOG_DIR}/cdrom-iso.log)"
	make_iso_file >${LOG_DIR}/cdrom-iso.log 2>&1
	del_bootstrapdir
	echo "Success! CD/USB: ${RELEASE_DIR}/TrueNAS-SCALE.iso"
}

preflight_check

case $1 in
	iso) make_iso ;;
	checkout) checkout_sources ;;
	packages) build_deb_packages ;;
	clean) cleanup ;;
	*) exit_err "Invalid build option!" ;;
esac

exit 0