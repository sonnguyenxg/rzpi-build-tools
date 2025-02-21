#!/bin/bash

ARM_GCC_VERSION="SDK"
if [ "${ARM_GCC_VERSION}" == "SDK" ] ; then
source /opt/poky/3.1.14/environment-setup-aarch64-poky-linux
else
## gcc 10.3 default
TOOLCHAIN_PATH=$HOME/toolchain/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu/bin
export PATH=$TOOLCHAIN_PATH:$PATH
export ARCH=arm64
export CROSS_COMPILE=aarch64-none-linux-gnu-
fi

UBOOT_DIR="u-boot"
TFA_DIR="rz-atf"

UBOOT_GIT_URL="git@github.com:sonnguyenxg/u-boot.git"
TFA_GIT_URL="git@github.com:sonnguyenxg/rz-atf.git"

UBOOT_BRANCH="dunfell/rz-sbc"
TFA_BRANCH="dunfell/rz-sbc"

#===============MAIN BODY NO NEED TO CHANGE=========================
help() {
bn=$(basename $0)
cat << EOF
usage :  $bn <option>
options:
  -h        display this help and exit
  -rzpi       build boot image for the RZPI Novtech board
  -v2l       build boot image for the RZV2L board
  -clean    clean the build files for all projects
  -g        get all the code to build boot image
Example:
    ./$bn -rz
    ./$bn -clean
EOF
}

check_host_require(){
	# check required applications are installed
	command -v gcc > /dev/null
	if [ $? -eq 1 ]; then
		log_error "Command 'gcc' not found, but can be installed with:"
		log_info "sudo apt install gcc"
		exit
	fi

	dpkg -l | grep libssl-dev > /dev/null
	if [ ! $? -eq 0 ]; then
		log_error "Package 'libssl-dev' not found, but can be installed with:"
		log_info "sudo apt install libssl-dev"
		exit
	fi
	
	dpkg -l | grep bison > /dev/null
	if [ ! $? -eq 0 ]; then
		log_error "Package 'bison' not found, but can be installed with:"
		log_info "sudo apt install bison flex"
		exit
	fi

	command -v ${CROSS_COMPILE}gcc > /dev/null
	if [ $? -ne 0 ]; then
		log_error "ERROR: ${CROSS_COMPILE}gcc not found,"
		log_info "please install the toolchain first and export the enviroment like:"
		log_info "export PATH=\$PATH:your_toolchain_path"
		exit
	fi
}

log_error(){
    local string=$1
    echo -ne "\e[31m $string \e[0m\n"
}
log_info(){
    local string=$1
    echo -ne "\e[32m $string \e[0m\n"
}

mk_clean()
{
    cd ${WORKPWD}
    make distclean -C ${UBOOT_DIR}/
    make distclean -C ${TFA_DIR}/
    rm ${TFA_DIR}/bl2_bp*
    rm ${TFA_DIR}/fip*
    rm ${TFA_DIR}/u-boot.bin
    rm *.srec
}

mk_getcode()
{
    cd ${WORKPWD}/

	#download uboot
	if [ ! -d {UBOOT_DIR} ];then
	    git clone $UBOOT_GIT_URL ${UBOOT_DIR}
	    git -C ${UBOOT_DIR} checkout ${UBOOT_BRANCH}
	fi

	#download trusted-firmware-a
	if [ ! -d {TFA_GIT_URL} ];then
	    git clone $TFA_GIT_URL ${TFA_DIR}
	    git -C ${TFA_DIR} checkout ${TFA_BRANCH}
	fi

    #download extra tool code
	if [ ! -d bootparameter ];then
		mkdir bootparameter
		cd bootparameter
		wget https://raw.githubusercontent.com/renesas-rz/meta-rzg2/dunfell/rzg2l/recipes-bsp/firmware-pack/bootparameter/bootparameter.c
	fi
	cd ${WORKPWD}/
}

mk_uboot()
{
    cd ${WORKPWD}/${UBOOT_DIR}/
    if [ "${SOC_TYPE}" == "rzpi" ] ; then
		make clean
		make distclean
		make rzpi_defconfig
	elif [ "${SOC_TYPE}" == "v2l" ] ; then
		make clean
		make distclean
		make smarc-rzv2l_defconfig
	else
		make smarc-rzv2l_defconfig
	fi
	make -j16
	[ $? -ne 0 ] && log_error "Failed in ${UBOOT_DIR} ..." && exit
}

mk_atf()
{
    cd ${WORKPWD}/${TFA_DIR}/
    case ${SOC_TYPE} in
		rzpi)
			echo "build atf for rzpi";
			unset CFLAGS LDFLAGS;
			make clean;
			make distclean;
			make -j16 PLAT=g2l BOARD=sbc_1 all;;
		v2l)
			echo "build atf for rzv2l";
			unset CFLAGS LDFLAGS;
			make clean;
			make distclean;
			make -j16 PLAT=v2l BOARD=smarc_pmic_2 bl2 bl31;;
	esac
	[ $? -ne 0 ] && log_error "Failed in ${TFA_DIR} ..." && exit
}

check_extra_tools()
{
    cd ${WORKPWD}/${TFA_DIR}/
	if [ ! -x fiptool ];then
		make -C tools/fiptool/ fiptool
		cp -af tools/fiptool/fiptool ./
		echo "copy fiptool "
	fi
	
	if [ ! -x bootparameter ];then
		cd ${WORKPWD}/bootparameter/
		gcc bootparameter.c -o bootparameter
		cd ${WORKPWD}/
		cp -af bootparameter/bootparameter ${TFA_DIR}/
		echo "copy bootparameter "
	fi
}

mk_bootimage()
{
	check_extra_tools
	cd ${WORKPWD}/${TFA_DIR}

	## BUILDMODE=debug
	BUILDMODE=release
	# Create bl2_bp.bin
	./bootparameter build/${SOC_TYPE}/${BUILDMODE}/bl2.bin bl2_bp.bin
	cat build/${SOC_TYPE}/${BUILDMODE}/bl2.bin >> bl2_bp.bin

	# Create fip.bin
	cp ../${UBOOT_DIR}/u-boot.bin ./
	./fiptool create --align 16 --soc-fw build/${SOC_TYPE}/${BUILDMODE}/bl31.bin --nt-fw ./u-boot.bin fip.bin

	# cp ../${UBOOT_DIR}/u-boot-nodtb.bin ./
	# ./fiptool create --align 16 --soc-fw build/${SOC_TYPE}/${BUILDMODE}/bl31.bin --nt-fw ./u-boot-nodtb.bin fip.bin

	# Convert to srec
	objcopy -O srec --adjust-vma=0x00011E00 --srec-forceS3 -I binary bl2_bp.bin bl2_bp.srec
	objcopy -I binary -O srec --adjust-vma=0x0000 --srec-forceS3 fip.bin fip.srec
	cd ${WORKPWD}
}

function main_process(){
	SOC_TYPE=$1
	WORKPWD=$(pwd)

    [ $# -eq 0 ] && help && exit
	while [ $# -gt 0 ]; do
		case $1 in
			-h|--help) help; exit ;;
			-v|--version) echo "version 1.03" ; exit ;;
			-cl*)  mk_clean ; exit ;;
			-g)    mk_getcode ; exit ;;
			-rzpi) SOC_TYPE="rzpi"; echo ${SOC_TYPE};;
			-v2l) SOC_TYPE="v2l"; echo ${SOC_TYPE};;
			*)  log_error "-- invalid option -- "; help; exit;;
		esac
		shift
	done

	check_host_require
	if [[ ! -d $UBOOT_DIR ]] || [[ ! -d $TFA_DIR ]] ;then
        log_error "Error: No found source code "
        log_info "use the follow command to download the all code:"
        log_info "./$(basename $0) -g"
        exit
	fi

	cd ${WORKPWD}
	# mk_uboot
	# mk_atf
	
	mk_bootimage
	cp -f ${WORKPWD}/${TFA_DIR}/bl2_bp.srec ./bl2_bp_${SOC_TYPE}.srec
	cp -f ${WORKPWD}/${TFA_DIR}/fip.srec ./fip_${SOC_TYPE}.srec
	echo ""
	echo "---Finished--- the boot image as follow:"
	log_info bl2_bp_${SOC_TYPE}.srec
	log_info fip_${SOC_TYPE}.srec
}

#--start--------
main_process $*

exit
#---- end ------
