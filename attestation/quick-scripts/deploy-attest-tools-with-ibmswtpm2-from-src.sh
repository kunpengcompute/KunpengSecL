#/bin/sh
# The purpose of this script is to fetch and install the attest-tools from
# source code, so that developers can easily utilize it to do attestation
# manually or automatically.
# It will install dependencies, download source code of ibmswtpm2, 
# build and deploy them, and then dry-run the attest-tools
# with the simulator and the physical tpm device to make sure things working.
#
# So far, support only Ubuntu and openEuler.

workdir=`mktemp -t -d tmpd.XXXXXX`
osv=`grep "\<NAME=" /etc/os-release | awk -F\" '{print $2}'`

# install deps
ubuntu_deps="autoconf-archive libcmocka0 libcmocka-dev procps iproute2 build-essential git pkg-config gcc libtool automake libssl-dev uthash-dev autoconf doxygen libjson-c-dev libini-config-dev libcurl4-openssl-dev uuid-dev pandoc help2man"
openeuler_deps="curl-devel gcc-c++ gdb git libgcrypt-devel libtool openssl-devel autoconf-archive libcmocka-devel autoconf automake babeltrace cmake-filesystem e2fsprogs-devel emacs-filesystem gdb-headless keyutils-libs-devel krb5-devel libgpg-error-devel libselinux-devel libsepol-devel libstdc++-devel libverto-devel m4 pcre2-devel perl-Error perl-Git perl-TermReadKey tar zlib-devel libcmocka pkgconf systemd procps iproute uthash-devel doxygen uuid-devel json-c-devel help2man"
case $osv in
    Ubuntu) sudo apt-get remove libtss2-esys0 tpm2-tools tpm2-tss tpm2-abrmd; sudo apt-get install $ubuntu_deps;;
    openEuler) sudo dnf remove tpm2-tools tpm2-tss tpm2-abrmd; sudo dnf groupinstall -y "Development Tools"; sudo dnf install -y $openeuler_deps;;
    *) echo $osv is not supported yet; exit;;
esac

# download, build and running ibmswtpm2
cd $workdir
ibmtpm_w_ver=ibmtpm1637
wget https://udomain.dl.sourceforge.net/project/ibmswtpm2/$ibmtpm_w_ver.tar.gz
#cp /tmp/$ibmtpm_w_ver.tar.gz $workdir
mkdir $ibmtpm_w_ver; cd $ibmtpm_w_ver; tar xf ../$ibmtpm_w_ver.tar.gz
kill `pidof tpm_server`
cd src; make && ./tpm_server -rm&

# download, build and install ibmtpm20tss
cd $workdir
git clone https://git.code.sf.net/p/ibmtpm20tss/tss ibmtpm20tss
#git clone /tmp/ibmtpm20tss-tss ibmtpm20tss
cd ibmtpm20tss; git checkout v1470; git switch -c branch-v1470
sed -i "s/\"US\"/\"DE\"/g" utils/createekcert.c
sed -i "s/\"NY\"/\"Bayern\"/g" utils/createekcert.c
sed -i "s/\"Yorktown\"/\"Muenchen\"/g" utils/createekcert.c
sed -i "s/\"IBM\"/\"Organization\"/g" utils/createekcert.c
sed -i "s/\"EK CA\"/\"CA\"/g" utils/createekcert.c
autoreconf -i && ./configure --disable-hwtpm --disable-tpm-1.2 && make -j5 && sudo make install
sudo cp utils/ekutils.h utils/cryptoutils.h /usr/local/include/ibmtss/
sudo ldconfig /usr/local/lib
sudo chmod a+rx /usr/local/include/ibmtss
sudo chmod -R a+r /usr/local/include/ibmtss

# download, build and install attest-tools
cd $workdir
git clone https://gitee.com/openeuler/attest-tools
#git clone /tmp/attest-tools
cd attest-tools; git submodule update --init --recursive
sed -i "s/\*attest_data, \*attest_data_path;/\*attest_data = NULL, \*attest_data_path = NULL;/g" ./src/attest_ra_client.c
autoreconf -i && ./configure && make -j5 && sudo make install
cd openssl_tpm2_engine; sh bootstrap.sh; ./configure && make -j5 && sudo make install
sudo ldconfig /usr/local/lib

#
# provisioning steps 
#
server_dir=$workdir/svr
client_dir=$workdir/clt
mkdir $server_dir; mkdir $client_dir

# Create an AK and request a certificate:

#   server side:
cd $server_dir

#   1. use existing CA or generate a new custom CA (key: cakey.pem, key password: 1234, cert: cacert.pem, use below field value while creating cert)
#        "DE",           /* 0 country */
#        "Bayern",       /* 1 state */
#        "Muenchen",     /* 2 locality*/
#        "Organization", /* 3 organization */
#        NULL,           /* 4 organization unit */
#        "CA",           /* 5 common name */
#        NULL            /* 6 email */

openssl genrsa -des3 -out cakey.pem -passout pass:1234 4096
echo Set input certificate attributes as below:
echo "\tCountry:	DE"
echo "\tState:		Bayern"
echo "\tLocality:	Muenchen"
echo "\tOrganization:	Organization"
echo "\tOrg Unit:	"
echo "\tCommon Name:	CA"
echo "\temail:	\n"
openssl req -x509 -new -nodes -key cakey.pem -passin pass:1234 -sha256 -days 1024 -out cacert.pem -subj "/C=DE/ST=Bayern/L=Muenchen/O=Organization/CN=CA"
mkdir demoCA
mkdir demoCA/newcerts
echo 01 >demoCA/serial
touch demoCA/index.txt

#   2. Update /etc/ssl/openssl.cnf:
#     unique_subject = no
#     copy_extensions = copy
case $osv in
    openEuler) sslconf_path=/etc/pki/tls/openssl.cnf;;
    Ubuntu) sslconf_path=/etc/ssl/openssl.cnf;;
    *);;
esac
sudo sed -i "s/#.*unique_subject.*= no/unique_subject\t= no/g" $sslconf_path
sudo sed -i "s/#.*copy_extensions.*=.*copy/copy_extensions\t= copy/g" $sslconf_path

#   3. create a key and certificate for the TLS server
openssl genrsa -out key.pem -passout pass:
openssl req -new -key key.pem -out cert.csr -subj "/C=DE/ST=Bayern/L=Muenchen/O=Organization/CN=`hostname`"
openssl x509 -req -in cert.csr -CA cacert.pem -CAkey cakey.pem -passin pass:1234 -CAcreateserial -out cert.pem

#   client side:
cd $client_dir

#   1. obtain the EK credential from TPM NVRAM: Make sure ibmtss/utils/createekcert.c contains expected rootIssuerEntriesRsa[] values. Copy the same CA key and CA cert from server to client.
#      software TPM case as an example
tssstartup
tsscreateekcert -cakey $server_dir/cakey.pem -capwd 1234
tsscreateprimary -hi o -st
tssevictcontrol -hi o -ho 80000000 -hp 81000001
tssflushcontext -ha 80000000
ekcert_read.sh -a sha256 -o ek_cert.pem

#   2. manually retrieve CA certificates of EK credential and add their path to the file 'list', one per line
echo $server_dir/cacert.pem > list

#   server side
cd $server_dir

#   1. generate verifier requirements:
attest_build_json -j reqs -k 'dummy|verify' -q '' req-dummy.json

#   2. server up:
kill `pidof attest_ra_server`
attest_ra_server -r req-dummy.json &

#   client side
cd $client_dir

#   1. ra client runs:
attest_ra_client -a -s localhost

# Create a TPM key not bound to any PCR, save attestation data to attest.txt and request a certificate:
#   client side
cd $client_dir
attest_ra_client -k -s localhost -r attest.txt

# Perform implicit RA:
#   server side
cd $server_dir
kill `pidof attest_tls_server`
attest_tls_server -k key.pem -c cert.pem -d cacert.pem -r req-dummy.json -S -V &

#   client side
cd $client_dir
attest_tls_client -k tpm_key.pem -c key_cert.pem -d $server_dir/cacert.pem -s `hostname` -e -a attest.txt

# Create a TPM key bound to PCRs 0-9,10 and request a certificate:
#   client side
#cd $client_dir
#   1. ensure that the client has a BIOS event log accessible from /sys/kernel/security/tpm0/binary_bios_measurements
#   2. ensure that the client has a IMA event log accessible from /sys/kernel/security/ima/binary_runtime_measurements and that no IMA policy is loaded
#   3. copy the name of the file containing the Privacy CA certificate to a file named 'list_privacy_ca'

#   server side
#cd $server_dir
#   1. create verifier requirement:
#attest_build_json -j reqs -k 'bios|verify' -q 'always-true' req-bios-ima.json
#attest_build_json -j reqs -k 'ima_boot_aggregate|verify' -q '' req-bios-ima.json
#   2. ra server up:
#attest_ra_server -r req-bios-ima.json -p 0,1,2,3,4,5,6,7,8,9,10

#   client side
#cd $client_dir
#   1. create the tpm key
#attest_ra_client -k -s localhost -r attest.txt -b -i -p 0,1,2,3,4,5,6,7,8,9,10

# Perform implicit RA:
#   server side
#cd $server_dir
#attest_tls_servers -k key.pem -c cert.pem -d cacert.pem -r req-bios-ima.json -S -V -p 0,1,2,3,4,5,6,7,8,9,10

#   client side
#cd $client_dir
#attest_tls_client -k tpm_key.pem -c key_cert.pem -d cacert.pem -s `hostname` -e -a attest.txt

# Perform explicit RA:
#   client side
#cd $client_dir
#attest_ra_client -q -s localhost -b -i -p 0,1,2,3,4,5,6,7,8,9,10

# Update PCR and perform again explicit RA:
#   client side
#tsspcrextend -halg sha1 -ha 10 -ic "test"
#attest_ra_client -q -s localhost -b -i -p 0,1,2,3,4,5,6,7,8,9,10

# This time RA should fail.
