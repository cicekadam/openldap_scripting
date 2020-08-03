#!/bin/bash

# A function to replace user inputs with the variables in the additional files
expandVarsStrict(){ 
  local line lineEscaped
  while IFS= read -r line || [[ -n $line ]]; do  # the `||` clause ensures that the last line is read even if it doesn't end with \n
    # Escape ALL chars. that could trigger an expansion..
    IFS= read -r -d '' lineEscaped < <(printf %s "$line" | tr '`([$' '\1\2\3\4')
    # ... then selectively reenable ${ references
    lineEscaped=${lineEscaped//$'\4'{/\${}
    # Finally, escape embedded double quotes to preserve them.
    lineEscaped=${lineEscaped//\"/\\\"}
    eval "printf '%s\n' \"$lineEscaped\"" | tr '\1\2\3\4' '`([$'
  done
}
# Taken from https://stackoverflow.com/a/40167919 Thanks a lot to mklement0

# Requesting the version wanted to install
echo "Installing and Configurin OpenLdap Server"
echo "Enter which version you want to install (e.g 2.4.48)(Leave it blank if you are not sure): "
read VER
if [[ !$VER ]]; then
	VER="2.4.48"
fi


# Installing requirements
yum install -y cyrus-sasl-devel make libtool autoconf libtool-ltdl-devel openssl-devel libdb-devel tar gcc perl perl-devel wget vim

# Creating a user to prevent using root
useradd -r -M -d /var/lib/openldap -u 55 -s /usr/sbin/nologin ldap

# Downloading the files and compiling them
wget ftp://ftp.openldap.org/pub/OpenLDAP/openldap-release/openldap-$VER.tgz
tar xzf openldap-$VER.tgz


./openldap-$VER/configure --prefix=/usr --sysconfdir=/etc --disable-static \
--enable-debug --with-tls=openssl --with-cyrus-sasl --enable-dynamic \
--enable-crypt --enable-spasswd --enable-slapd --enable-modules \
--enable-rlookups --enable-backends=mod --disable-ndb --disable-sql \
--disable-shell --disable-bdb --disable-hdb --enable-overlays=mod

make depend
make install

# Having user inpurs firs to fill additional files 
echo "Installation is done, now we are configuring OpenLdap Server"
echo "Enter your top level domain (e.g. com):"
read suffix3
if [[ !$suffix3 ]]; then
	suffix3="com"
fi

echo "Enter your domain (e.g. mydomain):"
read suffix2
if [[ !$suffix2 ]]; then
	suffix2="mydomain"
fi

echo "Enter your sub level domain (e.g. ldap):"
read suffix1
if [[ !$suffix1 ]]; then
	suffix1="com"
fi

echo "Now I need a password for root user of this directory service!"
rootpasswd=$(slappasswd)

while [ $? -ne 0 ]
do
	echo "Try again please."
	rootpasswd=$(slappasswd)
done


suffix="dc=$suffix1,dc=$suffix2,dc=$suffix3"


# Creating required directories and fixin permissions
mkdir /var/lib/openldap /etc/openldap/slapd.d
chown -R ldap:ldap /var/lib/openldap
chown root:ldap /etc/openldap/slapd.conf
chmod 640 /etc/openldap/slapd.conf

cp $(dirname $0)/systemd-service-file /etc/systemd/system/slapd.service
cp /usr/share/doc/sudo/schema.OpenLDAP  /etc/openldap/schema/sudo.schema
cp $(dirname $0)/sudo.ldif /etc/openldap/schema/sudo.ldif
mv /etc/openldap/slapd.ldif /etc/openldap/slapd.ldif.bak
cp $(dirname $0)/slapd.dif /etc/openldap/slapd.ldif

# To update the SLAPD database from the information provided on the SLAPD LDIF file above
slapadd -n 0 -F /etc/openldap/slapd.d -l /etc/openldap/slapd.ldif

# Ready to go
systemctl daemon-reload
systemctl enable --now slapd

# Enabling logs
ldapmodify -Y external -H ldapi:/// -f enable-ldap-log.ldif
echo "local4.* /var/log/slapd.log" >> /etc/rsyslog.conf
systemctl restart rsyslog

# Creating default rootdn and basedn
expandVarsStrict <<< $(cat $(dirname $0)/rootdn.ldif) > $HOME/rootdn.ldif
ldapadd -Y EXTERNAL -H ldapi:/// -f $HOME/rootdn.ldif

expandVarsStrict <<< $(cat $(dirname $0)/basedn.ldif) > $HOME/basedn.ldif
ldapadd -Y EXTERNAL -H ldapi:/// -f $HOME/basedn.ldif

# Creating binddn for ldap operations
echo "Now I need a password for BindDN user of this directory service!"
bindpasswd=$(slappasswd)

expandVarsStrict <<< $(cat $(dirname $0)/bindDNuser.ldif) > $HOME/bindDNuser.ldif
ldapadd -Y EXTERNAL -H ldapi:/// -f $HOME/bindDNuser.ldif


# Configuring SSL/TLS
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout \
/etc/pki/tls/ldapserver.key -out /etc/pki/tls/ldapserver.crt

chown ldap:ldap /etc/pki/tls/{ldapserver.crt,ldapserver.key}
ldapadd -Y EXTERNAL -H ldapi:/// -f $(dirname $0)/add-tls.ldif
echo "TLS_CACERT     /etc/pki/tls/ldapserver.crt" >> /etc/openldap/ldap.conf


# Configuring firewall tools
echo "Do you use firewalld (y/n): "
read answer

if [ $answer == "y" ]; then
	firewall-cmd --add-service={ldap,ldaps} --permanent
	firewall-cmd --reload
fi


