#!/bin/bash

print_help () {
  echo -e "./install.sh www_basedir user group"
  echo -e "\tbase_dir: The place where the web application will be put in"
  echo -e "\tuser:     User of the web application"
  echo -e "\tgroup:    Group of the web application"
}

# Ensure to be root
if [ "$EUID" -ne 0 ]; then
  echo "Please use sudo to run the script"
  exit
fi

# Ensure there are enought arguments
if [ "$#" -ne 3 ]; then
  print_help
  exit
fi


printf "\033[1m\n###################################### Installation Started #####################################\n"
sleep 2
printf "\033[1m\n######################################     OS Detection     #####################################\n"
# Detecting OS Distribution
OS=$(cat /etc/os-release | grep PRETTY_NAME | sed 's/"//g' | cut -f2 -d= | cut -f1 -d " ")
echo -e "# Detected: $OS #\r"
sleep 2
printf "\033[1m\n\n#################################### Installing Prerequisites ####################################\n"
printf "\033[1m#################################### This could take long time ####################################\n"
apt update && sudo apt upgrade -y

case $OS in
	Ubuntu)
    apt install -y openvpn apache2 mysql-server php php-mysql php-zip unzip git wget sed curl nodejs npm mc net-tools
		;;
	Raspbian)
		apt install -y openvpn apache2 mariadb-server php php-mysql php-zip unzip git wget sed curl nodejs npm mc
		;;
	*)
		echo "Can't detect OS distribution! you need to install prerequisites manully"
    exit
esac
npm install -g bower

# Ensure there are the prerequisites
for i in openvpn mysql php bower node unzip wget sed; do
  which $i > /dev/null
  if [ "$?" -ne 0 ]; then
    echo "$i is missing. Please install $i manually."
    exit
  fi
done

printf "\033[1m\n\n################################### Setting MySQL Configuration ####################################\n"
printf "\033[1m######################## Note the MySQL root password! you will need it soon ########################\n"
mysql_secure_installation


www=$1
user=$2
group=$3

openvpn_admin="$www/openvpn-admin"

# Check the validity of the arguments
if [ ! -d "$www" ] ||  ! grep -q "$user" "/etc/passwd" || ! grep -q "$group" "/etc/group" ; then
  print_help
  exit
fi

base_path=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )


printf "\n################## Server informations ##################\n"

read -p "Server Hostname/IP: " ip_server

read -p "OpenVPN protocol (tcp or udp) [tcp]: " openvpn_proto

if [[ -z $openvpn_proto ]]; then
  openvpn_proto="tcp"
fi

read -p "Port [1194]: " server_port

if [[ -z $server_port ]]; then
  server_port="1194"
fi

# Get root pass (to create the database and the user)
mysql_root_pass=""
status_code=1

while [ $status_code -ne 0 ]; do
  read -p "MySQL root password: " -s mysql_root_pass; echo
  echo "SHOW DATABASES" | mysql -u root --password="$mysql_root_pass" &> /dev/null
  status_code=$?
done

sql_result=$(echo "SHOW DATABASES" | mysql -u root --password="$mysql_root_pass" | grep -e "^openvpn-admin$")
# Check if the database doesn't already exist
if [ "$sql_result" != "" ]; then
  echo "The openvpn-admin database already exists."
  exit
fi


# Check if the user doesn't already exist
read -p "MySQL user name for OpenVPN-Admin (will be created): " mysql_user

echo "SHOW GRANTS FOR $mysql_user@localhost" | mysql -u root --password="$mysql_root_pass" &> /dev/null
if [ $? -eq 0 ]; then
  echo "The MySQL user already exists."
  exit
fi

read -p "MySQL user password for OpenVPN-Admin: " -s mysql_pass; echo

# TODO MySQL port & host ?


printf "\n################## Certificates informations ##################\n"

read -p "Key size (1024, 2048 or 4096) [2048]: " key_size

read -p "Root certificate expiration (in days) [3650]: " ca_expire

read -p "Certificate expiration (in days) [3650]: " cert_expire

read -p "Country Name (2 letter code) [US]: " cert_country

read -p "State or Province Name (full name) [California]: " cert_province

read -p "Locality Name (eg, city) [Mission Viejo]: " cert_city

read -p "Organization Name (eg, company) [Copyleft Certificate Co]: " cert_org

read -p "Organizational Unit Name (eg, section) [My Organizational Unit]: " cert_ou

read -p "Email Address [me@example.net]: " cert_email

read -p "Common Name (eg, your name or your server's hostname) [ChangeMe]: " key_cn


printf "\n################## Creating the certificates ##################\n"

# Get the rsa keys
EASYRSA_VERSION=$(curl -s https://api.github.com/repos/OpenVPN/easy-rsa/releases/latest | grep "tag_name" | cut -f2 -d "v" | sed 's/[",]//g')
EASYRSA_LOCATION=$(curl -s https://api.github.com/repos/OpenVPN/easy-rsa/releases/latest \
| grep "tag_name" \
| awk '{print "https://github.com/OpenVPN/easy-rsa/releases/download/" substr($2, 2, length($2)-3) "/EasyRSA-" substr($2, 3, length($2)-4) ".tgz"}') \
; curl -L -o easyrsa.tgz $EASYRSA_LOCATION

tar -xaf "easyrsa.tgz"
mv "EasyRSA-$EASYRSA_VERSION" /etc/openvpn/easy-rsa
rm "easyrsa.tgz"

cd /etc/openvpn/easy-rsa

if [[ ! -z $key_size ]]; then
  export EASYRSA_KEY_SIZE=$key_size
fi
if [[ ! -z $ca_expire ]]; then
  export EASYRSA_CA_EXPIRE=$ca_expire
fi
if [[ ! -z $cert_expire ]]; then
  export EASYRSA_CERT_EXPIRE=$cert_expire
fi
if [[ ! -z $cert_country ]]; then
  export EASYRSA_REQ_COUNTRY=$cert_country
fi
if [[ ! -z $cert_province ]]; then
  export EASYRSA_REQ_PROVINCE=$cert_province
fi
if [[ ! -z $cert_city ]]; then
  export EASYRSA_REQ_CITY=$cert_city
fi
if [[ ! -z $cert_org ]]; then
  export EASYRSA_REQ_ORG=$cert_org
fi
if [[ ! -z $cert_ou ]]; then
  export EASYRSA_REQ_OU=$cert_ou
fi
if [[ ! -z $cert_email ]]; then
  export EASYRSA_REQ_EMAIL=$cert_email
fi
if [[ ! -z $key_cn ]]; then
  export EASYRSA_REQ_CN=$key_cn
fi

# Init PKI dirs and build CA certs
./easyrsa init-pki
./easyrsa build-ca nopass
# Generate Diffie-Hellman parameters
./easyrsa gen-dh
# Genrate server keypair
./easyrsa build-server-full server nopass

# Generate shared-secret for TLS Authentication
openvpn --genkey --secret pki/ta.key


printf "\n################## Setup OpenVPN ##################\n"

# Copy certificates and the server configuration in the openvpn directory
cp /etc/openvpn/easy-rsa/pki/{ca.crt,ta.key,issued/server.crt,private/server.key,dh.pem} "/etc/openvpn/"
cp "$base_path/installation/server.conf" "/etc/openvpn/"
mkdir "/etc/openvpn/ccd"
sed -i "s/port 1194/port $server_port/" "/etc/openvpn/server.conf"

if [ $openvpn_proto = "udp" ]; then
  sed -i "s/proto tcp/proto $openvpn_proto/" "/etc/openvpn/server.conf"
fi

nobody_group=$(id -ng nobody)
sed -i "s/group nogroup/group $nobody_group/" "/etc/openvpn/server.conf"

printf "\n################## Setup firewall ##################\n"

# Make ip forwading and make it persistent
echo 1 > "/proc/sys/net/ipv4/ip_forward"
echo "net.ipv4.ip_forward = 1" >> "/etc/sysctl.conf"

# Get primary NIC device name
primary_nic=`route | grep '^default' | grep -o '[^ ]*$'`

# Iptable rules
iptables -I FORWARD -i tun0 -j ACCEPT
iptables -I FORWARD -o tun0 -j ACCEPT
iptables -I OUTPUT -o tun0 -j ACCEPT

iptables -A FORWARD -i tun0 -o $primary_nic -j ACCEPT
iptables -t nat -A POSTROUTING -o $primary_nic -j MASQUERADE
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $primary_nic -j MASQUERADE
iptables -t nat -A POSTROUTING -s 10.8.0.2/24 -o $primary_nic -j MASQUERADE


printf "\n################## Setup MySQL database ##################\n"

echo "CREATE DATABASE \`openvpn-admin\`" | mysql -u root --password="$mysql_root_pass"
echo "CREATE USER $mysql_user@localhost IDENTIFIED BY '$mysql_pass'" | mysql -u root --password="$mysql_root_pass"
echo "GRANT ALL PRIVILEGES ON \`openvpn-admin\`.*  TO $mysql_user@localhost" | mysql -u root --password="$mysql_root_pass"
echo "FLUSH PRIVILEGES" | mysql -u root --password="$mysql_root_pass"


printf "\n################## Setup web application ##################\n"

# Copy bash scripts (which will insert row in MySQL)
cp -r "$base_path/installation/scripts" "/etc/openvpn/"
chmod +x "/etc/openvpn/scripts/"*

# Configure MySQL in openvpn scripts
sed -i "s/USER=''/USER='$mysql_user'/" "/etc/openvpn/scripts/config.sh"
sed -i "s/PASS=''/PASS='$mysql_pass'/" "/etc/openvpn/scripts/config.sh"

# Create the directory of the web application
mkdir "$openvpn_admin"
cp -r "$base_path/"{index.php,sql,bower.json,.bowerrc,js,include,css,installation/client-conf} "$openvpn_admin"

# New workspace
cd "$openvpn_admin"

# Replace config.php variables
sed -i "s/\$user = '';/\$user = '$mysql_user';/" "./include/config.php"
sed -i "s/\$pass = '';/\$pass = '$mysql_pass';/" "./include/config.php"

# Replace in the client configurations with the ip of the server and openvpn protocol
for file in $(find -name client.ovpn); do
    sed -i "s/remote xxx\.xxx\.xxx\.xxx 1194/remote $ip_server $server_port/" $file
    echo "<ca>" >> $file
    cat "/etc/openvpn/ca.crt" >> $file
    echo "</ca>" >> $file
    echo "<tls-auth>" >> $file
    cat "/etc/openvpn/ta.key" >> $file
    echo "</tls-auth>" >> $file

  if [ $openvpn_proto = "udp" ]; then
    sed -i "s/proto tcp-client/proto udp/" $file
  fi
done

# Copy ta.key inside the client-conf directory
for directory in "./client-conf/gnu-linux/" "./client-conf/osx-viscosity/" "./client-conf/windows/"; do
  cp "/etc/openvpn/"{ca.crt,ta.key} $directory
done

# Install third parties
bower --allow-root install
chown -R "$user:$group" "$openvpn_admin"

printf "\033[1m\n\n################################### Setting Apache Configuration ####################################\n"
cp /etc/apache2/sites-available/000-default.conf /etc/apache2/sites-available/openvpn.conf
sed -i 's/\/var\/www\/html/\/var\/www\/openvpn-admin/g' /etc/apache2/sites-available/openvpn.conf
a2dissite 000-default
a2ensite openvpn
systemctl restart apache2

printf "\033[1m\n\n################################# Setting OpenVPN Configuration ####################################\n"
sed -i 's/explicit-exit-notify 1/# explicit-exit-notify 1/g' /etc/openvpn/server.conf
sed -i 's/80.67.169.12/8.8.8.8/g' /etc/openvpn/server.conf
sed -i 's/80.67.169.40/8.8.4.4/g' /etc/openvpn/server.conf
systemctl start openvpn@server

printf "\033[1m\n\n################################# Let'sEncrypt SSL Certificate ####################################\n"
printf "\033[1m###### NOTE: You need port 80 on the public facing side to be open and forwarded to this instance #####\n"
read -p "Do you wish to setup Let'sEncrypt SSL? (y/n)  " yn
case $yn in
    [Yy]*)
        read -p "provide the domain name without www.: " domain_name;
        apt install -y python-certbot-apache;
        certbot -n --apache -d $domain_name -d www.$domain_name --agree-tos -m $cert_email --no-redirect ;;
    [Nn]*)
        ;;
esac

printf "\033[1m\n################################################################################\n"
printf "\033[1m#################################### Finish ####################################\n"

echo -e "# Congratulations, you have successfully setup OpenVPN-Admin! #\r"
echo -e "and install the web application by visiting http://your-installation/index.php?installation\r"
echo "Please, report any issues here https://github.com/arvage/OpenVPN-Admin"
printf "\n################################################################################ \033[0m\n"
