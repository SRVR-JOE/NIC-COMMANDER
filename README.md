# NIC-COMMANDER 🖧

A comprehensive Network Interface Card (NIC) Dashboard for monitoring, managing, and configuring network interfaces on your system. Supports up to 8 NICs with real-time information display, ping tools, and device discovery capabilities.

## Features

### 📊 Dashboard
- **Multi-NIC Support**: Monitor up to 8 network interfaces simultaneously
- **Real-Time Information**: View detailed statistics for each NIC including:
  - IPv4 and IPv6 addresses
  - MAC addresses
  - Network masks
  - Interface status (UP/DOWN)
  - Link speed and MTU
  - Data sent/received (bytes and packets)
  - Error and drop statistics

### 🛠️ Network Tools
- **Ping Tool**: Test connectivity to any host or IP address
  - Customizable ping count
  - Real-time output display
  - Cross-platform support (Windows, Linux, macOS)

- **Device Discovery**: Scan your local network to discover active devices
  - Automatic hostname resolution
  - Quick network scanning
  - Visual display of discovered devices with IP addresses

### 🎨 User Interface
- Modern, responsive design
- Color-coded status indicators
- Easy-to-read card-based layout
- Real-time data refresh
- Mobile-friendly interface

## Installation

### Prerequisites
- Python 3.7 or higher
- pip (Python package manager)

### Setup

1. Clone the repository:
```bash
git clone https://github.com/SRVR-JOE/NIC-COMMANDER.git
cd NIC-COMMANDER
```

2. Install required dependencies:
```bash
pip install -r requirements.txt
```

### Required Packages
- Flask 3.0.0 - Web framework
- psutil 5.9.6 - System and process utilities
- netifaces 0.11.0 - Network interface information
- requests 2.31.0 - HTTP library

## Usage

### Starting the Application

Run the Flask application:
```bash
python app.py
```

The dashboard will be available at: `http://localhost:5000`

**Note:** For development with debug mode enabled, use:
```bash
python app.py --debug
```

### Using the Dashboard

1. **View NICs**: The main dashboard automatically displays all network interfaces (up to 8) with their current information.

2. **Refresh Data**: Click the "🔄 Refresh" button to update all NIC information.

3. **Ping a Host**:
   - Enter a hostname or IP address (e.g., `google.com` or `8.8.8.8`)
   - Optionally adjust the ping count (1-10)
   - Click "Ping" to execute
   - View the results in the output box

4. **Discover Devices**:
   - Enter your network prefix (e.g., `192.168.1` for 192.168.1.0/24)
   - Click "Discover Devices"
   - Wait for the scan to complete (may take a few moments)
   - View discovered devices with their IP addresses and hostnames

## API Endpoints

The application provides a RESTful API:

### GET `/api/nics`
Returns information about all network interfaces.

**Response:**
```json
{
  "success": true,
  "nics": [
    {
      "id": 1,
      "name": "eth0",
      "ipv4": "192.168.1.100",
      "netmask": "255.255.255.0",
      "mac": "00:11:22:33:44:55",
      "is_up": true,
      "speed": "1000 Mbps",
      ...
    }
  ]
}
```

### POST `/api/ping`
Executes a ping command to a specified host.

**Request:**
```json
{
  "host": "8.8.8.8",
  "count": 4
}
```

### POST `/api/discover`
Discovers devices on the specified network.

**Request:**
```json
{
  "network_prefix": "192.168.1"
}
```

## Project Structure

```
NIC-COMMANDER/
├── app.py                  # Main Flask application
├── requirements.txt        # Python dependencies
├── README.md              # This file
├── .gitignore             # Git ignore rules
├── templates/
│   └── index.html         # Main HTML template
└── static/
    ├── css/
    │   └── style.css      # Stylesheet
    └── js/
        └── app.js         # Frontend JavaScript
```

## System Requirements

- **Operating System**: Windows, Linux, or macOS
- **Python**: 3.7+
- **Network Access**: Required for ping and discovery features
- **Permissions**: Some features may require elevated privileges:
  - Ping usually works without special permissions
  - Device discovery may require admin/root on some systems

## Security Notes

- The application runs on `0.0.0.0:5000` by default (accessible from network)
- For production use, consider:
  - Setting up authentication
  - Using HTTPS
  - Restricting host binding
  - Running behind a reverse proxy

## Troubleshooting

### NICs Not Showing
- Ensure you have the required permissions
- Check that network interfaces are properly configured on your system
- Try running with elevated privileges (sudo/admin)

### Ping Not Working
- Verify network connectivity
- On some systems, ICMP may be blocked by firewall
- Try with elevated privileges

### Device Discovery Slow
- Network scanning can take time depending on network size
- Firewalls may block ping requests
- Consider scanning smaller network ranges

## Contributing

Contributions are welcome! Please feel free to submit pull requests or open issues for bugs and feature requests.

## License

This project is open source and available for personal and educational use.

## Author

Created for easy network interface management and monitoring.

---

**NIC Commander** - Making network management simple and accessible! 🚀 
