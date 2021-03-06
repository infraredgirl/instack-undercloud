# Copyright 2015 Red Hat, Inc.
# All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

if count(hiera('ntp::servers')) > 0 {
  include ::ntp
}

# TODO Galara
class { 'mysql::server':
  override_options => {
    'mysqld' => {
      'bind-address' => hiera('controller_host')
    }
  }
}

# FIXME: this should only occur on the bootstrap host (ditto for db syncs)
# Create all the database schemas
# Example DSN format: mysql://user:password@host/dbname
$allowed_hosts = ['%',hiera('controller_host')]
$keystone_dsn = split(hiera('keystone::database_connection'), '[@:/?]')
class { 'keystone::db::mysql':
  user          => $keystone_dsn[3],
  password      => $keystone_dsn[4],
  host          => $keystone_dsn[5],
  dbname        => $keystone_dsn[6],
  allowed_hosts => $allowed_hosts,
}
$glance_dsn = split(hiera('glance::api::database_connection'), '[@:/?]')
class { 'glance::db::mysql':
  user          => $glance_dsn[3],
  password      => $glance_dsn[4],
  host          => $glance_dsn[5],
  dbname        => $glance_dsn[6],
  allowed_hosts => $allowed_hosts,
}
$nova_dsn = split(hiera('nova::database_connection'), '[@:/?]')
class { 'nova::db::mysql':
  user          => $nova_dsn[3],
  password      => $nova_dsn[4],
  host          => $nova_dsn[5],
  dbname        => $nova_dsn[6],
  allowed_hosts => $allowed_hosts,
}
$neutron_dsn = split(hiera('neutron::server::database_connection'), '[@:/?]')
class { 'neutron::db::mysql':
  user          => $neutron_dsn[3],
  password      => $neutron_dsn[4],
  host          => $neutron_dsn[5],
  dbname        => $neutron_dsn[6],
  allowed_hosts => $allowed_hosts,
}
$heat_dsn = split(hiera('heat_dsn'), '[@:/?]')
class { 'heat::db::mysql':
  user          => $heat_dsn[3],
  password      => $heat_dsn[4],
  host          => $heat_dsn[5],
  dbname        => $heat_dsn[6],
  allowed_hosts => $allowed_hosts,
}
$ceilometer_dsn = split(hiera('ceilometer::db::database_connection'), '[@:/?]')
class { 'ceilometer::db::mysql':
  user          => $ceilometer_dsn[3],
  password      => $ceilometer_dsn[4],
  host          => $ceilometer_dsn[5],
  dbname        => $ceilometer_dsn[6],
  allowed_hosts => $allowed_hosts,
}
$ironic_dsn = split(hiera('ironic::database_connection'), '[@:/?]')
class { 'ironic::db::mysql':
user          => $ironic_dsn[3],
password      => $ironic_dsn[4],
host          => $ironic_dsn[5],
dbname        => $ironic_dsn[6],
allowed_hosts => $allowed_hosts,
}

if $::osfamily == 'RedHat' {
  $rabbit_provider = 'yum'
} else {
  $rabbit_provider = undef
}

Class['rabbitmq'] -> Rabbitmq_vhost <| |>
Class['rabbitmq'] -> Rabbitmq_user <| |>
Class['rabbitmq'] -> Rabbitmq_user_permissions <| |>

# TODO Rabbit HA
class { 'rabbitmq':
  package_provider  => $rabbit_provider,
  config_cluster    => false,
  node_ip_address   => hiera('controller_host'),
}

rabbitmq_vhost { '/':
  provider => 'rabbitmqctl',
}
rabbitmq_user { ['nova','glance','neutron','ceilometer','heat']:
  admin    => true,
  password => hiera('rabbit_password'),
  provider => 'rabbitmqctl',
}

rabbitmq_user_permissions {[
  'nova@/',
  'glance@/',
  'neutron@/',
  'ceilometer@/',
  'heat@/',
]:
  configure_permission => '.*',
  write_permission     => '.*',
  read_permission      => '.*',
  provider             => 'rabbitmqctl',
}

# pre-install swift here so we can build rings
include ::swift

include ::keystone

#TODO: need a cleanup-keystone-tokens.sh solution here
keystone_config {
  'ec2/driver': value => 'keystone.contrib.ec2.backends.sql.Ec2';
}
file { [ '/etc/keystone/ssl', '/etc/keystone/ssl/certs', '/etc/keystone/ssl/private' ]:
  ensure  => 'directory',
  owner   => 'keystone',
  group   => 'keystone',
  require => Package['keystone'],
}
file { '/etc/keystone/ssl/certs/signing_cert.pem':
  content => hiera('keystone_signing_certificate'),
  owner   => 'keystone',
  group   => 'keystone',
  notify  => Service['keystone'],
  require => File['/etc/keystone/ssl/certs'],
}
file { '/etc/keystone/ssl/private/signing_key.pem':
  content => hiera('keystone_signing_key'),
  owner   => 'keystone',
  group   => 'keystone',
  notify  => Service['keystone'],
  require => File['/etc/keystone/ssl/private'],
}
file { '/etc/keystone/ssl/certs/ca.pem':
  content => hiera('keystone_ca_certificate'),
  owner   => 'keystone',
  group   => 'keystone',
  notify  => Service['keystone'],
  require => File['/etc/keystone/ssl/certs'],
}

# TODO: notifications, scrubber, etc.
include ::glance::api
include ::glance::registry
include ::glance::backend::file

class { 'nova':
  rabbit_hosts           => [hiera('controller_host')],
  glance_api_servers     => join([hiera('glance_protocol'), '://', hiera('controller_host'), ':', hiera('glance_port')]),
}

include ::nova::api
include ::nova::cert
include ::nova::conductor
include ::nova::consoleauth
include ::nova::vncproxy
include ::nova::scheduler

class {'neutron':
  rabbit_hosts => [hiera('controller_host')],
}

include ::neutron::server
include ::neutron::agents::dhcp

class { 'neutron::plugins::ml2':
  flat_networks        => split(hiera('neutron_flat_networks'), ','),
}

class { 'neutron::agents::ml2::ovs':
  bridge_mappings  => split(hiera('neutron_bridge_mappings'), ','),
}

# swift proxy
include ::memcached
include ::swift::proxy
include ::swift::proxy::proxy_logging
include ::swift::proxy::healthcheck
include ::swift::proxy::cache
include ::swift::proxy::keystone
include ::swift::proxy::authtoken
include ::swift::proxy::staticweb
include ::swift::proxy::ceilometer
include ::swift::proxy::ratelimit
include ::swift::proxy::catch_errors
include ::swift::proxy::tempauth
include ::swift::proxy::tempurl
include ::swift::proxy::formpost

# swift storage
class {'swift::storage::all':
  mount_check => str2bool(hiera('swift_mount_check'))
}
if(!defined(File['/srv/node'])) {
  file { '/srv/node':
    ensure  => directory,
    owner   => 'swift',
    group   => 'swift',
    require => Package['openstack-swift'],
  }
}
$swift_components = ['account', 'container', 'object']
swift::storage::filter::recon { $swift_components : }
swift::storage::filter::healthcheck { $swift_components : }

# Ceilometer
include ::ceilometer
include ::ceilometer::api
include ::ceilometer::db
include ::ceilometer::agent::notification
include ::ceilometer::agent::central
include ::ceilometer::alarm::notifier
include ::ceilometer::alarm::evaluator
include ::ceilometer::expirer
include ::ceilometer::collector
class { 'ceilometer::agent::auth':
  auth_url => join(['http://', hiera('controller_host'), ':5000/v2.0']),
}

Cron <| title == 'ceilometer-expirer' |> { command => "sleep $((\$(od -A n -t d -N 3 /dev/urandom) % 86400)) && ${::ceilometer::params::expirer_command}" }

# Heat
include ::heat
include ::heat::api
include ::heat::api_cfn
include ::heat::api_cloudwatch
include ::heat::engine

$snmpd_user = hiera('snmpd_readonly_user_name')
snmp::snmpv3_user { $snmpd_user:
  authtype => 'MD5',
  authpass => hiera('snmpd_readonly_user_password'),
}
class { 'snmp':
  agentaddress => ['udp:161','udp6:[::1]:161'],
  snmpd_config => [ join(['rouser ', hiera('snmpd_readonly_user_name')]), 'proc  cron', 'includeAllDisks  10%', 'master agentx', 'trapsink localhost public', 'iquerySecName internalUser', 'rouser internalUser', 'defaultMonitors yes', 'linkUpDownNotifications yes' ],
}

class { 'nova::compute':
  enabled => true,
}

nova_config {
  'DEFAULT/my_ip':                     value => $ipaddress;
  'DEFAULT/linuxnet_interface_driver': value => 'nova.network.linux_net.LinuxOVSInterfaceDriver';
}


class { 'nova::compute::ironic':
  admin_user        => 'ironic',
  admin_passwd    => hiera('ironic::api::admin_password'),
  admin_tenant_name => hiera('ironic::api::admin_tenant_name'),
  api_endpoint      => join(['http://', hiera('controller_host'), ':6385/v1']),
}

class { 'nova::network::neutron':
  neutron_admin_auth_url    => join(['http://', hiera('controller_host'), ':35357/v2.0']),
  neutron_url               => join(['http://', hiera('controller_host'), ':9696']),
  neutron_admin_password    => hiera('neutron::server::auth_password'),
  neutron_admin_tenant_name => hiera('neutron::server::auth_tenant'),
  neutron_region_name       => '',
}

include ::ironic::conductor

class { 'ironic':
  enabled_drivers => ['pxe_ipmitool', 'pxe_ssh']
}

class { 'ironic::api':
  host_ip => hiera('controller_host'),
}

ironic_config {
  'DEFAULT/my_ip':                value => hiera('controller_host');
  'glance/host':                  value => hiera('glance::api::bind_host');
}
