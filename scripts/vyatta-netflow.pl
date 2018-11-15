#!/usr/bin/perl
#
# Module: vyatta-netflow.pl
#
# **** License ****
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2009-2010 Vyatta, Inc.
# All Rights Reserved.
#
# Author: Stig Thormodsrud
# Date: June 2009
# Description: Script to configure netflow/sflow (pmacct).
#
# **** End License ****
#

use Getopt::Long;
use POSIX;

use lib '/opt/vyatta/share/perl5';
use Vyatta::Config;
use Vyatta::Netflow;
use Vyatta::Interface;
use Vyatta::Misc;

use warnings;
use strict;

# Default ports for netflow/sflow
my $def_nf_port = 2055;
my $def_sf_port = 6343;

# Default NFLOG table/chain
# There is some debate about whether we should hook into netfilter
# very early (raw, PRE_ROUTING) or late (filter, VYATTA_POST_FW_FWD_HOOK)
# For a default we will choose "early" - change it to "late" to use
# the other table/chain.
my $table_chain_entry = "early";

# NFLOG tuning parameters
#
# see http://wiki.pmacct.net/OfficialConfigKeys
my $nflog_range     = 64;  # number of bytes of the packet copied to NFLOG
my $nflog_threshold = 10;  # number of packets to batch to NFLOG
my $nflog_nl_sz     = (2 * 1024 * 1024);
my $nflog_nl_buf    = (4 * 1024); # 4KB, which is the default value
my $mempools	    = 169; # number of memory pool descriptors

#  (169+1) * sizeof(struct memory_pool_desc) = 4K

# Default pipe for plugins
my $default_pipe_size = 10; # 10 MiB

sub acct_get_table_chain {
    my %chain_table = ();
    if ($table_chain_entry eq "early") {
        %chain_table = ("VYATTA_CT_PREROUTING_HOOK" => "raw");
    } else {
        %chain_table = (
            "VYATTA_POST_FW_IN_HOOK"  => "filter",
            "VYATTA_POST_FW_FWD_HOOK" => "filter"
        );
    }
    return (\%chain_table);
}

sub acct_conf_globals {
    my ($config) = @_;

    my $output = '';
    my $pid_file  = acct_get_pid_file();
    my $pipe_file = acct_get_pipe_file();

    my $pipe_size = $config->returnValue('system flow-accounting buffer-size');
    $pipe_size = $default_pipe_size unless defined $pipe_size;
    $pipe_size = $pipe_size * 1024 * 1024;
    my $buffer_size = $pipe_size / 1024;

    $output .= "!\n! autogenerated by $0\n!\n";
    $output .= "daemonize: true\n";
    $output .= "promisc:   false\n";
    $output .= "pidfile:   $pid_file\n";
    $output .= "imt_path:  $pipe_file\n";
    $output .= "imt_mem_pools_number: $mempools\n";
    $output .= "uacctd_group: 2\n";
    $output .= "uacctd_nl_size: $nflog_nl_sz\n";
    $output .= "snaplen: $nflog_nl_buf\n";
    $output .= "refresh_maps: true\n";
    $output .= "pre_tag_map: /etc/pmacct/int_map\n";
    $output .= "aggregate: tag,src_mac,dst_mac,vlan,src_host,dst_host";
    $output .= ",src_port,dst_port,proto,tos,flows";

    if (-e '/etc/pmacct/networks.lst') {
        $output .= ",src_as,dst_as\n";
        $output .= "networks_file: /etc/pmacct/networks.lst\n";
    } else {
        $output .= "\n";
    }
    $output .= "plugin_pipe_size: $pipe_size\n";
    $output .= "plugin_buffer_size: $buffer_size\n";
    return $output;
}

my %timeout_hash = (
    'tcp-generic'     => 'tcp',
    'tcp-rst'         => 'tcp.rst',
    'tcp-fin'         => 'tcp.fin',
    'udp'             => 'udp',
    'icmp'            => 'icmp',
    'flow-generic'    => 'general',
    'max-active-life' => 'maxlife',
    'expiry-interval' => 'expint',
);

sub acct_get_collector_names {
    my ($config, $nf_sf) = @_;

    my @names;
    my $path = 'system flow-accounting';
    $config->setLevel("$path $nf_sf server");
    my @servers = $config->listNodes();
    if (scalar(@servers)) {
        foreach my $server (@servers) {
            $config->setLevel("$path $nf_sf server $server");
            my $port = $config->returnValue('port');
            $port = $def_nf_port if !defined $port;
            push @names, "$server-$port";
        }
    }
    return @names;
}

sub acct_get_netflow {
    my ($config) = @_;

    my $path   = 'system flow-accounting';
    my $output = undef;

    $config->setLevel($path);
    return $output if !$config->exists('netflow');

    $config->setLevel("$path netflow");
    my $version   = $config->returnValue('version');
    my $engine_id = $config->returnValue('engine-id');
    $engine_id = 0 if !defined $engine_id;
    my $sampling  = $config->returnValue('sampling-rate');
    my $source_ip = $config->returnValue('source-ip');
    my $maxflows  = $config->returnValue('max-flows');

    $config->setLevel("$path netflow timeout");
    my $timeout_str = '';
    foreach my $timeout (keys %timeout_hash) {
        my $value = $config->returnValue($timeout);
        if ($value and $timeout_hash{$timeout}) {
            $timeout_str .= ":" if $timeout_str ne '';
            $timeout_str .= "$timeout_hash{$timeout}=$value";
        }
    }

    my @names = acct_get_collector_names($config, 'netflow');
    foreach my $name (@names) {
        my $server_port = $name;
        $server_port    =~ s/-/:/;
        $output .= "nfprobe_receiver: $server_port\n";
        $output .= "nfprobe_version: $version\n" if defined $version;
        $output .= "nfprobe_source_ip: $source_ip\n" if defined $source_ip;
        $output .= "nfprobe_engine: $engine_id:0\n";
        $output .= "nfprobe_timeouts: $timeout_str\n"
            if $timeout_str ne '';
        $output .= "nfprobe_maxflows: $maxflows\n" if defined $maxflows;
        $output .= "sampling_rate: $sampling\n" if defined $sampling;
    }
    return $output;
}

sub sflow_find_agent_ip {
    my ($config) = @_;

    my $router_id = undef;
    my $path = 'protocols';
    $config->setLevel($path);
    if ($config->exists('bgp')) {
        $config->setLevel("$path bgp");
        my @AS = $config->listNodes();
        if (scalar(@AS) > 0) {
            $config->setLevel("$path bgp $AS[0] parameters");
            $router_id = $config->returnValue('router-id');
            if (defined $router_id) {
                return $router_id;
            }
        }
    }

    $config->setLevel($path);
    if ($config->exists('ospf')) {
        $config->setLevel("$path ospf parameters");
        if ($config->exists('router-id')) {
            $router_id = $config->returnValue('router-id');
            return $router_id;
        }
    }

    $config->setLevel($path);
    if ($config->exists('ospfv3')) {
        $config->setLevel("$path ospfv3 parameters");
        if ($config->exists('router-id')) {
            $router_id = $config->returnValue('router-id');
            return $router_id;
        }
    }

    my @intfs = getInterfaces();
    chomp(@intfs);
    foreach my $intf (@intfs) {
        my @ips = getIP($intf, 4);
        foreach my $ip (@ips) {
            if ($ip =~ /^([\d.]+)\/([\d.]+)$/) { # strip /mask
                $ip = $1;
            }
            next if $ip eq '127.0.0.1';
            return $ip;
        }
    }
    return;
}

sub acct_get_sflow {
    my ($config) = @_;

    my $path   = 'system flow-accounting';
    my $output = undef;

    $config->setLevel($path);
    return $output if !$config->exists('sflow');

    $config->setLevel("$path sflow");
    my $agent    = $config->returnValue('agentid');
    my $agent_ip = $config->returnValue('agent-address');
    my $sampling  = $config->returnValue('sampling-rate');
    if (defined $agent_ip and $agent_ip eq 'auto') {
        $agent_ip = sflow_find_agent_ip($config);
    }
    my $found = undef;
    if (defined $agent_ip) {
        my @ips = getIP();
        foreach my $ip (@ips) {
            if ($ip =~ /^([\d.]+)\/([\d.]+)$/) { # strip /mask
                $ip = $1;
            }
            $found = 1 if $ip eq $agent_ip;
        }
    }
    if (!defined $found) {
        die "agent-address [$agent_ip] not configured on system\n";
    }

    my @names = acct_get_collector_names($config, 'sflow');
    foreach my $name (@names) {
        my $server_port = $name;
        $server_port    =~ s/-/:/;
        $output .= "sfprobe_receiver: $server_port\n";
        $output .= "sfprobe_agentip: $agent_ip\n" if $agent_ip;
        $output .= "sfprobe_agentsubid: $agent\n" if $agent;
        $output .= "sampling_rate: $sampling\n" if defined $sampling;
    }

    return $output;
}

sub acct_get_config {

    my $config = new Vyatta::Config;
    my $output = '';
    my $path   = 'system flow-accounting';

    $output .= acct_conf_globals($config);

    $config->setLevel($path);
    my $facility = $config->returnValue('syslog-facility');
    $output .= "syslog: $facility\n" if defined $facility;

    my $plugins = '';
    
    if ( $config->exists('disable-imt') )
    {
      $plugins = 'plugins: memory';
    }    

    my $netflow = acct_get_netflow($config);
    if (defined $netflow) {
        my @names = acct_get_collector_names($config, 'netflow');
        foreach my $name (@names) {
            if ($plugins eq '') {
                $plugins .= "plugins: nfprobe";
            } else {
                $plugins .= ",nfprobe";
            }
        }
    }

    my $sflow   = acct_get_sflow($config);
    if (defined $sflow) {
        my @names = acct_get_collector_names($config, 'sflow');
        foreach my $name (@names) {
            if ($plugins eq '') {
                $plugins .= "sfprobe";
            } else {
                $plugins .= ",sfprobe";
            }
        }
    }

    if ($plugins eq '') {
        die "no plugins defined, you need to enable either imt, netflow or sflow\n";
    }

    $output .= "$plugins\n";
    $output .= $netflow if defined $netflow;
    $output .= $sflow   if defined $sflow;
    return $output;
}

sub acct_add_nflog_target {
    my ($intf) = @_;

    my ($table_chain) = acct_get_table_chain();
    while (my ($chain, $table) = each(%$table_chain)) {
        my $cmd = "iptables -t $table -I $chain 1 -i $intf -j NFLOG" ." --nflog-group 2";
        if (defined $nflog_range) {
            $cmd .= " --nflog-range $nflog_range";
        }
        if (defined $nflog_threshold) {
            $cmd .= " --nflog-threshold $nflog_threshold";
        }
        my $ret = system($cmd);
        if ($ret >> 8) {
            die "Error: [$cmd] failed - $?\n";
        }
    }
}

sub acct_rm_nflog_target {
    my ($intf) = @_;

    my ($table_chain) = acct_get_table_chain();
    while (my ($chain, $table) = each(%$table_chain)) {
        my $cmd = "iptables -t $table -vnL $chain --line";
        my @lines = `$cmd 2> /dev/null | egrep ^[0-9]`;
        if (scalar(@lines) < 1) {
            die "Error: failed to find NFLOG entry for $chain => $table\n";
        }
        my $found_target = 'false';
        foreach my $line (@lines) {
            my ($num, undef, undef, $target, undef, undef, $in) = split /\s+/, $line;
            if (defined $in and $in eq $intf) {
                $cmd = "iptables -t $table -D $chain $num";
                my $ret = system($cmd);
                if ($ret >> 8) {
                    die "Error: failed to delete target - $?\n";
                }
                $found_target = 'true';
                last;
            }
        }
        die "Error: failed to find target\n" if $found_target eq 'false';
    }
}

sub acct_get_int_map {
    my (@intfs) = @_;

    my $output = '';
    foreach my $intf (@intfs) {
        my $ifindx = acct_get_ifindx($intf);
        if (defined $ifindx) {
            $output .= "id=$ifindx\tin=$ifindx\n";
        } else {
            print "Warning: unknow ifindx for [$intf]\n";
        }
    }
    return $output;
}

#
# main
#

my ($action, $intf);

GetOptions(
    "action=s"      => \$action,
    "intf=s"        => \$intf,
);

die "Undefined action" if !$action;

if ($action eq 'add-intf') {
    die "Error: must include interface\n" if !defined $intf;
    my $interface = new Vyatta::Interface($intf);
    print "Warning : interface [$intf] does not exist on system\n"
        if !defined $interface;
    acct_log("update [$intf]");
    acct_add_nflog_target($intf);
    print "Adding flow-accounting for [$intf]\n";
    exit 0;
}

if ($action eq 'del-intf') {
    die "Error: must include interface\n" if !defined $intf;
    acct_log("stop [$intf]");
    acct_rm_nflog_target($intf);
    print "Removing flow-accounting for [$intf]\n";
    exit 0;
}

if ($action eq 'update') {
    acct_log("update");
    my $config = new Vyatta::Config;

    $config->setLevel('system flow-accounting interface');
    my @interfaces = $config->returnValues();
    my $conf_file = acct_get_conf_file();
    if (scalar(@interfaces) > 0) {
        my $map_conf = acct_get_int_map(@interfaces);
        my $map_changed = acct_write_file('/etc/pmacct/int_map', $map_conf);
        my $conf = acct_get_config();
        if (acct_write_file($conf_file, $conf)) {
            acct_log("conf file written");
            restart_daemon($conf_file);
        } else {

            # on reboot, the conf should match
            # but we still need to start it
            my $pid_file  = acct_get_pid_file();
            if (!is_running($pid_file)) {
                start_daemon($conf_file);
            } elsif ($map_changed) {
                acct_log("signal reread mapping");
                system("pkill -SIGUSR2 uacctd");
            }
        }

    } else {
        acct_log("stop");
        stop_daemon();
        system("rm -f $conf_file");
    }

    exit 0;
}

if ($action eq 'list-intf') {
    my @intfs = acct_get_intfs();
    print join("\n", @intfs);
    exit 0;
}

exit 1;

# end of file
