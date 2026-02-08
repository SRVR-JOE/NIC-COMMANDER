#!/usr/bin/env python3
"""
NIC Commander - Network Interface Dashboard
A comprehensive dashboard for managing and monitoring network interface cards (NICs)
Supports 1-8 NICs with configuration, ping, and device discovery tools
"""

import os
import subprocess
import platform
import socket
from flask import Flask, render_template, jsonify, request
import psutil
import netifaces

app = Flask(__name__)

def get_nic_info():
    """
    Retrieve information for all network interfaces (up to 8 NICs)
    Returns detailed information including IP addresses, MAC addresses, and statistics
    """
    nics = []
    interfaces = netifaces.interfaces()
    
    # Limit to first 8 interfaces
    for idx, iface in enumerate(interfaces[:8]):
        try:
            addrs = netifaces.ifaddresses(iface)
            
            # Get IPv4 address
            ipv4 = None
            netmask = None
            if netifaces.AF_INET in addrs:
                ipv4 = addrs[netifaces.AF_INET][0].get('addr')
                netmask = addrs[netifaces.AF_INET][0].get('netmask')
            
            # Get IPv6 address
            ipv6 = None
            if netifaces.AF_INET6 in addrs:
                ipv6 = addrs[netifaces.AF_INET6][0].get('addr')
            
            # Get MAC address
            mac = None
            if netifaces.AF_LINK in addrs:
                mac = addrs[netifaces.AF_LINK][0].get('addr')
            
            # Get network statistics
            net_stats = psutil.net_if_stats().get(iface)
            io_stats = psutil.net_io_counters(pernic=True).get(iface)
            
            nic_info = {
                'id': idx + 1,
                'name': iface,
                'ipv4': ipv4 or 'N/A',
                'netmask': netmask or 'N/A',
                'ipv6': ipv6 or 'N/A',
                'mac': mac or 'N/A',
                'is_up': net_stats.isup if net_stats else False,
                'speed': f"{net_stats.speed} Mbps" if net_stats and net_stats.speed > 0 else 'N/A',
                'mtu': net_stats.mtu if net_stats else 'N/A',
                'bytes_sent': format_bytes(io_stats.bytes_sent) if io_stats else 'N/A',
                'bytes_recv': format_bytes(io_stats.bytes_recv) if io_stats else 'N/A',
                'packets_sent': io_stats.packets_sent if io_stats else 0,
                'packets_recv': io_stats.packets_recv if io_stats else 0,
                'errors_in': io_stats.errin if io_stats else 0,
                'errors_out': io_stats.errout if io_stats else 0,
                'drops_in': io_stats.dropin if io_stats else 0,
                'drops_out': io_stats.dropout if io_stats else 0
            }
            nics.append(nic_info)
        except Exception as e:
            print(f"Error getting info for {iface}: {e}")
            continue
    
    return nics

def format_bytes(bytes_value):
    """Convert bytes to human-readable format"""
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if bytes_value < 1024.0:
            return f"{bytes_value:.2f} {unit}"
        bytes_value /= 1024.0
    return f"{bytes_value:.2f} PB"

def ping_host(host, count=4):
    """
    Ping a host and return results
    Works on both Windows and Unix-like systems
    """
    param = '-n' if platform.system().lower() == 'windows' else '-c'
    command = ['ping', param, str(count), host]
    
    try:
        output = subprocess.check_output(
            command,
            stderr=subprocess.STDOUT,
            timeout=30,
            universal_newlines=True
        )
        return {
            'success': True,
            'output': output,
            'host': host
        }
    except subprocess.CalledProcessError as e:
        return {
            'success': False,
            'output': e.output,
            'host': host,
            'error': 'Host unreachable or ping failed'
        }
    except subprocess.TimeoutExpired:
        return {
            'success': False,
            'output': '',
            'host': host,
            'error': 'Ping timeout'
        }
    except Exception as e:
        return {
            'success': False,
            'output': '',
            'host': host,
            'error': str(e)
        }

def discover_devices(network_prefix, timeout=1):
    """
    Discover devices on the network by scanning common IP addresses
    network_prefix: e.g., '192.168.1' to scan 192.168.1.1-254
    """
    discovered = []
    
    # Scan a limited range for quick discovery
    for i in range(1, 255):
        ip = f"{network_prefix}.{i}"
        try:
            # Try to resolve hostname
            try:
                hostname = socket.gethostbyaddr(ip)[0]
            except:
                hostname = 'Unknown'
            
            # Quick ping test (single ping)
            param = '-n' if platform.system().lower() == 'windows' else '-c'
            wait_param = '-w' if platform.system().lower() == 'windows' else '-W'
            command = ['ping', param, '1', wait_param, '1', ip]
            
            result = subprocess.run(
                command,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=timeout
            )
            
            if result.returncode == 0:
                discovered.append({
                    'ip': ip,
                    'hostname': hostname,
                    'status': 'up'
                })
        except:
            continue
    
    return discovered

@app.route('/')
def index():
    """Main dashboard page"""
    return render_template('index.html')

@app.route('/api/nics')
def api_nics():
    """API endpoint to get all NIC information"""
    try:
        nics = get_nic_info()
        return jsonify({'success': True, 'nics': nics})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/ping', methods=['POST'])
def api_ping():
    """API endpoint to ping a host"""
    data = request.get_json()
    host = data.get('host')
    count = data.get('count', 4)
    
    if not host:
        return jsonify({'success': False, 'error': 'Host is required'}), 400
    
    result = ping_host(host, count)
    return jsonify(result)

@app.route('/api/discover', methods=['POST'])
def api_discover():
    """API endpoint to discover devices on the network"""
    data = request.get_json()
    network_prefix = data.get('network_prefix')
    
    if not network_prefix:
        return jsonify({'success': False, 'error': 'Network prefix is required (e.g., 192.168.1)'}), 400
    
    try:
        devices = discover_devices(network_prefix)
        return jsonify({'success': True, 'devices': devices})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/nic/<nic_name>/toggle', methods=['POST'])
def api_toggle_nic(nic_name):
    """API endpoint to enable/disable a NIC (requires appropriate permissions)"""
    try:
        # This is a placeholder - actual implementation requires admin/root privileges
        # and varies by operating system
        return jsonify({
            'success': False,
            'error': 'NIC toggling requires administrative privileges and is system-dependent'
        }), 403
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0', port=5000)
