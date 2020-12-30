#/bin/sh
# The purpose of this script is to fetch and install the tss2 stack from
# source code, so that developers can easily develop tpm2 based application.
# It will install dependencies, download source code of ibmswtpm2, tpm2-tss
# and tpm2-tools, build and deploy them, and then dry-run the tpm2-tools
# with the simulator and the physical tpm device to make sure things working.
#
# So far, support only Ubuntu and openEuler.

workdir=`mktemp -t -d tmpd.XXXXXX`
osv=`grep "\<NAME=" /etc/os-release | awk -F\" '{print $2}'`

# install deps
ubuntu_deps="autoconf-archive libcmocka0 libcmocka-dev procps iproute2 build-essential git pkg-config gcc libtool automake libssl-dev uthash-dev autoconf doxygen libjson-c-dev libini-config-dev libcurl4-openssl-dev uuid-dev python-yaml pandoc"
openeuler_deps="curl-devel gcc-c++ gdb git libgcrypt-devel libtool openssl-devel autoconf-archive libcmocka-devel autoconf automake babeltrace cmake-filesystem e2fsprogs-devel emacs-filesystem gdb-headless keyutils-libs-devel krb5-devel libgpg-error-devel libselinux-devel libsepol-devel libstdc++-devel libverto-devel m4 pcre2-devel perl-Error perl-Git perl-TermReadKey tar zlib-devel libcmocka pkgconf systemd procps iproute uthash-devel doxygen uuid-devel python-yaml json-c-devel"
case $osv in
    Ubuntu) sudo apt-get remove libtss2-esys0 tpm2-tools tpm2-tss tpm2-abrmd; sudo apt-get install $ubuntu_deps;;
    openEuler) sudo dnf remove tpm2-tools tpm2-tss tpm2-abrmd; sudo dnf groupinstall -y "Development Tools"; sudo dnf install -y $openeuler_deps;;
    *) echo $osv is not supported yet; exit;;
esac

# download, build and running ibmswtpm2
cd $workdir
ibmtpm_w_ver=ibmtpm1637
wget https://udomain.dl.sourceforge.net/project/ibmswtpm2/$ibmtpm_w_ver.tar.gz
mkdir $ibmtpm_w_ver; cd $ibmtpm_w_ver; tar xf ../$ibmtpm_w_ver.tar.gz
kill `pidof tpm_server`
cd src; make && ./tpm_server&

# download, build and install tpm2-tss
cd $workdir
git clone https://github.com/tpm2-software/tpm2-tss
cd tpm2-tss
./bootstrap && ./configure --prefix=/usr && make -j5 && sudo make install && sudo ldconfig
sudo chmod a+rx /usr/lib/pkgconfig
export PKG_CONFIG_PATH=/usr/lib/pkgconfig
sudo chmod a+rx /usr/include/tss2

# download, build and install tpm2-tools
cd $workdir
git clone https://github.com/tpm2-software/tpm2-tools
cd tpm2-tools
case $osv in
    openEuler)
        git checkout 4.1.3;; # TODO: latest version has dependencies issue in openEuler.
    *);;
esac
./bootstrap && ./configure --prefix=/usr && make -j5 && sudo make install #install-man

# configure and run tpm2-tools
cd $workdir
export TPM2TOOLS_TCTI="mssim:host=localhost,port=2321"
tpm2_startup -c
tpm2_getrandom --hex 32
tpm2_getcap -l
tpm2_getcap pcrs
tpm2_pcrread
tpm2_pcrextend 4:sha1=f1d2d2f924e986ac86fdf7b36c94bcdf32beec15,sha256=b5bb9d8014a0f9b1d61e21e796d78dccdf1352f23cd32812f4850b878ae4944c
tpm2_pcrread sha1
tpm2_pcrread sha256
tpm2_pcrread sha1:4+sha256:4

#try with h/w tpm
sudo tpm2_getrandom -T device:/dev/tpm0 --hex 32

